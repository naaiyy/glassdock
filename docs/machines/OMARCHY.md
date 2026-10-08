# Omarchy Quattro on Apple Silicon

GlassDock Machines has an Omarchy profile for the ARM64 Arch Linux factory
built by [Try Omarchy](https://github.com/omacom/try-omarchy). It runs the
Omarchy 4 desktop in GlassDock's QEMU/HVF backend and native SPICE viewer.
This is an ARM64 adaptation of Omarchy, rather than the x86_64 installer ISO.

## Create a machine

Prerequisites: macOS 15 or later on Apple Silicon, a prepared GlassDock Machines
runtime, Python 3.11 or later, and Homebrew's `zstd` and `e2fsprogs` packages.
Allow approximately 15 GiB of free space for the download, expanded factory,
and new machine, plus build space if building from source. The preparation
script checks expanded-image space; it does not reserve the machine's disk.

```sh
brew install zstd e2fsprogs
bash scripts/machines/create-omarchy.sh
```

The default machine is named `Omarchy Quattro`, with 4 CPUs, 4 GiB RAM,
a 64 GiB sparse disk, VirGL graphics, audio output, and SSH forwarded only on
`127.0.0.1:22223`. An optional first argument supplies a different name and a
second argument supplies an SSH port. The script creates a stopped machine;
start it in the newly built `.build/machines/GlassDock Machines.app` and
complete the upstream owner setup. The creation script builds that viewer and
its signed helpers, reusing installed runtime frameworks when available.
No account or password is preconfigured by GlassDock.

For the app's New Machine dialog:

```sh
bash scripts/machines/prepare-omarchy.sh
```

Choose **Omarchy Quattro ARM64**, then select the prepared
`.build/machines/omarchy-quattro-4.0.4` directory. Its disk and boot files are
copied into the machine. The app does not depend on that directory afterward.
Creation through the CLI is equivalent:

```sh
glassdockctl machines create 'Omarchy Quattro' --os omarchy \
  --omarchy-guest .build/machines/omarchy-quattro-4.0.4 --ssh-port 22223
```

An existing destination is never overwritten by preparation. To refresh it,
prepare into a new directory and create a new machine. Existing Ubuntu and
Windows machines retain their current configurations and runtimes.

## Boot and guest integration

The factory disk is an ext4 filesystem without an EFI installation. Each
machine retains its paired `vmlinuz-linux`, `initramfs-linux.img`, and upstream
metadata under `state/`. Boot uses these files directly. Snapshots, clones,
and both directory and ZIP exports carry them alongside the disk. Import
rejects an Omarchy machine missing its boot kit. Its original kernel/graphics
pinning policy remains in place during guest package updates.

Preparation pins Try Omarchy **v0.5.1**, containing Omarchy **4.0.4 / Quattro**,
and verifies the release DMG SHA-256:

```
03760f542025600ef29f77319c93d7c3640a3b15fcf73bda75b9caa9fcbd9999
```

The factory manifest checks the compressed disk, expanded disk, kernel,
initramfs, metadata, and license before adaptation. GlassDock adds a first-boot
systemd service to a staged factory copy using `debugfs`, verifies its bytes
and enablement, and records the original rootfs hash and integration payload
hashes in provenance. It then updates the prepared manifest hashes. No
upstream launcher or QEMU binaries from the DMG are executed or redistributed.

On first boot, the service installs `qemu-guest-agent` and `davfs2` from signed
Arch Linux ARM repositories using `pacman -Syu`, respecting the factory's
`IgnorePkg` list. This package transaction uses the current signed repository;
it is separate from the pinned downloaded factory. Guest management becomes
available after it succeeds. A network/package failure retries every 30
seconds without blocking owner setup. Inspect the result inside the guest:

```sh
systemctl status glassdock-omarchy-integration.service qemu-guest-agent
journalctl -u glassdock-omarchy-integration.service
```

The completion marker is `/var/lib/glassdock/integration-v1`.
SSH is enabled at boot only when an SSH forward is configured, and uses the
account created during owner setup. No host SSH key is injected.

## Capabilities and limits

- CPU virtualization, networking, native display and input, audio, orderly
  shutdown, pause/resume, stopped disk snapshots, cloning, and portable
  export/import use the existing machine backend.
- VirGL is required for Hyprland. Basic and Windows Neptune graphics profiles
  are rejected for Omarchy. Minimums are 4 CPUs, 4 GiB RAM, and 64 GiB disk.
- RAM checkpoints retain the existing backend restriction to basic graphics,
  so they are unavailable for this profile.
- Hyprland uses Wayland. GlassDock's existing X11 SPICE clipboard and desktop
  resolution agent is not a Wayland integration. Clipboard sharing and
  automatic guest resolution changes must not be assumed to match Ubuntu.
  Host directory sharing can be mounted with the guest's WebDAV client.
- Try Omarchy's custom Touch ID, camera, battery, and other launcher bridges
  are not connected to GlassDock. Their presence in the upstream image does
  not imply that those host integrations are available here.

For an isolated worktree preview, set `GLASSDOCK_VM_LIBRARY` to a separate
library directory when launching the app. CLI commands also accept `--library`.
This lets a preview run without opening or changing the normal machine library.
Older installed versions cannot read the new Omarchy profile. For worktree use:

```sh
GLASSDOCK_VM_LIBRARY="$PWD/.build/machines/library" bash scripts/machines/create-omarchy.sh
open -n --env "GLASSDOCK_VM_LIBRARY=$PWD/.build/machines/library" \
  '.build/machines/GlassDock Machines.app'
```
