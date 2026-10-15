#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$task_root/Tools/build.sh"
open "$task_root/dist/Big Water.app" --args "$@"
