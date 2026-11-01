#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$root/Tools/build.sh"
open "$root/dist/Big Water.app" --args "$@"
