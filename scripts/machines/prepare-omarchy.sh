#!/bin/bash
# Extract only factory guest artifacts; never launch or install Try Omarchy.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_dir="$root_dir/.build/machines"
destination="${1:-$runtime_dir/omarchy-quattro-4.0.4}"
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11 or later is required"'
command -v zstd >/dev/null || { echo 'Install zstd with Homebrew first.' >&2; exit 1; }
debugfs="$(command -v debugfs || true)"
[[ -n "$debugfs" ]] || debugfs="/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
[[ -x "$debugfs" ]] || { echo 'Install e2fsprogs with Homebrew first.' >&2; exit 1; }
[[ ! -e "$destination" ]] || { echo "Factory folder already exists: $destination" >&2; exit 1; }
mkdir -p "$runtime_dir/downloads" "$(dirname "$destination")"
dmg="$runtime_dir/downloads/TryOmarchy-v0.5.1.dmg"
if [[ ! -f "$dmg" ]]; then
  curl -fL --retry 3 https://github.com/omacom/try-omarchy/releases/download/v0.5.1/TryOmarchy.dmg -o "$dmg.partial"
  mv "$dmg.partial" "$dmg"
fi
printf '%s  %s\n' 03760f542025600ef29f77319c93d7c3640a3b15fcf73bda75b9caa9fcbd9999 "$dmg" | shasum -a 256 -c -
mount_dir="$(mktemp -d /tmp/glassdock-omarchy.XXXXXX)"
stage="$(mktemp -d "$(dirname "$destination")/.omarchy-prepare.XXXXXX")"
cleanup() {
  hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  rmdir "$mount_dir" 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg"
guest="$mount_dir/Try Omarchy.app/Contents/Resources/guest"
# Verify artifacts and budget the expanded root filesystem before decompression.
python3 - "$guest" "$stage" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
source, stage = map(Path, sys.argv[1:])
manifest = json.loads((source/'guest-manifest.json').read_text())
if (manifest['schemaVersion'] != 1 or manifest['kind'] != 'try-omarchy-guest-artifacts'
    or manifest['guest']['architecture'] != 'aarch64'
    or manifest['upstream']['release'] != '4.0.4' or manifest['upstream']['channel'] != 'quattro'):
    raise SystemExit('Unsupported Omarchy factory manifest')
artifacts = {a['path']: a for a in manifest['artifacts']}
if shutil.disk_usage(stage).free < artifacts['rootfs.ext4']['bytes'] + 2*1024**3:
    raise SystemExit('Not enough space for the expanded Omarchy factory and 2 GiB reserve')
files = ['rootfs.ext4.zst', 'vmlinuz-linux', 'initramfs-linux.img', 'build-spec.json', 'provenance.json', 'LICENSE.omarchy']
for name in files:
    path = source/name
    artifact = artifacts[name]
    if path.is_symlink() or not path.is_file() or path.stat().st_size != artifact['bytes']:
        raise SystemExit(f'Invalid factory artifact: {name}')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != artifact['sha256']:
        raise SystemExit(f'Factory checksum mismatch: {name}')
    if name != 'rootfs.ext4.zst': shutil.copyfile(path, stage/name)
shutil.copyfile(source/'guest-manifest.json', stage/'guest-manifest.json')
PY
zstd -d --sparse "$guest/rootfs.ext4.zst" -o "$stage/rootfs.ext4"
python3 - "$stage" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
artifact = next(a for a in json.loads((root/'guest-manifest.json').read_text())['artifacts'] if a['path'] == 'rootfs.ext4')
with (root/'rootfs.ext4').open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
if (root/'rootfs.ext4').stat().st_size != artifact['bytes'] or digest != artifact['sha256']:
    raise SystemExit('Expanded Omarchy root filesystem checksum mismatch')
PY
python3 "$root_dir/scripts/machines/guest/prepare-omarchy-integration.py" "$stage" "$root_dir/scripts/machines/guest" "$debugfs"
mv "$stage" "$destination"
echo "Prepared Omarchy Quattro 4.0.4: $destination"
echo 'Choose this folder in New Machine → Omarchy Quattro ARM64.'
