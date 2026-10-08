#!/bin/bash
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_dir="$root_dir/.build/machines"
mkdir -p "$runtime_dir"
cat > "$runtime_dir/hypervisor.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST
cat > "$runtime_dir/virtualization.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
# Installation and signing precede running a guest with Hypervisor.framework.
if [[ -z "${GLASSDOCK_VM_RUNTIME_SOURCE:-}" ]]; then bash "$root_dir/scripts/machines/install-runtime.sh"; fi
swift build --package-path "$root_dir" --product glassdock-macos
swift build --package-path "$root_dir" --product glassdockctl
swift build --package-path "$root_dir" --product glassdock-vm-runner
swift build --package-path "$root_dir" --product glassdock-qemu
if [[ ! -d "$runtime_dir/CocoaSpice/.git" ]]; then
  git clone https://github.com/utmapp/CocoaSpice.git "$runtime_dir/CocoaSpice"
  git -C "$runtime_dir/CocoaSpice" checkout 127033fa3e59cd49678f49ed54f8adfc060afb56
fi
if [[ "$(git -C "$runtime_dir/CocoaSpice" rev-parse HEAD)" != "127033fa3e59cd49678f49ed54f8adfc060afb56" ]]; then
  echo "CocoaSpice checkout does not match the pinned revision" >&2
  exit 1
fi
if git -C "$runtime_dir/CocoaSpice" apply --check "$root_dir/scripts/machines/patches/cocoaspice-dynamic-gstreamer.patch" 2>/dev/null; then
  git -C "$runtime_dir/CocoaSpice" apply "$root_dir/scripts/machines/patches/cocoaspice-dynamic-gstreamer.patch"
elif ! git -C "$runtime_dir/CocoaSpice" apply --reverse --check "$root_dir/scripts/machines/patches/cocoaspice-dynamic-gstreamer.patch"; then
  echo "CocoaSpice patch state is unexpected" >&2
  exit 1
fi
if git -C "$runtime_dir/CocoaSpice" apply --check "$root_dir/scripts/machines/patches/cocoaspice-initial-frame.patch" 2>/dev/null; then
  git -C "$runtime_dir/CocoaSpice" apply "$root_dir/scripts/machines/patches/cocoaspice-initial-frame.patch"
elif ! git -C "$runtime_dir/CocoaSpice" apply --reverse --check "$root_dir/scripts/machines/patches/cocoaspice-initial-frame.patch"; then
  echo "CocoaSpice initial-frame patch state is unexpected" >&2
  exit 1
fi
if git -C "$runtime_dir/CocoaSpice" apply --check "$root_dir/scripts/machines/patches/cocoaspice-atomic-key-stroke.patch" 2>/dev/null; then
  git -C "$runtime_dir/CocoaSpice" apply "$root_dir/scripts/machines/patches/cocoaspice-atomic-key-stroke.patch"
elif ! git -C "$runtime_dir/CocoaSpice" apply --reverse --check "$root_dir/scripts/machines/patches/cocoaspice-atomic-key-stroke.patch"; then
  echo "CocoaSpice keyboard patch state is unexpected" >&2
  exit 1
fi
patch="$root_dir/scripts/machines/patches/cocoaspice-explicit-sharing-usb.patch"
if git -C "$runtime_dir/CocoaSpice" apply --check "$patch" 2>/dev/null; then
  git -C "$runtime_dir/CocoaSpice" apply "$patch"
elif ! git -C "$runtime_dir/CocoaSpice" apply --reverse --check "$patch"; then
  echo "CocoaSpice sharing/USB patch state is unexpected" >&2
  exit 1
fi
swift build --package-path "$root_dir/Apps/GlassDockMachines" --product GlassDockMachinesApp
ui_bin="$(swift build --package-path "$root_dir/Apps/GlassDockMachines" --show-bin-path)"
core_bin="$(swift build --package-path "$root_dir" --show-bin-path)"
sign_development_binary() {
  local binary="$1" staged
  staged="$(mktemp "$core_bin/.signed.XXXXXX")"
  cp "$binary" "$staged"
  chmod 755 "$staged"
  if [[ "$(basename "$binary")" == "glassdock-qemu" ]]; then
    codesign --force --sign - --entitlements "$runtime_dir/hypervisor.entitlements" "$staged"
  elif [[ "$(basename "$binary")" == "glassdock-macos" ]]; then
    codesign --force --sign - --entitlements "$runtime_dir/virtualization.entitlements" "$staged"
  else
    codesign --force --sign - "$staged"
  fi
  mv -f "$staged" "$binary"
}
sign_development_binary "$core_bin/glassdock-macos"
sign_development_binary "$core_bin/glassdockctl"
sign_development_binary "$core_bin/glassdock-vm-runner"
sign_development_binary "$core_bin/glassdock-qemu"
app="$runtime_dir/GlassDock Machines.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Replace executable inodes atomically: overwriting a mapped, signed binary can
# kill a running viewer or VM when macOS faults in a modified code page.
install_binary() {
  local source="$1" name="$2"
  local staged
  staged="$(mktemp "$app/Contents/MacOS/.binary.XXXXXX")"
  cp "$source" "$staged"
  chmod 755 "$staged"
  if [[ "$name" == "GlassDockMachinesApp" ]]; then
    bash "$root_dir/scripts/stamp-app-sdk.sh" "$staged"
  fi
  if [[ "$name" == "glassdock-qemu" ]]; then
    codesign --force --sign - --entitlements "$runtime_dir/hypervisor.entitlements" "$staged"
  elif [[ "$name" == "glassdock-macos" || "$name" == "GlassDockMachinesApp" ]]; then
    codesign --force --sign - --entitlements "$runtime_dir/virtualization.entitlements" "$staged"
  else
    codesign --force --sign - "$staged"
  fi
  mv -f "$staged" "$app/Contents/MacOS/$name"
}
install_binary "$core_bin/glassdock-macos" glassdock-macos
install_binary "$ui_bin/GlassDockMachinesApp" GlassDockMachinesApp
install_binary "$core_bin/glassdock-qemu" glassdock-qemu
install_binary "$core_bin/glassdock-vm-runner" glassdock-vm-runner
if [[ -d "$ui_bin/CocoaSpice_CocoaSpiceRenderer.bundle" ]]; then
  ditto "$ui_bin/CocoaSpice_CocoaSpiceRenderer.bundle" "$app/Contents/Resources/CocoaSpice_CocoaSpiceRenderer.bundle"
fi
for dependency in "$root_dir" "$runtime_dir/CocoaSpice" "$root_dir/.build/checkouts/ZIPFoundation"; do
  name="$(basename "$dependency")"
  mkdir -p "$app/Contents/Resources/Licenses/$name"
  staged_license="$(mktemp "$app/Contents/Resources/Licenses/$name/.license.XXXXXX")"
  cp "$dependency/LICENSE" "$staged_license"
  chmod 644 "$staged_license"
  mv -f "$staged_license" "$app/Contents/Resources/Licenses/$name/LICENSE"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.glassdock.machines</string>
<key>CFBundleName</key><string>GlassDock Machines</string>
<key>CFBundleExecutable</key><string>GlassDockMachinesApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 "$root_dir/scripts/machines/package-runtime.py" "${GLASSDOCK_VM_RUNTIME_SOURCE:-$runtime_dir/UTM.app}" "$app"
echo "$app"
