#!/usr/bin/env bash
# Builds the Ashui project in the current directory with RayDE's headless WindowedApp and runs it offscreen, speaking the surface protocol on stdout.
# Build output goes to stderr so the protocol stays clean. HXML=build.hxml and ASH override the defaults; ASH_UI_BIN is a folder holding
# blinc_abi.hdll, xgpu.hdll and xwindow.hdll (RayDE's bin by default). The app is drawn on the host's wgpu adapter; no window is made.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
hxml=${HXML:-build.hxml}
ash=$(command -v "${ASH:-ash}" || true)
[ -x "$ash" ] || { echo "ashui-surface.sh: put ash on PATH or set ASH" >&2; exit 1; }
[ -f "$hxml" ] || { echo "ashui-surface.sh: no $hxml in $(pwd)" >&2; exit 1; }
natives=${ASH_UI_BIN:-$here/bin}
mkdir -p bin
# The project's own output target is replaced by the surface build's.
grep -v '^-hl ' "$hxml" > bin/rayde-ashui-surface.hxml || true
# Built beside the old one and moved over it, so an app already running keeps the file it started from.
haxe bin/rayde-ashui-surface.hxml -D ashui_window -cp "$here/shims/ashui" -cp "$here/src" -hl bin/rayde-ashui-surface.hl.next >&2
mv -f bin/rayde-ashui-surface.hl.next bin/rayde-ashui-surface.hl
for lib in blinc_abi xgpu xwindow; do
  if [ -e "$natives/$lib.hdll" ] && { [ ! -e "bin/$lib.hdll" ] || [ "$natives/$lib.hdll" -nt "bin/$lib.hdll" ]; }; then cp "$natives/$lib.hdll" bin/; fi
done
exec "$ash" --mode hybrid --preset application bin/rayde-ashui-surface.hl
