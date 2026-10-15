#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
# Needs an awake desktop session: it opens real overlay windows briefly.
swift run BigWaterSessionChecks
