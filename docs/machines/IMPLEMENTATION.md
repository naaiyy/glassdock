# GlassDock Machines

GlassDock Machines is the native Linux ARM64 and Windows ARM64 companion to the Docker-compatible daemon. Containers continue to use Apple Container/Containerization. Full machines use QEMU with Apple's Hypervisor.framework (HVF), because this stack supports Windows ARM, software TPM, SPICE, portable disks and saved RAM together. There is no VMPal code, Vercel Native, D3DMetal or decompiled iOS hypervisor in this implementation.

## Build and run

```sh
# Source build; requires Xcode + Metal toolchain and the prerequisites below.
bash scripts/machines/build-source-runtime.sh
GLASSDOCK_VM_RUNTIME_SOURCE="$PWD/.build/machines/source-runtime/GlassDockRuntime" \
  bash scripts/machines/build-app.sh
open '.build/machines/GlassDock Machines.app'
.build/debug/glassdockctl machines --help
```

Build prerequisites: Homebrew bison, gettext, libgpg-error, glib, glib-utils, meson, ninja, automake, autoconf, libtool, pkg-config, cmake, nasm, python, xorriso and spirv-llvm-translator; Xcode's command-line and Metal tools. The script builds the selected upstream runtime, including ANGLE, LLVM 15 and DXMT; it can take substantial time and disk space. `GLASSDOCK_VM_BUILD_JOBS` defaults to 4. The Python build dependencies are pinned in `scripts/machines/requirements-build.txt`. Sources, tool environments and output stay in ignored `.build/machines/source-runtime`. Do not use resume switches on an incomplete or different source tree.

For a development bootstrap, `bash scripts/machines/build-app.sh` without the source-runtime variable downloads and verifies official UTM 5.0.5, then packages only the selected open-source closure. This is explicitly a prebuilt bootstrap, not an independent source build. Its DMG SHA-256 is `713afe73c711f01344b8766654be531cd391ed2e30931206f43b5159f143764f`.

Create an Ubuntu desktop from Canonical's cloud image and checksum manifest:

```sh
bash scripts/machines/create-ubuntu.sh 'Ubuntu Linux' 22222
```

Choose an unused name and loopback SSH port. The local SSH key and cloud-init seed remain ignored. XFCE, LightDM, QGA, SPICE agents, Mesa, audio and WebDAV guest packages install at first boot. Windows installation uses an ARM64 Microsoft installer and requires the user to accept its terms and enter credentials. Guest-tool licenses are separate. No Windows activation or license entitlement is supplied.

## Stack and architecture

| Layer | Dependency / role |
|---|---|
| Host manager | SwiftUI/AppKit; independent companion app `dev.glassdock.machines`, menu-bar launcher, `glassdockctl machines` |
| Desktop viewer | Pinned CocoaSpice `127033fa3e59cd49678f49ed54f8adfc060afb56`, CocoaSpiceRenderer/MetalKit |
| CPU | QEMU 10.0.12-utm, ARM `virt` machine, host CPU, HVF |
| Firmware / disks | EDK2 ARM UEFI, persistent variables, QCOW2 and qemu-img |
| Windows security | swtpm/libtpms TPM 2.0, CRB interface and secure EDK2 firmware |
| Networking | QEMU user-mode NAT; optional SSH forwarding bound to 127.0.0.1 |
| Control | Private UNIX QMP and QEMU guest-agent sockets; Swift supervisor and operation/session locks |
| Basic graphics (default) | virtio-ramfb; Linux Mesa llvmpipe / Windows VirtIO GPU DOD |
| Linux accelerated graphics | virglrenderer + libepoxy + ANGLE Metal; SPICE GLES |
| Windows accelerated graphics | Neptune virglrenderer + DXMT native D3D11 + signed Triton ARM driver v0.3; HVF 4 KiB IPA granules |
| Guest integration | spice-vdagent / Windows vdservice, QGA, phodav/libsoup + spice-webdavd, USB redirection via libusb/usbredir |
| Audio | Optional output-only CoreAudio + Intel HDA; no microphone device |
| SPICE dependencies | spice-gtk/server, GLib/GObject/GIO, GStreamer and their selected transitive frameworks |
| Archives | ZIPFoundation exact 0.9.20, CryptoKit SHA-256; sparse APFS folder archives |
| Container engine | Existing apple/container, apple/containerization and Vapor stack; independent of full-machine runtime |

[upstream-runtime-inventory.json](upstream-runtime-inventory.json) contains the exact upstream versions and GPU commits derived from [UTM v5.0.5 sources](https://github.com/utmapp/UTM/blob/v5.0.5/patches/sources). The source builder pins UTM commit `b6f7475be54f9cb542c46b131319454b83489ced`, retains its build patches and applies explicit macOS/Xcode compatibility adjustments. It excludes proprietary D3DMetal, the decompiled iOS Hypervisor, unused Venus/MoltenVK/Mesa paths and QEMU's unused ParavirtualizedGraphics backend. The packaged runtime contains 37 ARM64 frameworks, an independent render server and firmware; it does not embed or symlink the UTM app. Runtime dependencies have portable paths and strict ad-hoc signature verification. The QEMU patch transports IOSurface IDs through a socket pair, and CocoaSpice reads them with MSG_PEEK so reconnecting viewers do not consume the shared identifier. CocoaSpice patches also adopt an existing GL surface on reconnect and expose its dimensions before renderer attachment; the native viewer selects the active accelerated adapter ahead of an inactive firmware framebuffer.

The observed source identities are recorded in [source-runtime-provenance.json](source-runtime-provenance.json). The source build emits `source-provenance.json` with archive hashes, git commits and patch/build-script identities; packaging emits `runtime-artifacts.json` with binary/helper/firmware hashes. Notices are collected in `Contents/Resources/Licenses`. Keep the source work directory. Public binary distribution additionally requires complete corresponding source, dependency/license review, Developer ID signing and notarization; these are not established by a local ad-hoc build. Some matching upstream pins are old, including OpenSSL 1.1.1b, GStreamer 1.19.1 and libxml2 2.9.12. Exact reference parity does not make them security-reviewed release dependencies.

Apple Virtualization/Rosetta and libkrun comparison backends are not implemented. Windows ARM support is the reason to use QEMU/HVF as the shared full-machine backend. Rosetta is not a Windows runtime. Quickshell belongs inside a Linux guest if desired; it is not a VM manager or host graphics backend. Capsule's public description is architecture inspiration, not an imported dependency or inspected public source release. No proprietary VMPal implementation was copied or payment bypassed.

## Machine management and safety

Machines live at `~/Library/Application Support/GlassDock/Machines/<UUID>.glassvm`. Disk, UEFI, TPM and removable media are under `state`; logs and locks remain outside portable guest state. Control sockets have owner-only permissions under `/tmp/glassdock-vm-<uid>/<UUID>`.

- Native creation/configuration includes OS, CPU, memory, disk, graphics, output audio and optional USB channels. CLI exposes the same lifecycle, media, clone, snapshot, archive and guest-execution operations. Configuration/clone/archive/stopped snapshots require a stopped machine.
- Stopped snapshots capture disk, UEFI, TPM, configuration and local RAM-checkpoint metadata together. Restore stages and backs up state before replacement. Clones/imports receive a new host UUID/MAC, and imports drop the source SSH forward. Windows guest identity and activation are not generalized; these are local clones, not Sysprep deployment templates.
- RAM checkpoints use QEMU savevm/loadvm and require basic graphics, identical machine settings, QEMU version and binary hash. Saving budgets guest RAM plus 2 GiB of free disk headroom. Live restore and resume after full process restart are implemented. Accelerated GPU state is not checkpointable. A different runtime correctly rejects old checkpoints; cold boot or stopped snapshots remain available.
- ZIP and folder archives validate SHA-256, ZIP CRC where applicable, entry/path limits, symlinks, special files, disk backing references and available storage. They preserve guest disk/firmware/TPM state, but not manager snapshots or automatic RAM resume. Folder archives use sparse/APFS copies; cross-volume copies conservatively budget full logical size. ZIP export can compact disks but requires substantially more staging space. Windows folder export/import is verified; Windows ZIP export was capacity-limited and has not completed on this host.
- Mac ASCII typing defaults to logical US guest keys, complete SPICE chords and Command-V paste as keystrokes. Physical keys are optional. Unicode keystroke paste is rejected. Input stops when a host sheet owns focus; a dialog's text cannot leak into the guest.
- Continuous text clipboard sharing starts off and is opt-in. Folder sharing starts off, requires an explicit selected folder and defaults read-only; access is revoked on deselection/disconnect. USB forwarding requires explicit device selection and never automatically attaches host devices. No microphone forwarding is configured.

## Observed validation

| Capability | Evidence |
|---|---|
| Linux desktop | Ubuntu ARM64 cold boot, XFCE, native display/reconnect, QGA and loopback SSH; marker survives restart |
| Windows desktop | ARM64 installed; user confirmed sign-in, normal desktop use and pause; native reconnect and orderly shutdown observed |
| TPM / basic driver | CRB TPM enabled/owned and healthy PnP; VirtIO GPU DOD healthy |
| Clone / stopped restore | Both OS clones boot; Windows test marker returns to baseline and TPM persistent state is preserved |
| Export / import | Linux ZIP round trip boots; Windows checksummed folder round trip boots with healthy TPM/driver and marker |
| RAM checkpoints | Linux volatile RAM marker and boot identity preserved through live restore and full process restart; Windows marker restored live and after full process restart |
| Clipboard | Ubuntu guest-to-host and host-to-guest text observed in native apps; sharing then disabled |
| Folder sharing | Ubuntu WebDAV read passes, default read-only rejects write (403), explicit writable test returns 201 and appears on host, revocation returns 404 |
| Audio | Ubuntu HDA detected and speaker-test executes successfully; Windows HDA PnP healthy. Audible output quality has not been independently confirmed |
| USB | Native explicit picker and protocol channels implemented; forwarding a physical peripheral has not been exercised |
| Linux acceleration | Full native XFCE desktop, accelerated Mesa capability and matched scene measurements below |
| Windows acceleration | Signed Triton GPU3D driver PnP code 0; Neptune/DXMT DWM texture composition and native lock screen observed. Interactive hardware D3D11 feature level 11_0 and verified pixels pass in three trials; Neptune/DXMT compared with WARP below. QGA Session 0 is unsuitable for hardware graphics acceptance |
| Regression tests | `make test`: 877 passing tests (845 main, 6 menu, 26 control), including archive guards, RAM metadata, keyboard focus, audio/USB graphics args display selection, and real UNIX QGA synchronization |

The independently built and packaged source runtime also cold-boots both guests in the native viewer. Linux volatile RAM/boot identity and Windows TPM remain healthy after saving RAM and restoring across a complete process restart. Native creation, CPU/audio/USB settings, stopped snapshot creation, cloning, folder export and folder import were exercised with an empty test machine. No overall fastest-VM claim is established.

The Windows installer SHA-256 `8992F2D2CFD2FA647E579E9EB31FC21F34DA8333C29B6170FDE17D2ED6623E9C` matches an official Microsoft published hash, but the language row differs from the selected English download even though internal metadata is English. The language-label discrepancy remains unresolved. It must not be presented as a matching English-row checksum.

## Matched Linux graphics measurements

Apple M4 Pro, Ubuntu 24.04 ARM64, Mesa 25.2.8, 4 CPUs / 4 GiB, glmark2 2023.01. The table below uses the independently built source runtime; the original bootstrap measurements are retained in local logs. Three alternating runs per backend, 800×600 off-screen, frame-end finish, 3 seconds per scene. Pixel validation passes on both profiles.

| Scene | Basic / llvmpipe median FPS (range) | virgl / ANGLE Metal median FPS (range) |
|---|---:|---:|
| build, use-vbo=true | 921 (847–923) | 543 (543–562) |
| shading, phong | 479 (440–491) | 533 (511–548) |
| texture, linear filtering | 1554 (1486–1555) | 578 (566–587) |

Basic is the default. Accelerated rendering wins the shading scene by about 11%, but loses the other two; neither backend is universally faster. This compares two GlassDock Linux graphics profiles, not Docker, VMPal, UTM product performance or a complete gaming/UI benchmark. These measurements precede the final IOSurface transport reconnection patch; the renderer and benchmark workload are unchanged, but timings were not remeasured after that patch. Raw local measurements stay in `.build/machines/graphics`; [graphics-results.json](graphics-results.json) records the source-runtime trials.

```sh
glmark2 --off-screen --size 800x600 --frame-end finish \
  -b build:use-vbo=true:duration=3.0 \
  -b shading:shading=phong:duration=3.0 \
  -b texture:texture-filter=linear:duration=3.0
```

Primary references: [Triton/Neptune setup](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/), [signed Triton v0.3](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.3), [QGA protocol](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html), [Microsoft ARM64 installer](https://www.microsoft.com/en-us/software-download/windows11arm64), [glmark2](https://github.com/glmark2/glmark2).

## Windows Direct3D 11 acceptance and readback comparison

These trials preceded the final IOSurface transport reconnection patch. The signed-in Windows Graphics Test guest runs the independently built Neptune/DXMT runtime with the signed Triton v0.3 driver. Hardware and WARP both create feature-level 11_0 devices and pass RGBA pixel checks. Three alternating 3-second trials after 20 warm-up frames render an 800×600 clear, copy it to a staging texture and synchronously map/read it every frame. This measures clear-plus-readback overhead, not shaders, games or desktop responsiveness. Both devices run in the same Windows guest and user session; WARP is not the basic VM graphics profile.

| D3D11 device | Median frames/s | Range | Pixel validation |
|---|---:|---:|---|
| Hardware / Neptune + DXMT | 590.32 | 589.74–596.17 | Pass |
| Software / Microsoft WARP | 3839.38 | 3326.90–3896.48 | Pass |

WARP is about 6.5× faster on this readback-heavy workload. This does not establish a general GPU speed ranking. The reproducible test source is [d3d11-proof.cs](../../scripts/machines/benchmarks/d3d11-proof.cs); compile with Windows PowerShell Add-Type using OutputType ConsoleApplication and run the executable in the interactive desktop. Running hardware tests via QGA's service session instead reports a missing virtual PCI device and is not a valid substitute.

Packaging replaces signed framework and helper inodes before publication; no live helper is edited or signed in place. A running Linux test guest preserved its boot identity through repackaging, and Windows stayed running. An earlier development packaging pass stopped several guests, including the original Ubuntu process (supervisor recorded status 11); its in-memory paused session was lost, while its disk remains intact. Existing RAM checkpoints from a different runtime are intentionally rejected.

The packaging regression test is `python3 scripts/machines/tests/test-package-runtime.py`. It holds open executable/framework files while packaging and checks that relocation/signing leaves their original inodes unchanged; reverting atomic helper publication makes the test fail.

The accelerated-surface regression test is `python3 scripts/machines/tests/test-surface-reconnect.py`: it compiles the exact CocoaSpice surface-ID reader and verifies repeated socket reads, invalidation and legacy pipe compatibility. Packaging also rejects cyclic or escaping framework symlinks. The two Python suites cover three cases. Guest tools receive an explicit powerdown request for orderly shutdown; ACPI is the fallback when guest shutdown is unavailable. This avoids Windows power-button settings that may sleep instead.

Final installed-build checks: the Ubuntu test clone with 2 GiB RAM preserves boot ID and a volatile marker through live restore and full process restart. Paused Linux and running Windows test clones shut down through guest tools. The installed app reconnects to both OS displays; after the final Windows restart, its lock screen, healthy GPU driver and enabled/activated/owned TPM are verified. A fresh interactive sign-in check remains pending the user; the interactive D3D11 trials above passed earlier in this session. `Get-Tpm` in the QGA service session returns a TBS error; TPM claims here refer to the explicit Win32_Tpm properties, not a successful Get-Tpm call.
