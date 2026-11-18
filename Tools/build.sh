#!/usr/bin/env bash
# Builds dist/Big Water.app for this Mac, or for both chip families with
# --universal. The app is signed ad hoc, which is enough to run it locally.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

universal=false
case "${1:-}" in
    "") ;;
    --universal) universal=true ;;
    -h|--help) echo "Usage: $0 [--universal]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac

fail() { echo "$1" >&2; exit 1; }

app="$root/dist/Big Water.app"
art="$root/dist/Artwork"
executable="$app/Contents/MacOS/BigWater"
sparkle_src="$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
sparkle_dst="$app/Contents/Frameworks/Sparkle.framework"

# The icon is drawn by the same code as the app's pixel art.
swift build -c release --product BigWaterArtwork
"$(swift build -c release --product BigWaterArtwork --show-bin-path)/BigWaterArtwork" "$art"

binaries=()
if [[ "$universal" == true ]]; then
    for triple in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
        swift build -c release --product BigWater --triple "$triple"
        binaries+=("$(swift build -c release --product BigWater --triple "$triple" --show-bin-path)/BigWater")
    done
else
    swift build -c release --product BigWater
    binaries+=("$(swift build -c release --product BigWater --show-bin-path)/BigWater")
fi

[[ -d "$sparkle_src" ]] || fail "Sparkle.framework is missing: $sparkle_src
Run 'swift package resolve' first."

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Sparkle-LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
iconutil -c icns "$art/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

# Written beside the old binary and moved into place, so a copy that is
# running keeps a whole executable until it quits.
if [[ "$universal" == true ]]; then
    lipo -create "${binaries[@]}" -output "$executable.new"
else
    cp "${binaries[0]}" "$executable.new"
fi
mv -f "$executable.new" "$executable"

# ditto keeps Sparkle's symlinks, executable bits and nested signatures.
rm -rf "$sparkle_dst"
ditto "$sparkle_src" "$sparkle_dst"

[[ -x "$executable" && -x "$sparkle_dst/Autoupdate" ]] \
    || fail "The app or Sparkle's updater lost its executable permission."
for link in Versions/Current Sparkle Updater.app XPCServices; do
    [[ -L "$sparkle_dst/$link" ]] || fail "Sparkle.framework lost its symlink: $link"
done
[[ "$(otool -l "$executable")" == *'@executable_path/../Frameworks'* ]] \
    || fail "The executable cannot find its Frameworks folder; check the BigWaterApp linker settings."
if [[ "$universal" == true ]]; then
    archs="$(lipo -archs "$executable")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "Not a universal binary: $archs"
fi

# Sign only the app itself. Sparkle's own signatures inside stay as they
# are, so never pass --deep here.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

echo "App: $app"
[[ "$universal" == true ]] && echo "Architectures: $(lipo -archs "$executable")"
exit 0
