#!/bin/bash
# Runs inside the Omarchy guest. Pacman authenticates ARM packages with the
# factory's Arch Linux ARM keyring; its pinned kernel/graphics IgnorePkg stays.
set -euo pipefail
pacman -Syu --needed --noconfirm qemu-guest-agent davfs2
systemctl enable --now qemu-guest-agent.service
mkdir -p /var/lib/glassdock
touch /var/lib/glassdock/integration-v1
