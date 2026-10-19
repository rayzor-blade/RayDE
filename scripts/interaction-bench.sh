#!/usr/bin/env bash
# First opens and ten-tab/view switching, without allocating PNG readbacks in the measured frames.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
"$here/scripts/build-libgit2.sh"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main Snapshots -hl bin/snapshots.hl
exec python3 tests/interaction_probe.py "$ash"
