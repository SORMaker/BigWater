#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"

task_universal=false
while (($#)); do
    case "$1" in
        --universal) task_universal=true ;;
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

task_app="$task_root/dist/Big Water.app"
task_art="$task_root/dist/Artwork"
task_framework_src="$task_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
task_framework_dst="$task_app/Contents/Frameworks/Sparkle.framework"

swift build -c release --product BigWaterArtwork
task_host_bin_dir="$(swift build -c release --product BigWaterArtwork --show-bin-path)"
"$task_host_bin_dir/BigWaterArtwork" "$task_art"

if [[ "$task_universal" == true ]]; then
    task_arm_triple="arm64-apple-macosx13.0"
    task_intel_triple="x86_64-apple-macosx13.0"

    swift build -c release --product BigWater --triple "$task_arm_triple"
    swift build -c release --product BigWater --triple "$task_intel_triple"
    task_arm_bin_dir="$(swift build -c release --product BigWater --triple "$task_arm_triple" --show-bin-path)"
    task_intel_bin_dir="$(swift build -c release --product BigWater --triple "$task_intel_triple" --show-bin-path)"
else
    swift build -c release --product BigWater
    task_bin_dir="$(swift build -c release --product BigWater --show-bin-path)"
fi

if [[ ! -d "$task_framework_src" ]]; then
    echo "Sparkle.framework is missing from the resolved Sparkle 2.10.0 artifact:" >&2
    echo "  $task_framework_src" >&2
    echo "Resolve the Swift package dependencies before building." >&2
    exit 1
fi

mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" "$task_app/Contents/Frameworks"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/Resources/Sparkle-LICENSE" "$task_app/Contents/Resources/Sparkle-LICENSE"
iconutil -c icns "$task_art/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"

if [[ "$task_universal" == true ]]; then
    lipo -create \
        "$task_arm_bin_dir/BigWater" \
        "$task_intel_bin_dir/BigWater" \
        -output "$task_app/Contents/MacOS/BigWater.new"
else
    cp "$task_bin_dir/BigWater" "$task_app/Contents/MacOS/BigWater.new"
fi
mv -f "$task_app/Contents/MacOS/BigWater.new" "$task_app/Contents/MacOS/BigWater"

# ditto preserves Sparkle's framework symlinks, executable modes, and nested
# signatures. Sign only the containing app below; never use codesign --deep.
rm -rf "$task_framework_dst"
ditto "$task_framework_src" "$task_framework_dst"

task_executable="$task_app/Contents/MacOS/BigWater"
if [[ ! -x "$task_executable" || ! -x "$task_framework_dst/Autoupdate" ]]; then
    echo "The app or Sparkle helper lost its executable permission." >&2
    exit 1
fi
if [[ ! -L "$task_framework_dst/Versions/Current" || ! -L "$task_framework_dst/Sparkle" || ! -L "$task_framework_dst/Updater.app" || ! -L "$task_framework_dst/XPCServices" ]]; then
    echo "Sparkle.framework symlinks were not preserved during packaging." >&2
    exit 1
fi

task_load_commands="$(otool -l "$task_executable")"
if [[ "$task_load_commands" != *'@executable_path/../Frameworks'* ]]; then
    echo "The BigWater executable is missing its Frameworks runtime rpath." >&2
    echo 'Add @executable_path/../Frameworks to the BigWaterApp linker settings.' >&2
    exit 1
fi
if [[ "$task_universal" == true ]]; then
    task_archs="$(lipo -archs "$task_executable")"
    if [[ "$task_archs" != *arm64* || "$task_archs" != *x86_64* ]]; then
        echo "Universal build does not contain both arm64 and x86_64: $task_archs" >&2
        exit 1
    fi
fi

# Sparkle ships its framework and helper code signed by Sparkle. An ad-hoc
# signature on this app is sufficient for local distribution and preserves
# those nested upstream signatures.
codesign --force --sign - --timestamp=none "$task_app"
codesign --verify --deep --strict "$task_app"

echo "App: $task_app"
if [[ "$task_universal" == true ]]; then
    echo "Architectures: $(lipo -archs "$task_executable")"
fi
