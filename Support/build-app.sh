#!/bin/zsh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
swift build -c release --product TubeUI
app="$root/TubeUI.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/TubeUI" "$app/Contents/MacOS/TubeUI"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
swift "$root/Support/MakeIcon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
codesign --force --sign - "$app"
echo "$app"
