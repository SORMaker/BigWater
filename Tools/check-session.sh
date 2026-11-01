#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# Needs an awake desktop session: it opens real overlay windows briefly.
swift run BigWaterSessionChecks
