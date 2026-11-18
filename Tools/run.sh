#!/usr/bin/env bash
# Builds the app and opens it, replacing a copy that is already running.
# Arguments go to the app: --preview shows one real reminder straight away.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$root/Tools/build.sh"

# `open` only brings a running copy forward, so the old one has to quit
# first. It saves its countdown on the way out.
if pgrep -xq BigWater; then
    osascript -e 'tell application id "com.oil.bigwater" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        pgrep -xq BigWater || break
        sleep 0.1
    done
fi

open "$root/dist/Big Water.app" --args "$@"
