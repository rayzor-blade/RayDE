#!/usr/bin/env bash
# Measures extension worker work and UI stalls; --native excludes Ash JIT warm-up.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
"$here/scripts/build-libgit2.sh"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main Snapshots -hl bin/extension-probe.hl
program=("$ash" --preset application bin/extension-probe.hl)
if [ "${1:-}" = --native ]; then
  "$ash" --build bin/extension-probe-aot bin/extension-probe.hl
  program=("$here/bin/extension-probe-aot")
fi
exec python3 tests/extension_probe.py "${program[@]}"
