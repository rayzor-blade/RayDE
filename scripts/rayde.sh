#!/usr/bin/env bash
# Opens a project in RayDE: scripts/rayde.sh path/to/build.hxml, path/to/name.rayext for an extension, or path/to/name.raytheme for a theme
# --build rebuilds without opening a window; --native also compiles bin/rayde ahead of time.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
build_only=0
native=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) build_only=1; shift ;;
    --native) native=1; shift ;;
    *) break ;;
  esac
done
[ "$build_only" = 1 ] || [ $# -ge 1 ] || fail "usage: rayde.sh [--native] [--build] <build.hxml | name.rayext | name.raytheme>"
cd "$here"
"$here/scripts/build-libgit2.sh"
stage_natives bin
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl bin/rayde.hl
if [ "$native" = 1 ]; then
  "$ash" --build bin/rayde.next bin/rayde.hl
  mv bin/rayde.next bin/rayde
fi
[ "$build_only" = 1 ] && exit 0
project=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
if [ "$native" = 1 ]; then exec "$here/bin/rayde" "$project"; fi
exec "$ash" --preset application bin/rayde.hl "$project"
