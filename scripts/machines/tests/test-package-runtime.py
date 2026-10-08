#!/usr/bin/env python3
"""Packaging regression: mapped helper/framework files must stay immutable."""
import os
import pathlib
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'package-runtime.py'
ROOTS = ['qemu-aarch64-softmmu', 'qemu-img', 'swtpm.0', 'spice-client-glib-2.0.8',
         'glib-2.0.0', 'gobject-2.0.0', 'gio-2.0.0', 'gstreamer-1.0.0',
         'gstapp-1.0.0', 'gstvideo-1.0.0', 'phodav-3.0.0', 'soup-3.0.0',
         'usb-1.0.0', 'usbredirhost.1', 'usbredirparser.1', 'EGL', 'GLESv2',
         'dxmt-native', 'vulkan.1']

class PackagingTests(unittest.TestCase):
    def test_cyclic_framework_alias_is_rejected_before_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary); source=root/'source'; app=root/'app'
            folder=source/'Contents/Frameworks/vulkan.1.framework'; folder.mkdir(parents=True)
            (folder/'vulkan.1').write_bytes(b'binary')
            (folder/'loop').symlink_to('loop')
            with patch.object(sys,'argv',[str(SCRIPT),str(source),str(app)]):
                with self.assertRaisesRegex(RuntimeError,'Invalid framework symlink'):
                    runpy.run_path(str(SCRIPT),run_name='__main__')
            self.assertFalse((app/'Contents/Frameworks/vulkan.1.framework').exists())

    def test_signing_and_relocation_preserve_open_executable_inodes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source, app = root / 'source', root / 'app'
            for base in [source, app]:
                for directory in ['Frameworks', 'MacOS', 'Resources/qemu']:
                    (base / 'Contents' / directory).mkdir(parents=True)
            for name in ROOTS:
                for base in [source, app]:
                    folder = base / 'Contents/Frameworks' / (name + '.framework')
                    folder.mkdir()
                    (folder / name).write_bytes(b'original-framework')
            server = source / 'Contents/MacOS/glassdock-render-server'
            server.write_bytes(b'new-server')
            held = []
            for name in ['glassdock-qemu', 'glassdock-vm-runner', 'glassdock-macos', 'GlassDockMachinesApp', 'glassdock-render-server']:
                binary = app / 'Contents/MacOS' / name
                binary.write_bytes(b'original-helper')
                binary.chmod(0o755)
                held.append((binary.open('rb'), b'original-helper'))
            binary = app / 'Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu'
            held.append((binary.open('rb'), b'original-framework'))
            def output(args, **kwargs):
                if args[0] == 'lipo': return 'arm64\n'
                if '-L' in args: return 'binary:\n'
                return 'cmd LC_RPATH\n path /old/runtime (offset 12)\n'
            signed = {}
            def run(args, **kwargs):
                if args[0] == 'codesign' and '--verify' not in args:
                    signed[pathlib.Path(args[-1]).name] = args
                if args[0] == 'ditto':
                    shutil.copytree(args[1], args[2], dirs_exist_ok=True)
                elif args[0] in ['codesign', 'install_name_tool'] and '--verify' not in args:
                    target = pathlib.Path(args[-1])
                    if target.suffix == '.framework': target = target / target.stem
                    if target.is_file():
                        # Model a real code-sign/load-command write to that inode.
                        with target.open('ab') as stream: stream.write(b'-modified')
            try:
                with patch.object(sys, 'argv', [str(SCRIPT), str(source), str(app)]), \
                     patch('subprocess.check_output', side_effect=output), \
                     patch('subprocess.run', side_effect=run):
                    runpy.run_path(str(SCRIPT), run_name='__main__')
                for stream, original in held:
                    self.assertEqual(stream.read(), original)
                self.assertIn(b'-modified', (app / 'Contents/MacOS/glassdock-qemu').read_bytes())
                for name in ['.GlassDockMachinesApp-staged', '.glassdock-macos-staged', app.name]:
                    arguments = signed[name]
                    self.assertIn('--entitlements', arguments)
                    entitlements = pathlib.Path(arguments[arguments.index('--entitlements') + 1])
                    self.assertEqual(entitlements.name, 'virtualization.entitlements')
            finally:
                for stream, _ in held: stream.close()

if __name__ == '__main__': unittest.main()
