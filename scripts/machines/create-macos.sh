#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo 'Usage: scripts/machines/create-macos.sh /path/to/Restore.ipsw [name] [machines create options]' >&2
  echo 'Find a compatible IPSW with glassdockctl machines restore-image.' >&2
  exit 1
fi
restore_image="$1"
shift
machine_name="${1:-macOS}"
if [[ $# -gt 0 ]]; then shift; fi
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_source="${GLASSDOCK_VM_RUNTIME_SOURCE:-/Applications/GlassDock Machines.app}"
GLASSDOCK_VM_RUNTIME_SOURCE="$runtime_source" bash "$root_dir/scripts/machines/build-app.sh"
core_bin="$(swift build --package-path "$root_dir" --show-bin-path)"
export GLASSDOCK_VM_RUNTIME="$root_dir/.build/machines/GlassDock Machines.app"
export GLASSDOCK_VM_BIN="$GLASSDOCK_VM_RUNTIME/Contents/MacOS"
"$core_bin/glassdockctl" machines create "$machine_name" --os macos --ipsw "$restore_image" "$@"
echo 'Created macOS machine. Open the worktree Machines app and start it to install macOS.'
