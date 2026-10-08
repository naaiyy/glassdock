#!/usr/bin/env python3
"""Collect notices and reproducible source identities for a local source build.

Notices alone do not satisfy corresponding-source obligations for distribution.
Keep the source work directory and publish corresponding source with releases.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


work = pathlib.Path(sys.argv[1]).resolve()
resources = work / "GlassDockRuntime/Contents/Resources"
notices = resources / "Licenses"
notices.mkdir(parents=True, exist_ok=True)
sources = {}
for source in sorted((work / "build-macOS-arm64").iterdir()):
    if source.is_file() and ".tar." in source.name:
        sources[source.name] = {"sha256": digest(source)}
    elif source.is_dir():
        if (source / ".git").exists():
            sources[source.name] = {
                "commit": subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
                "patchSha256": hashlib.sha256(subprocess.check_output(["git", "-C", str(source), "diff", "--binary", "HEAD"])).hexdigest(),
            }
        candidates = list(source.glob("*")) + list(source.glob("*/*"))
        if source.name == "WebKit.git":
            candidates += list((source / "Source/ThirdParty/ANGLE").glob("*"))
        if source.name.startswith("qemu-"):
            candidates += list((source / "pc-bios").glob("*licenses.txt"))
            candidates += [source / "pc-bios/README"]
        for notice in candidates:
            if notice.is_file() and (notice.name.upper().startswith(("COPYING", "LICENSE", "NOTICE", "COPYRIGHT")) or notice.parent.name == "pc-bios"):
                target = notices / source.name / notice.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(notice, target)
        for folder in (source / "LICENSES", source / "licenses"):
            if folder.is_dir():
                shutil.copytree(folder, notices / source.name / folder.name, dirs_exist_ok=True)
upstream = work / "upstream"
provenance = {
    "schemaVersion": 1,
    "upstreamCommit": subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip(),
    "buildScriptSha256": digest(upstream / "scripts/build_glassdock_runtime.sh"),
    "sourceManifestSha256": digest(upstream / "patches/sources"),
    "glassdockPatches": {
        patch.name: digest(patch)
        for patch in sorted((pathlib.Path(__file__).resolve().parent / "patches").glob("*.patch"))
    },
    "sources": sources,
}
(resources / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
print(f"Collected notices and {len(sources)} source identities")
