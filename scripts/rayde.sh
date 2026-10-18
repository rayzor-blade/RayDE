#!/usr/bin/env bash
# Opens a project in RayDE: scripts/rayde.sh path/to/build.hxml, or path/to/name.rayext for an extension
# scripts/rayde.sh --build only rebuilds bin/rayde.hl, without opening a window.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
build_only=0
if [ "${1:-}" = --build ]; then build_only=1; shift; fi
[ "$build_only" = 1 ] || [ $# -ge 1 ] || fail "usage: rayde.sh [--build] <build.hxml | name.rayext>"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl bin/rayde.hl
[ "$build_only" = 1 ] && exit 0
project=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
exec "$ash" --preset application bin/rayde.hl "$project"
