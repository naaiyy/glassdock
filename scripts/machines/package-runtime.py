#!/usr/bin/env python3
"""Package only the dependency closure used by GlassDock, never the UTM app.

Input may be the verified development bundle or an independently built runtime
with the same Contents/{Frameworks,Resources/qemu} layout. This does not turn
prebuilt dependencies into a source build or grant distribution rights.
"""
import hashlib,json,pathlib,re,shutil,subprocess,sys,tempfile
source=pathlib.Path(sys.argv[1]).resolve()
app=pathlib.Path(sys.argv[2]).resolve()
frameworks=source/'Contents/Frameworks'
destination=app/'Contents/Frameworks'
destination.mkdir(parents=True,exist_ok=True)
roots=['qemu-aarch64-softmmu','qemu-img','swtpm.0','spice-client-glib-2.0.8','glib-2.0.0','gobject-2.0.0','gio-2.0.0','gstreamer-1.0.0','gstapp-1.0.0','gstvideo-1.0.0','phodav-3.0.0','soup-3.0.0','usb-1.0.0','usbredirhost.1','usbredirparser.1','EGL','GLESv2','dxmt-native','vulkan.1']
seen=set();queue=list(roots)
while queue:
    name=queue.pop()
    if name in seen:continue
    if name in ('D3DMetal','d3dmetal-native','Hypervisor'):raise RuntimeError('Excluded dependency: '+name)
    folder=frameworks/(name+'.framework');binary=folder/name
    if not binary.is_file():raise RuntimeError('Missing dependency: '+str(binary))
    for alias in folder.rglob('*'):
        if alias.is_symlink():
            try:resolved_alias=alias.resolve(strict=True)
            except (RuntimeError,OSError) as error:raise RuntimeError('Invalid framework symlink: '+str(alias)) from error
            if not resolved_alias.is_relative_to(folder.resolve()):raise RuntimeError('External framework symlink: '+str(alias))
    seen.add(name)
    output=subprocess.check_output(['otool','-arch','arm64','-L',str(binary)],text=True)
    for line in output.splitlines()[1:]:
        dependency=line.strip().split(' (')[0]
        if dependency.startswith('@rpath/'):
            m=re.match(r'@rpath/([^/]+)\.framework/',dependency)
            if not m:raise RuntimeError('Unexpected runtime dependency: '+dependency)
            queue.append(m[1])
        elif not dependency.startswith(('/System/Library/','/usr/lib/')):
            raise RuntimeError('Nonportable dependency: '+dependency)
    # Preserve mapped executable inodes when rebuilding with guests still running.
    staging=pathlib.Path(tempfile.mkdtemp(prefix='.runtime-',dir=destination))
    staged=staging/folder.name
    target=destination/folder.name
    subprocess.run(['ditto',str(folder),str(staged)],check=True)
    # Thin universal runtime binaries for this ARM-only product.
    resolved=(staged/name).resolve()
    temporary=resolved.with_suffix('.arm64')
    if subprocess.check_output(['lipo','-archs',str(resolved)],text=True).strip()=='arm64':shutil.copyfile(resolved,temporary)
    else:subprocess.run(['lipo',str(resolved),'-thin','arm64','-output',str(temporary)],check=True)
    temporary.replace(resolved)
    subprocess.run(['codesign','--force','--sign','-',str(staged)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    previous=staging/'previous.framework'
    if target.exists():target.rename(previous)
    try:staged.rename(target)
    except BaseException:
        if previous.exists():previous.rename(target)
        raise
    shutil.rmtree(staging)
resources=app/'Contents/Resources';resources.mkdir(parents=True,exist_ok=True)
firmware=resources/'qemu'
if firmware.exists():shutil.rmtree(firmware)
subprocess.run(['ditto',str(source/'Contents/Resources/qemu'),str(firmware)],check=True)
for name in ('Licenses', 'source-provenance.json'):
    original=source/'Contents/Resources'/name
    target=resources/name
    if original.is_dir():shutil.copytree(original,target,dirs_exist_ok=True)
    elif original.is_file():shutil.copyfile(original,target)
legacy=resources/'UTM.app'
if legacy.is_symlink():legacy.unlink()
server=source/'Contents/MacOS/glassdock-render-server'
if not server.exists():server=source/'Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer'
if not server.is_file():raise RuntimeError('Missing open-source virgl render-server executable')
server_target=app/'Contents/MacOS/glassdock-render-server'
server_stage=server_target.with_name('.render-server-staged')
if subprocess.check_output(['lipo','-archs',str(server)],text=True).strip()=='arm64':shutil.copyfile(server,server_stage)
else:subprocess.run(['lipo',str(server),'-thin','arm64','-output',str(server_stage)],check=True)
server_stage.chmod(0o755)
subprocess.run(['codesign','--force','--sign','-',str(server_stage)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
server_stage.replace(server_target)
for executable in (app/'Contents/MacOS').iterdir():
    if not executable.is_file() or executable.name.startswith('.'):continue
    # All load-command edits and signing happen on a new inode. Even signing
    # alone can invalidate pages in a helper that already hosts a running VM.
    staged_executable=executable.with_name('.'+executable.name+'-staged')
    shutil.copy2(executable,staged_executable)
    output=subprocess.check_output(['otool','-l',str(staged_executable)],text=True)
    for path in re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset',output,re.S):
        if not path.startswith('@'):subprocess.run(['install_name_tool','-delete_rpath',path,str(staged_executable)],check=True)
    if '@executable_path/../Frameworks' not in output:
        subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(staged_executable)],check=True)
    args=['codesign','--force','--sign','-']
    if executable.name=='glassdock-qemu':args+=['--entitlements',str(pathlib.Path(__file__).resolve().parents[2]/'.build/machines/hypervisor.entitlements')]
    subprocess.run(args+[str(staged_executable)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    staged_executable.replace(executable)
manifest={}
for name in sorted(seen):
    binary=(destination/(name+'.framework')/name).resolve()
    manifest[name]=hashlib.sha256(binary.read_bytes()).hexdigest()
files={}
for root in (app/'Contents/MacOS', firmware):
    for path in sorted(root.rglob('*')):
        # The app's final signature changes its main executable and seals this
        # manifest, so hashing that executable here would be self-referential.
        if path.is_file() and not path.is_symlink() and path.name!='GlassDockMachinesApp':
            digest=hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
            files[str(path.relative_to(app/'Contents'))]=digest.hexdigest()
(resources/'runtime-artifacts.json').write_text(json.dumps({'schemaVersion':1,'provenance':source.name,'frameworks':manifest,'files':files},indent=2)+'\n')
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Packaged '+str(len(seen))+' ARM64 frameworks; strict signature verification passed.')
