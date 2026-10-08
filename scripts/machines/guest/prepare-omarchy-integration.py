#!/usr/bin/env python3
"""Adapt a verified factory copy; keep the original disk hash in provenance."""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def quoted(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def prepare(root, payload, debugfs):
    disk = root / 'rootfs.ext4'
    manifest_path = root / 'guest-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    original = next(a for a in manifest['artifacts'] if a['path'] == 'rootfs.ext4')
    if digest(disk) != original['sha256']:
        raise ValueError('Factory disk must be verified before adaptation')
    files = {
        '/usr/local/lib/glassdock/omarchy-integration.sh': payload / 'omarchy-integration.sh',
        '/etc/systemd/system/glassdock-omarchy-integration.service': payload / 'glassdock-omarchy-integration.service',
    }
    with tempfile.TemporaryDirectory(prefix='glassdock-omarchy-integration-') as temporary:
        commands = ['mkdir /usr/local/lib/glassdock']
        for target, source in files.items():
            commands.append(f'write {quoted(source)} {target}')
            commands.append(f'set_inode_field {target} mode 0100644')
        commands.append('symlink /etc/systemd/system/multi-user.target.wants/glassdock-omarchy-integration.service /etc/systemd/system/glassdock-omarchy-integration.service')
        command_file = Path(temporary) / 'commands'
        command_file.write_text('\n'.join(commands) + '\n')
        subprocess.run([str(debugfs), '-w', '-f', str(command_file), str(disk)], check=True)
        # debugfs may return zero for a failed write. Verify the resulting bytes
        # and enablement explicitly before publishing this adapted factory.
        for index, (target, source) in enumerate(files.items()):
            dumped = Path(temporary) / str(index)
            subprocess.run([str(debugfs), '-R', f'dump {target} {quoted(dumped)}', str(disk)], check=True)
            if dumped.read_bytes() != source.read_bytes():
                raise ValueError(f'Guest integration write failed: {target}')
        enabled = subprocess.run([str(debugfs), '-R', 'stat /etc/systemd/system/multi-user.target.wants/glassdock-omarchy-integration.service', str(disk)], check=True, capture_output=True, text=True)
        if 'Fast link dest: "/etc/systemd/system/glassdock-omarchy-integration.service"' not in enabled.stdout:
            raise ValueError('Guest integration service was not enabled')
    provenance_path = root / 'provenance.json'
    provenance = json.loads(provenance_path.read_text())
    provenance['glassdockIntegration'] = {
        'version': 1,
        'factoryRootfsSHA256': original['sha256'],
        'files': {target: digest(source) for target, source in files.items()},
        'packages': ['qemu-guest-agent', 'davfs2'],
        'packagePolicy': 'Signed Arch Linux ARM packages, installed at first boot with pacman -Syu; factory IgnorePkg preserved',
    }
    provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    for artifact in manifest['artifacts']:
        if artifact['path'] in ('rootfs.ext4', 'provenance.json'):
            path = root / artifact['path']
            artifact.update(bytes=path.stat().st_size, sha256=digest(path))
    # The compressed upstream disk is no longer the adapted raw disk. Do not
    # retain its entry in the manifest of the prepared folder.
    manifest['artifacts'] = [a for a in manifest['artifacts'] if a['path'] != 'rootfs.ext4.zst']
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    prepare(*map(Path, sys.argv[1:]))
