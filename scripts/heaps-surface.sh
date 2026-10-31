#!/usr/bin/env bash
# Builds the Heaps project in the current directory with RayDE's surface hook and runs it headless, speaking the surface protocol on stdout.
# Build output goes to stderr so the protocol stays clean. HXML=native.hxml, ASH and ASH_HEAPS_BIN (a folder with SDL3's sdl.hdll and the other hdlls) override the defaults.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
siblings=$(dirname "$here")
hxml=${HXML:-native.hxml}
ash=${ASH:-$siblings/ash/target/release/ash}
[ -x "$ash" ] || ash=$(command -v ash || true)
[ -x "$ash" ] || { echo "heaps-surface.sh: put ash on PATH or set ASH" >&2; exit 1; }
[ -f "$hxml" ] || { echo "heaps-surface.sh: no $hxml in $(pwd)" >&2; exit 1; }
natives=${ASH_HEAPS_BIN:-$siblings/ash/examples/heaps_base2d/bin}
mkdir -p bin
# The project's own output target is replaced by the surface build's.
grep -v '^-hl ' "$hxml" > bin/rayde-surface.hxml || true
haxe bin/rayde-surface.hxml -cp "$here/shims/heaps" -cp "$here/src" --macro 'rayde.surface.Inject.apply()' -hl bin/rayde-surface.hl >&2
for lib in "$natives"/*.hdll "$natives"/libhl*; do
  [ -e "$lib" ] && [ ! -e "bin/$(basename "$lib")" ] && cp "$lib" bin/
done
exec "$ash" --mode hybrid bin/rayde-surface.hl
