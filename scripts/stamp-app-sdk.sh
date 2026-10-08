#!/bin/bash
# SwiftPM's build engine can write the deployment version into the SDK field.
# AppKit uses this field for linked-on-or-after design behavior. Record the SDK
# actually used by Xcode without changing the app's minimum supported macOS.
# Run before signing; load-command edits invalidate the previous signature.
set -euo pipefail
binary="${1:?Usage: stamp-app-sdk.sh <app-executable>}"
build_info="$(xcrun vtool -show-build "$binary")"
deployment="$(awk '$1 == "minos" { print $2; exit }' <<< "$build_info")"
linker_version="$(awk '$1 == "tool" && $2 == "LD" { found=1; next } found && $1 == "version" { print $2; exit }' <<< "$build_info")"
sdk="$(xcrun --sdk macosx --show-sdk-version)"
if [[ -z "$deployment" ]]; then
    echo "Cannot read the app's macOS deployment version: $binary" >&2
    exit 1
fi
staged="$(mktemp "${binary}.sdk.XXXXXX")"
trap 'rm -f "$staged"' EXIT
arguments=(-set-build-version macos "$deployment" "$sdk")
if [[ -n "$linker_version" ]]; then arguments+=(-tool ld "$linker_version"); fi
xcrun vtool "${arguments[@]}" -replace -output "$staged" "$binary"
chmod "$(stat -f '%Lp' "$binary")" "$staged"
mv -f "$staged" "$binary"
