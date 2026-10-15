#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"

swift build -c release
task_bin_dir="$(swift build -c release --show-bin-path)"
task_app="$task_root/dist/Big Water.app"
task_art="$task_root/dist/Artwork"

mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
"$task_bin_dir/BigWaterArtwork" "$task_art"
cp "$task_bin_dir/BigWater" "$task_app/Contents/MacOS/BigWater.new"
mv -f "$task_app/Contents/MacOS/BigWater.new" "$task_app/Contents/MacOS/BigWater"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
iconutil -c icns "$task_art/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$task_app"

echo "App: $task_app"
