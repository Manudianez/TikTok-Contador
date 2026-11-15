#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="$(mktemp -d /tmp/tiktok-contador.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/TikTok Contador.app"
mkdir -p "$app/Contents/MacOS" dist
cp Info.plist "$app/Contents/Info.plist"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    TikTokCounter.swift -o "$app/Contents/MacOS/TikTokCounter"
codesign --force --sign - "$app"
codesign --verify "$app"
ditto --norsrc --noextattr "$app" "dist/TikTok Contador.app"
printf 'App creada en dist/TikTok Contador.app\n'
