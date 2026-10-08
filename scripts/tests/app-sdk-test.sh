#!/bin/bash
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
# A compiled fixture verifies load commands and signing, without launching UI.
printf 'print("SDK fixture")\n' > "$fixture/main.swift"
xcrun swiftc -target arm64-apple-macosx15.0 "$fixture/main.swift" -o "$fixture/app"
xcrun vtool -set-build-version macos 15.0 15.0 -replace -output "$fixture/legacy" "$fixture/app"
chmod 755 "$fixture/legacy"
bash "$root_dir/scripts/stamp-app-sdk.sh" "$fixture/legacy"
build_info="$(xcrun vtool -show-build "$fixture/legacy")"
[[ "$(awk '$1 == "minos" {print $2; exit}' <<< "$build_info")" == "15.0" ]]
[[ "$(awk '$1 == "sdk" {print $2; exit}' <<< "$build_info")" == "$(xcrun --sdk macosx --show-sdk-version)" ]]
[[ -x "$fixture/legacy" ]]
codesign --force --sign - "$fixture/legacy"
codesign --verify --strict "$fixture/legacy"
[[ "$("$fixture/legacy")" == "SDK fixture" ]]
echo "App SDK stamping preserves deployment, execution, and valid signing."
