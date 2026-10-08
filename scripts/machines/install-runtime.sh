#!/bin/bash
# Development runtime only. Final distribution must build the pinned open-source
# frameworks and omit Apple's proprietary D3DMetal runtime from the UTM bundle.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_dir="$root_dir/.build/machines"
mkdir -p "$runtime_dir/downloads"
dmg="$runtime_dir/downloads/UTM-5.0.5.dmg"
if [[ ! -f "$dmg" ]]; then
  curl -fL --retry 3 https://github.com/utmapp/UTM/releases/download/v5.0.5/UTM.dmg -o "$dmg.partial"
  mv "$dmg.partial" "$dmg"
fi
printf '%s  %s\n' 713afe73c711f01344b8766654be531cd391ed2e30931206f43b5159f143764f "$dmg" | shasum -a 256 -c -
if [[ ! -d "$runtime_dir/UTM.app" ]]; then
  mount_dir="$(mktemp -d /tmp/glassdock-utm.XXXXXX)"
  trap 'hdiutil detach "$mount_dir" >/dev/null 2>&1 || true; rmdir "$mount_dir" 2>/dev/null || true' EXIT
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg"
  ditto "$mount_dir/UTM.app" "$runtime_dir/UTM.app"
fi
codesign --verify --deep --strict "$runtime_dir/UTM.app"
swift build --package-path "$root_dir" --product glassdock-qemu
swift build --package-path "$root_dir" --product glassdock-vm-runner
cat > "$runtime_dir/hypervisor.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST
bin_dir="$(swift build --package-path "$root_dir" --show-bin-path)"
codesign --force --sign - --entitlements "$runtime_dir/hypervisor.entitlements" "$bin_dir/glassdock-qemu"
"$bin_dir/glassdock-qemu" "$runtime_dir/UTM.app/Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" --version
