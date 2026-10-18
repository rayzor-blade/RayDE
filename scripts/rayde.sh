#!/usr/bin/env bash
# Opens a project in RayDE: scripts/rayde.sh path/to/build.hxml
set -euo pipefail
source "$(dirname "$0")/deps.sh"
[ $# -ge 1 ] || fail "usage: rayde.sh <build.hxml>"
project=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl bin/rayde.hl
exec "$ash" --preset application bin/rayde.hl "$project"
