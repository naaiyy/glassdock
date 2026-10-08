# macOS on Apple Silicon

GlassDock Machines uses Apple's Virtualization.framework for macOS guests. It
requires an Apple Silicon Mac running macOS 15 or newer, a compatible Apple IPSW
restore image, and the signed Machines app and preparation helper. Linux and Windows continue
to use QEMU. The host must support the chosen restore image's hardware model;
importing an archive does not make an incompatible model runnable.

## Create and install

Build the native app and signed helpers:

```sh
GLASSDOCK_VM_RUNTIME_SOURCE='/Applications/GlassDock Machines.app' \
  bash scripts/machines/build-app.sh
```

The runtime source is only needed for the existing Linux/Windows viewer. The Mac
itself runs through Apple's framework, not the QEMU frameworks.

Find the current image compatible with the host:

```sh
.build/out/Products/Debug/glassdockctl machines restore-image
```

Download the printed Apple URL to a local `.ipsw` file. Creation checks that the
library has room for a copy of the IPSW plus at least 22 GiB for installation.
Allow additional space for host operation, applications, snapshots, and exports.

In the Machines app choose **New Machine → macOS (Apple Silicon)** and select the
IPSW. Or use:

```sh
glassdockctl machines create 'macOS' --os macos --ipsw /path/to/Restore.ipsw \
  --cpus 4 --memory 4096 --disk-size 64
glassdockctl machines start 'macOS'
```

The first start installs macOS with `VZMacOSInstaller`, displaying progress in the
embedded desktop. Power and pause controls are unavailable during
installation. When installation succeeds, the guest starts Setup Assistant.
Complete Apple's terms and account/password setup yourself in the embedded desktop.
The copied installer is removed after success; failed installation keeps it for
retry. GlassDock never creates guest credentials or signs into an Apple Account.

The desktop is embedded in the Machines app, backed by `VZVirtualMachineView`,
with Mac keyboard/trackpad input and automatic display resizing. Selecting another
machine or closing the window keeps the guest running. Quitting with an active
macOS guest hides the app; stop the guest to quit completely. The app owns the
native session and its lifetime lock. CLI starts open a Machines app instance
for the selected library; **Open Desktop** focuses its embedded view. Or use:

```sh
glassdockctl machines desktop 'macOS'
```

The library and CLI support status, start, orderly shutdown, immediate power off,
pause, resume, stopped snapshots/restore, clone, and checksummed ZIP/folder
archives. An orderly shutdown may still require answering a guest prompt.

## Identity and portability

A machine stores a raw disk, hardware model, Apple machine identifier, and Mac
auxiliary storage together. Snapshots and archive migration preserve all four.
Cloning creates a new Apple identifier and network MAC, while preserving the
copied hardware model, auxiliary storage, and guest disk. Shut down before taking
a disk snapshot, cloning, or exporting. Apple's hardware-model compatibility is
checked on import and start. Archives contain no host paths, shared-folder
permissions, or active host shares. Installed archives omit the consumed IPSW.

## Sharing and supported devices

- Apple virtual graphics and audio output are enabled by default. Native Mac
  keyboard/trackpad input needs no guest tools.
- Networking uses Apple's NAT attachment. QEMU port forwarding is unavailable.
  Enable Remote Login inside macOS if you want SSH; `machines exec` explains that
  macOS has no QEMU guest agent.
- **Share Folder** enables a native VirtioFS share, read only by default. Supported
  macOS guests mount it automatically. Changing machines or stopping sharing
  revokes the share; each fresh VM run starts with no host folder shared.
- Clipboard synchronization, arbitrary USB forwarding, QEMU ISO media,
  Neptune/VirGL graphics, RAM checkpoints, and QCOW2 compaction are unavailable
  for this backend. The UI disables these options and the CLI rejects them.

## Worktree testing

Use `--library` in the CLI and `GLASSDOCK_VM_LIBRARY` when launching the preview to
avoid the installed app's normal library. Never point an older Machines app at a
library containing a newer profile it cannot decode.

References: [Apple's macOS virtualization sample](https://developer.apple.com/documentation/virtualization/virtualize-macos-on-a-mac),
[macOS installation](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine),
and the Virtualization.framework headers in the macOS SDK.
