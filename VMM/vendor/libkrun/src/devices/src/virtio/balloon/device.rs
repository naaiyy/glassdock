use std::cmp;
use std::convert::TryInto;
use std::io::{self, Write};
use std::mem::size_of;
use std::sync::Arc;

use utils::eventfd::EventFd;
use vm_memory::{Address, ByteValued, Bytes, GuestAddress, GuestMemory, GuestMemoryMmap};

use super::super::{
    ActivateError, ActivateResult, BalloonError, DeviceQueue, DeviceState, QueueConfig,
    VirtioDevice,
};
use super::{defs, defs::uapi};
use crate::virtio::InterruptTransport;

// Inflate queue.
pub(crate) const IFQ_INDEX: usize = 0;
// Deflate queue.
pub(crate) const DFQ_INDEX: usize = 1;
// Stats queue.
pub(crate) const STQ_INDEX: usize = 2;
// Page-hinting queue.
pub(crate) const PHQ_INDEX: usize = 3;
// Free page reporting queue.
pub(crate) const FRQ_INDEX: usize = 4;

const PAGE_SIZE: u64 = 4096;

// Supported features.
pub(crate) const AVAIL_FEATURES: u64 = (1 << uapi::VIRTIO_F_VERSION_1 as u64)
    | (1 << uapi::VIRTIO_BALLOON_F_STATS_VQ as u64)
    | (1 << uapi::VIRTIO_BALLOON_F_DEFLATE_ON_OOM as u64)
    | (1 << uapi::VIRTIO_BALLOON_F_FREE_PAGE_HINT as u64)
    | (1 << uapi::VIRTIO_BALLOON_F_PAGE_POISON as u64)
    | (1 << uapi::VIRTIO_BALLOON_F_REPORTING as u64);

#[derive(Copy, Clone, Debug, Default)]
#[repr(C, packed)]
pub struct VirtioBalloonConfig {
    /* Number of pages host wants Guest to give up. */
    num_pages: u32,
    /* Number of pages we've actually got in balloon. */
    actual: u32,
    /* Free page report command id, readonly by guest */
    free_page_report_cmd_id: u32,
    /* Stores PAGE_POISON if page poisoning is in use */
    poison_val: u32,
}

// Safe because it only has data and has no implicit padding.
unsafe impl ByteValued for VirtioBalloonConfig {}

pub struct Balloon {
    pub(crate) queues: Option<Vec<DeviceQueue>>,
    pub(crate) avail_features: u64,
    pub(crate) acked_features: u64,
    pub(crate) activate_evt: EventFd,
    pub(crate) device_state: DeviceState,
    config: VirtioBalloonConfig,
    free_page_reclaimer: Option<Arc<dyn FreePageReclaimer>>,
}

/// Host-specific free-page release. The macOS implementation removes the
/// stage-2 mapping for free-page reports and drops backing for explicit
/// balloon pages while retaining their mapping for fast deflation.
pub trait FreePageReclaimer: Send + Sync {
    fn release_range(
        &self,
        mem: &GuestMemoryMmap,
        guest_addr: GuestAddress,
        len: u64,
    ) -> io::Result<()>;

    fn release_pages(&self, mem: &GuestMemoryMmap, pages: &[GuestAddress]) -> io::Result<()> {
        for page in pages {
            self.release_range(mem, *page, PAGE_SIZE)?;
        }
        Ok(())
    }

    fn restore_range(
        &self,
        _mem: &GuestMemoryMmap,
        _guest_addr: GuestAddress,
        _len: u64,
    ) -> io::Result<()> {
        Err(io::Error::from_raw_os_error(libc::ENOTSUP))
    }

    fn restore_pages(&self, mem: &GuestMemoryMmap, pages: &[GuestAddress]) -> io::Result<()> {
        for page in pages {
            self.restore_range(mem, *page, PAGE_SIZE)?;
        }
        Ok(())
    }
}

impl Balloon {
    pub fn new() -> super::Result<Balloon> {
        Self::new_with_reclaimer(None)
    }

    pub fn new_with_reclaimer(
        free_page_reclaimer: Option<Arc<dyn FreePageReclaimer>>,
    ) -> super::Result<Balloon> {
        Ok(Balloon {
            queues: None,
            avail_features: AVAIL_FEATURES,
            acked_features: 0,
            activate_evt: EventFd::new(utils::eventfd::EFD_NONBLOCK)
                .map_err(BalloonError::EventFd)?,
            device_state: DeviceState::Inactive,
            config: VirtioBalloonConfig::default(),
            free_page_reclaimer,
        })
    }

    pub fn id(&self) -> &str {
        defs::BALLOON_DEV_ID
    }

    pub fn set_target_pages(&mut self, pages: u32) -> bool {
        if self.config.num_pages == pages {
            return false;
        }
        self.config.num_pages = pages;
        true
    }

    pub fn target_reached(&self) -> bool {
        self.config.actual == self.config.num_pages
    }

    fn read_page_list(
        mem: &GuestMemoryMmap,
        head: super::super::DescriptorChain<'_>,
    ) -> io::Result<Vec<GuestAddress>> {
        let mut pages = Vec::new();
        for desc in head.into_iter() {
            if desc.is_write_only() || desc.len % size_of::<u32>() as u32 != 0 {
                return Err(io::Error::from_raw_os_error(libc::EINVAL));
            }
            for offset in (0..desc.len).step_by(size_of::<u32>()) {
                let address = desc
                    .addr
                    .raw_value()
                    .checked_add(u64::from(offset))
                    .ok_or_else(|| io::Error::from_raw_os_error(libc::EFAULT))?;
                let page_frame = mem
                    .read_obj::<u32>(GuestAddress(address))
                    .map_err(|_| io::Error::from_raw_os_error(libc::EFAULT))?;
                let page_address = u64::from(page_frame)
                    .checked_mul(PAGE_SIZE)
                    .ok_or_else(|| io::Error::from_raw_os_error(libc::EFAULT))?;
                pages.push(GuestAddress(page_address));
            }
        }
        Ok(pages)
    }

    fn process_page_queue(&mut self, queue_index: usize, inflate: bool) -> bool {
        let mem = match self.device_state {
            DeviceState::Activated(ref mem, _) => mem,
            DeviceState::Inactive => unreachable!(),
        };
        let mut have_used = false;
        let mut pending = Vec::new();
        let mut pages = Vec::new();

        loop {
            let head = {
                let queues = self
                    .queues
                    .as_mut()
                    .expect("queues should exist when activated");
                queues[queue_index].queue.pop(mem)
            };
            let Some(head) = head else { break };
            let index = head.index;
            let head_pages = match Self::read_page_list(mem, head) {
                Ok(pages) => pages,
                Err(error) => {
                    warn!(
                        "balloon: invalid {} page list: {error}",
                        if inflate { "inflate" } else { "deflate" }
                    );
                    Vec::new()
                }
            };
            pages.extend(head_pages.iter().copied());
            pending.push((index, head_pages));
            have_used = true;
        }

        let result = if let Some(reclaimer) = &self.free_page_reclaimer {
            if inflate {
                reclaimer.release_pages(mem, &pages)
            } else {
                reclaimer.restore_pages(mem, &pages)
            }
        } else {
            Self::reclaim_without_host_reclaimer(mem, &pages, inflate)
        };
        if let Err(error) = result {
            warn!(
                "balloon: failed to {} {} pages: {error}",
                if inflate { "inflate" } else { "deflate" },
                pages.len()
            );
        } else if inflate {
            self.config.actual = self
                .config
                .actual
                .saturating_add(u32::try_from(pages.len()).unwrap_or(u32::MAX));
        } else {
            self.config.actual = self
                .config
                .actual
                .saturating_sub(u32::try_from(pages.len()).unwrap_or(u32::MAX));
        }
        let queues = self
            .queues
            .as_mut()
            .expect("queues should exist when activated");
        for (index, _) in pending {
            if let Err(error) = queues[queue_index].queue.add_used(mem, index, 0) {
                error!("failed to add used elements to balloon queue: {error:?}");
            }
        }

        have_used
    }

    fn reclaim_without_host_reclaimer(
        mem: &GuestMemoryMmap,
        pages: &[GuestAddress],
        inflate: bool,
    ) -> io::Result<()> {
        for page in pages {
            let host_addr = mem
                .get_host_address(*page)
                .map_err(|_| io::Error::from_raw_os_error(libc::EFAULT))?;
            #[cfg(target_os = "linux")]
            let advice = if inflate {
                libc::MADV_DONTNEED
            } else {
                libc::MADV_FREE
            };
            #[cfg(target_os = "macos")]
            let advice = if inflate {
                libc::MADV_FREE_REUSABLE
            } else {
                libc::MADV_FREE_REUSE
            };
            if unsafe { libc::madvise(host_addr as *mut libc::c_void, PAGE_SIZE as usize, advice) }
                != 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    pub fn process_ifq(&mut self) -> bool {
        self.process_page_queue(IFQ_INDEX, true)
    }

    pub fn process_dfq(&mut self) -> bool {
        self.process_page_queue(DFQ_INDEX, false)
    }

    pub fn process_frq(&mut self) -> bool {
        debug!("balloon: process_frq()");
        let mem = match self.device_state {
            DeviceState::Activated(ref mem, _) => mem,
            // This should never happen, it's been already validated in the event handler.
            DeviceState::Inactive => unreachable!(),
        };

        let queues = self
            .queues
            .as_mut()
            .expect("queues should exist when activated");
        let mut have_used = false;

        while let Some(head) = queues[FRQ_INDEX].queue.pop(mem) {
            let index = head.index;
            for desc in head.into_iter() {
                if let Some(reclaimer) = &self.free_page_reclaimer {
                    if let Err(error) = reclaimer.release_range(mem, desc.addr, u64::from(desc.len))
                    {
                        warn!(
                            "balloon: rejected free-page report guest_addr={:?} len={}: {error}",
                            desc.addr, desc.len
                        );
                    }
                    continue;
                }
                let host_addr = mem.get_host_address(desc.addr).unwrap();
                debug!(
                    "balloon: should release guest_addr={:?} host_addr={:p} len={}",
                    desc.addr, host_addr, desc.len
                );
                #[cfg(target_os = "linux")]
                let advice = libc::MADV_DONTNEED;
                #[cfg(target_os = "macos")]
                let advice = libc::MADV_FREE;
                unsafe {
                    libc::madvise(
                        host_addr as *mut libc::c_void,
                        desc.len.try_into().unwrap(),
                        advice,
                    )
                };
            }

            have_used = true;
            if let Err(e) = queues[FRQ_INDEX].queue.add_used(mem, index, 0) {
                error!("failed to add used elements to the queue: {e:?}");
            }
        }

        have_used
    }
}

impl VirtioDevice for Balloon {
    fn avail_features(&self) -> u64 {
        self.avail_features
    }

    fn acked_features(&self) -> u64 {
        self.acked_features
    }

    fn set_acked_features(&mut self, acked_features: u64) {
        self.acked_features = acked_features
    }

    fn device_type(&self) -> u32 {
        uapi::VIRTIO_ID_BALLOON
    }

    fn device_name(&self) -> &str {
        "balloon"
    }

    fn queue_config(&self) -> &[QueueConfig] {
        &defs::QUEUE_CONFIG
    }

    fn read_config(&self, offset: u64, mut data: &mut [u8]) {
        let config_slice = self.config.as_slice();
        let config_len = config_slice.len() as u64;
        if offset >= config_len {
            error!("Failed to read config space");
            return;
        }
        if let Some(end) = offset.checked_add(data.len() as u64) {
            // This write can't fail, offset and end are checked against config_len.
            data.write_all(&config_slice[offset as usize..cmp::min(end, config_len) as usize])
                .unwrap();
        }
    }

    fn write_config(&mut self, offset: u64, data: &[u8]) {
        let actual_offset = size_of::<u32>() as u64;
        if offset == actual_offset && data.len() == size_of::<u32>() {
            // Linux reports the number of pages it has placed in the balloon
            // through this writable configuration field after each queue
            // batch. The host keeps the same value while it processes the
            // corresponding descriptor.
            self.config.actual = u32::from_le_bytes(data.try_into().unwrap());
            return;
        }
        let poison_offset = 3 * size_of::<u32>() as u64;
        if offset == poison_offset && data.len() == size_of::<u32>() {
            self.config.poison_val = u32::from_le_bytes(data.try_into().unwrap());
            return;
        }
        debug!(
            "balloon: ignored guest device-config write (offset={offset:x}, len={})",
            data.len()
        );
    }

    fn activate(
        &mut self,
        mem: GuestMemoryMmap,
        interrupt: InterruptTransport,
        queues: Vec<DeviceQueue>,
    ) -> ActivateResult {
        if queues.len() != defs::NUM_QUEUES {
            error!(
                "Cannot perform activate. Expected {} queue(s), got {}",
                defs::NUM_QUEUES,
                queues.len()
            );
            return Err(ActivateError::BadActivate);
        }

        if self.activate_evt.write(1).is_err() {
            error!("Cannot write to activate_evt",);
            return Err(ActivateError::BadActivate);
        }

        self.queues = Some(queues);
        self.device_state = DeviceState::Activated(mem, interrupt);

        Ok(())
    }

    fn is_activated(&self) -> bool {
        self.device_state.is_activated()
    }
}
