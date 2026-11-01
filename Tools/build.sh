#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

universal=false
while (($#)); do
    case "$1" in
        --universal) universal=true ;;
        -h|--help)
            echo "Usage: $0 [--universal]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--universal]" >&2
            exit 2
            ;;
    esac
    shift
done

app="$root/dist/Big Water.app"
art="$root/dist/Artwork"
framework_src="$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
framework_dst="$app/Contents/Frameworks/Sparkle.framework"

swift build -c release --product BigWaterArtwork
host_bin_dir="$(swift build -c release --product BigWaterArtwork --show-bin-path)"
"$host_bin_dir/BigWaterArtwork" "$art"

if [[ "$universal" == true ]]; then
    arm_triple="arm64-apple-macosx13.0"
    intel_triple="x86_64-apple-macosx13.0"

    swift build -c release --product BigWater --triple "$arm_triple"
    swift build -c release --product BigWater --triple "$intel_triple"
    arm_bin_dir="$(swift build -c release --product BigWater --triple "$arm_triple" --show-bin-path)"
    intel_bin_dir="$(swift build -c release --product BigWater --triple "$intel_triple" --show-bin-path)"
else
    swift build -c release --product BigWater
    bin_dir="$(swift build -c release --product BigWater --show-bin-path)"
fi

if [[ ! -d "$framework_src" ]]; then
    echo "Sparkle.framework is missing from the resolved Sparkle 2.10.0 artifact:" >&2
    echo "  $framework_src" >&2
    echo "Resolve the Swift package dependencies before building." >&2
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Sparkle-LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
iconutil -c icns "$art/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

if [[ "$universal" == true ]]; then
    lipo -create \
        "$arm_bin_dir/BigWater" \
        "$intel_bin_dir/BigWater" \
        -output "$app/Contents/MacOS/BigWater.new"
else
    cp "$bin_dir/BigWater" "$app/Contents/MacOS/BigWater.new"
fi
mv -f "$app/Contents/MacOS/BigWater.new" "$app/Contents/MacOS/BigWater"

# ditto preserves Sparkle's framework symlinks, executable modes, and nested
# signatures. Sign only the containing app below; never use codesign --deep.
rm -rf "$framework_dst"
ditto "$framework_src" "$framework_dst"

executable="$app/Contents/MacOS/BigWater"
if [[ ! -x "$executable" || ! -x "$framework_dst/Autoupdate" ]]; then
    echo "The app or Sparkle helper lost its executable permission." >&2
    exit 1
fi
if [[ ! -L "$framework_dst/Versions/Current" || ! -L "$framework_dst/Sparkle" || ! -L "$framework_dst/Updater.app" || ! -L "$framework_dst/XPCServices" ]]; then
    echo "Sparkle.framework symlinks were not preserved during packaging." >&2
    exit 1
fi

load_commands="$(otool -l "$executable")"
if [[ "$load_commands" != *'@executable_path/../Frameworks'* ]]; then
    echo "The BigWater executable is missing its Frameworks runtime rpath." >&2
    echo 'Add @executable_path/../Frameworks to the BigWaterApp linker settings.' >&2
    exit 1
fi
if [[ "$universal" == true ]]; then
    archs="$(lipo -archs "$executable")"
    if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
        echo "Universal build does not contain both arm64 and x86_64: $archs" >&2
        exit 1
    fi
fi

# Sparkle ships its framework and helper code signed by Sparkle. An ad-hoc
# signature on this app is sufficient for local distribution and preserves
# those nested upstream signatures.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

echo "App: $app"
if [[ "$universal" == true ]]; then
    echo "Architectures: $(lipo -archs "$executable")"
fi
