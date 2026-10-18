#!/usr/bin/env bash
# Times frames of a long file flicked and left to decelerate in the workbench, offscreen. ROWS=<n> sets its length.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main ScrollBench -hl bin/scroll-bench.hl
exec "$ash" --preset application bin/scroll-bench.hl "$@"
