#!/bin/bash
# Independent ARM64 build of the selected open-source UTM runtime components.
# No UTM application, D3DMetal, or decompiled iOS Hypervisor is built or packaged.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
work_dir="${GLASSDOCK_VM_SOURCE_WORK:-$root_dir/.build/machines/source-runtime}"
mkdir -p "$work_dir"
if [[ ! -d "$work_dir/upstream/.git" ]]; then
  git clone --depth 1 --branch v5.0.5 https://github.com/utmapp/UTM.git "$work_dir/upstream"
fi
[[ "$(git -C "$work_dir/upstream" rev-parse HEAD)" == b6f7475be54f9cb542c46b131319454b83489ced ]] || { echo "Unexpected upstream revision" >&2; exit 1; }
python3 -m venv "$work_dir/venv"
"$work_dir/venv/bin/pip" install -r "$root_dir/scripts/machines/requirements-build.txt"
# Keep changes explicit and reviewable; preserve upstream patches and build logic.
python3 - "$work_dir/upstream" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
s=(root/'scripts/build_dependencies.sh').read_text().replace('MAC_SDKMINVER="11.0"','MAC_SDKMINVER="15.0"')
# BSD ln otherwise follows an existing directory alias on resumed builds.
s=s.replace('ln -sf ', 'ln -sfn ')
for line in ['    clone $HYPERVISOR_REPO $HYPERVISOR_COMMIT\n','    clone $D3DMETAL_REPO $D3DMETAL_COMMIT\n','    clone $MESA_REPO $MESA_COMMIT\n','    clone $MOLTENVK_REPO $MOLTENVK_COMMIT\n','    clone_moltenvk_dependences $MOLTENVK_REPO\n','build_vulkan_drivers\n']:
    assert line in s,line
    s=s.replace(line,'')
# No Venus backend is exposed by GlassDock: Linux uses ANGLE, Windows DXMT.
s=s.replace('-Dvenus=true','-Dvenus=false')
# Xcode 27 diagnoses virtual destructors in final classes in the pinned WebKit.
s=s.replace('                                         CODE_SIGNING_ALLOWED=NO', '                                         CODE_SIGNING_ALLOWED=NO \\\n                                         WARNING_CFLAGS="$(inherited) -Wno-unnecessary-virtual-specifier -Wno-nontrivial-memcall -Wno-error=deprecated-declarations"')

a=s.index('    if [ "$ARCH" == "x86_64" -a "$PLATFORM" == "macos" ]; then',s.index('build_d3d_drivers ()'))
b=s.index('\n}',a)
s=s[:a]+s[b:]
s=s.replace('build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS','build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS --target-list=aarch64-softmmu --disable-pvg')
s=s.replace('build $QEMU_DIR --cross-prefix=""', '''qemu_patch="$GLASSDOCK_VM_SOURCE_PATCH_DIR/qemu-reconnect-surface.patch"
if patch -d "$QEMU_DIR" -p1 --dry-run < "$qemu_patch" >/dev/null 2>&1; then
    patch -d "$QEMU_DIR" -p1 < "$qemu_patch"
elif ! patch -d "$QEMU_DIR" -R -p1 --dry-run < "$qemu_patch" >/dev/null 2>&1; then
    echo "Unexpected QEMU surface transport patch state" >&2
    exit 1
fi
build $QEMU_DIR --cross-prefix=""''',1)
resume=__import__('os').environ.get('GLASSDOCK_VM_SOURCE_RESUME')
if resume in ('angle','qemu'):
    s=s.replace('    download_all\n','    : # resume existing sources\n').replace('copy_private_headers\n',': # private headers already prepared\n').replace('rm -rf "$PREFIX/"*','echo "Preserving completed dependencies"')
    if resume=='angle':
        start=s.index('    build $FFI_SRC',s.index('build_qemu_dependencies ()'))
        end=s.index('    build_angle',start)
        s=s[:start]+s[end:]
    else:
        s=s.replace('\nbuild_qemu_dependencies\n','\n: # reuse completed dependencies\n')
        s=s.replace('\nbuild_spice_client\n','\n: # reuse completed SPICE client\n')
        s=s.replace('\nbuild_d3d_drivers\n','\n: # reuse completed DXMT and LLVM\n')
s=s.replace('    cd "$BUILD_DIR/WebKit.git/Source/ThirdParty/ANGLE"', '    sed -i \'\' \'s/-D_LIBCPP_ENABLE_ASSERTIONS=1/-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE/g\' "$BUILD_DIR/WebKit.git/Configurations/CommonBase.xcconfig"\n    cd "$BUILD_DIR/WebKit.git/Source/ThirdParty/ANGLE"')
(root/'scripts/build_glassdock_runtime.sh').write_text(s)
p=root/'patches/sources'
s=p.read_text().replace('http://ftp.gnu.org/','https://ftp.gnu.org/').replace('http://xmlsoft.org/sources/libxml2-2.9.12.tar.gz','https://download.gnome.org/sources/libxml2/2.9/libxml2-2.9.12.tar.xz')
p.write_text(s)
PY
export PATH="$work_dir/venv/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/gettext/bin:/opt/homebrew/opt/libgpg-error/bin:$PATH"
export GLASSDOCK_VM_SOURCE_PATCH_DIR="$root_dir/scripts/machines/patches"
cd "$work_dir"
# WebKit's pinned ANGLE uses a libc++ switch removed in Xcode 27.
# Keep assertions enabled with the supported equivalent; do not disable checks.
python3 - "$work_dir" <<'PYANGLE'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'build-macOS-arm64/WebKit.git/Configurations/CommonBase.xcconfig'
if p.exists():
    p.write_text(p.read_text().replace('-D_LIBCPP_ENABLE_ASSERTIONS=1','-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE'))
PYANGLE
NCPU="${GLASSDOCK_VM_BUILD_JOBS:-4}" /bin/sh upstream/scripts/build_glassdock_runtime.sh -p macos -a arm64
# Adapt the sysroot layout to the runtime's portable bundle layout.
runtime="$work_dir/GlassDockRuntime"
mkdir -p "$runtime/Contents/Resources" "$runtime/Contents/MacOS"
python3 - "$work_dir/sysroot-macOS-arm64/Frameworks" "$runtime/Contents/Frameworks" <<'PYLINKS'
import pathlib,sys
for collection in map(pathlib.Path, sys.argv[1:]):
    for framework in collection.glob('*.framework'):
        for relative,target in [('Versions/A/A','A'),('Versions/A/Resources/Resources','Versions/Current/Resources')]:
            alias=framework/relative
            if alias.is_symlink() and str(alias.readlink())==target:
                alias.unlink()
PYLINKS
cp "$work_dir/sysroot-macOS-arm64/libexec/virgl_render_server" "$runtime/Contents/MacOS/glassdock-render-server"
ditto "$work_dir/sysroot-macOS-arm64/Frameworks" "$runtime/Contents/Frameworks"
ditto "$work_dir/sysroot-macOS-arm64/share/qemu" "$runtime/Contents/Resources/qemu"
python3 "$root_dir/scripts/machines/runtime-notices.py" "$work_dir"
echo "Source runtime: $runtime"
echo "Build with GLASSDOCK_VM_RUNTIME_SOURCE='$runtime' bash scripts/machines/build-app.sh"
