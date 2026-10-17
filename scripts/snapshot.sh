#!/usr/bin/env bash
# Captures RayDE's workbench with ashui's snapshot tools, into bin/snapshots.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main Snapshots -hl bin/snapshots.hl
export ASHUI_SNAPSHOT_DIR=${ASHUI_SNAPSHOT_DIR:-$here/bin/snapshots}
exec "$ash" --preset application bin/snapshots.hl "$@"
