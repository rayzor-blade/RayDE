#!/usr/bin/env bash
# Times frames of the terminal under a program printing as fast as it can, offscreen.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main TerminalBench -hl bin/terminal-bench.hl
exec "$ash" --preset application bin/terminal-bench.hl "$@"
