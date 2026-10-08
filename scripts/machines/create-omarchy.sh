#!/bin/bash
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root_dir"
name="${1:-Omarchy Quattro}"
ssh_port="${2:-22223}"
guest="$root_dir/.build/machines/omarchy-quattro-4.0.4"
[[ -d "$guest" ]] || bash scripts/machines/prepare-omarchy.sh "$guest"
# Build the profile-aware viewer and signed helpers in this checkout. An older
# installed app cannot decode the new profile; reuse only its runtime frameworks.
runtime_source="${GLASSDOCK_VM_RUNTIME_SOURCE:-${GLASSDOCK_VM_RUNTIME:-}}"
if [[ -z "$runtime_source" && -d '/Applications/GlassDock Machines.app' ]]; then
  runtime_source='/Applications/GlassDock Machines.app'
fi
if [[ -n "$runtime_source" ]]; then
  GLASSDOCK_VM_RUNTIME_SOURCE="$runtime_source" bash scripts/machines/build-app.sh
else
  bash scripts/machines/build-app.sh
fi
bin_dir="$(swift build --show-bin-path)"
app="$root_dir/.build/machines/GlassDock Machines.app"
GLASSDOCK_VM_RUNTIME="$app" GLASSDOCK_VM_BIN="$app/Contents/MacOS" \
  "$bin_dir/glassdockctl" machines create "$name" --os omarchy --omarchy-guest "$guest" --ssh-port "$ssh_port"
echo "Created $name. Start it in $app and complete Omarchy's owner setup."
