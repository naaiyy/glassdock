# Socktainer

Monitor the local Socktainer daemon and control container workloads from
Raycast.

## Requirements

- macOS on Apple Silicon
- Socktainer and `socktainerctl` installed on the same user account
- Raycast 1.26 or later

The extension checks these standard command locations:

- `/opt/socktainer/bin/socktainerctl`
- `/opt/homebrew/bin/socktainerctl`
- `/usr/local/bin/socktainerctl`

If the command is elsewhere, set **socktainerctl Executable** in the extension
preferences to its absolute path.

## Command

**Socktainer** is one searchable view. It shows daemon status, containers, and
diagnostics. Open a status or diagnostics item for detail. Container items keep
start, stop, log, and copy-ID actions in their action panels.

The extension does not use a shell. It sends fixed arguments to
`socktainerctl`. It does not send data to an external service. Stop and restart
are available only for a daemon that Socktainer Control manages. Daemon stop
and restart are blocked while a container is running.

## Local development

From the repository root:

```sh
make control
make raycast-install
cd raycast
npm run dev
```

For a source build, set **socktainerctl Executable** to the absolute path of
`.build/debug/socktainerctl`. You can also put a reversible link in a standard
location before you start Raycast development mode:

```sh
ln -s "$(cd .. && pwd)/.build/debug/socktainerctl" /opt/homebrew/bin/socktainerctl
```
