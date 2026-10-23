#!/usr/bin/env bash
# Restores the window session, or opens a supplied folder, project entry, extension or theme.
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
cd "$here"
"$here/scripts/build-libgit2.sh"
stage_natives bin
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl bin/rayde.hl
if [ "$native" = 1 ]; then
  "$ash" --build bin/rayde.next bin/rayde.hl
  mv bin/rayde.next bin/rayde
fi
[ "$build_only" = 1 ] && exit 0
if [ $# -gt 0 ]; then
  project=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  set -- "$project"
fi
if [ "$native" = 1 ]; then exec "$here/bin/rayde" "$@"; fi
exec "$ash" --preset application bin/rayde.hl "$@"
