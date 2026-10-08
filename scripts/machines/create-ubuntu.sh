#!/bin/bash
# Reproducible development guest; SSH key stays in ignored .build/machines/seed.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root_dir"
umask 077
runtime_dir="$root_dir/.build/machines"
name="${1:-Ubuntu Linux}"
ssh_port="${2:-22222}"
mkdir -p "$runtime_dir/downloads" "$runtime_dir/seed"
command -v xorriso >/dev/null || { echo 'Install xorriso with Homebrew first.' >&2; exit 1; }
bash scripts/machines/install-runtime.sh
swift build --product glassdockctl
bin_dir="$(swift build --show-bin-path)"
image="$runtime_dir/downloads/ubuntu-24.04-arm64.qcow2"
checksums="$runtime_dir/downloads/ubuntu-SHA256SUMS"
# Download image and checksum as one release pair; do not refresh only one.
if [[ ! -f "$image" || ! -f "$checksums" ]]; then
  curl -fL --retry 3 https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img -o "$image.partial"
  curl -fL --retry 3 https://cloud-images.ubuntu.com/noble/current/SHA256SUMS -o "$checksums.partial"
  mv "$image.partial" "$image"
  mv "$checksums.partial" "$checksums"
fi
expected="$(awk '$2 == "*noble-server-cloudimg-arm64.img" || $2 == "noble-server-cloudimg-arm64.img" { print $1 }' "$checksums")"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { echo 'Ubuntu checksum manifest is invalid.' >&2; exit 1; }
printf '%s  %s\n' "$expected" "$image" | shasum -a 256 -c -
key="$runtime_dir/seed/id_ed25519"
[[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C glassdock-development-guest -f "$key"
seed_dir="$(mktemp -d "$runtime_dir/seed/cloud-init.XXXXXX")"
trap 'rm -rf "$seed_dir"' EXIT
python3 - "$key.pub" "$seed_dir" <<'PY'
from pathlib import Path
import sys,uuid
key = Path(sys.argv[1]).read_text().strip().replace("'", "''")
root = Path(sys.argv[2])
(root/'meta-data').write_text(f'instance-id: glassdock-{uuid.uuid4()}\nlocal-hostname: glassdock-linux\n')
(root/'network-config').write_text('version: 2\nethernets:\n  guest:\n    match:\n      name: "en*"\n    dhcp4: true\n    optional: true\n')
(root/'user-data').write_text(f'''#cloud-config
users:
  - name: glassdock
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - '{key}'
packages: [qemu-guest-agent, spice-vdagent, xfce4, mousepad, lightdm, xserver-xorg, mesa-utils, davfs2, spice-webdavd, linux-generic, alsa-utils, pulseaudio]
write_files:
  - path: /etc/lightdm/lightdm.conf.d/50-glassdock.conf
    content: |
      [Seat:*]
      autologin-user=glassdock
      autologin-user-timeout=0
      autologin-session=xfce
      user-session=xfce
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
  - [systemctl, set-default, graphical.target]
  - [systemctl, enable, --now, lightdm]
''')
PY
iso="$seed_dir/cloud-init.iso"
xorriso -as mkisofs -quiet -o "$iso" -V cidata -J -r "$seed_dir/user-data" "$seed_dir/meta-data" "$seed_dir/network-config"
"$bin_dir/glassdockctl" machines create "$name" --os linux --disk "$image" --seed "$iso" --ssh-port "$ssh_port"
echo "Created $name. Start it in GlassDock Machines. Cloud-init installs the desktop on first boot."
