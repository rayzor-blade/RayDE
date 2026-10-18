#!/usr/bin/env bash
# Runs an extension through the Extension Studio's Preview offscreen and captures it, into bin/snapshots.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main PreviewShot -hl bin/preview-shot.hl
export ASHUI_SNAPSHOT_DIR=${ASHUI_SNAPSHOT_DIR:-$here/bin/snapshots}
exec "$ash" --preset application bin/preview-shot.hl "$@"
