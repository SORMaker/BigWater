#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
swift build
task_bin_dir="$(swift build --show-bin-path)"
task_checks="$(mktemp -d "${TMPDIR:-/tmp}/bigwater-session.XXXXXX")"
trap 'rm -rf "$task_checks"' EXIT

# Compile the real app classes into an isolated notification test process.
swiftc -parse-as-library -I "$task_bin_dir/Modules" \
    Sources/BigWater/AppDelegate.swift Sources/BigWater/AppStorage.swift Sources/BigWater/SettingsView.swift \
    Sources/BigWater/OverlayController.swift Sources/BigWater/OverlayControls.swift \
    Tests/BigWaterSessionTests/SessionChecks.swift \
    "$task_bin_dir"/BigWaterCore.build/*.swift.o "$task_bin_dir"/BigWaterArt.build/*.swift.o \
    -o "$task_checks/BigWaterSessionChecks"
"$task_checks/BigWaterSessionChecks"
