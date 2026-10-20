#!/usr/bin/env bash
# Measures Markdown glides and verifies visible coverage, anchor continuity and bounded mounted blocks.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main MarkdownScrollBench -hl bin/markdown-scroll-bench.hl
if [ "${1:-}" = --native ]; then
  shift
  "$ash" --build bin/markdown-scroll-native bin/markdown-scroll-bench.hl
  exec "$here/bin/markdown-scroll-native" "$@"
fi
exec "$ash" --preset application bin/markdown-scroll-bench.hl "$@"
