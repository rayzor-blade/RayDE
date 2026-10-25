#!/usr/bin/env bash
# Captures RayDE's workbench with ashui's snapshot tools, into bin/snapshots.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
if [ -z "${SNAPSHOT_ONLY:-}" ] || [ "${SNAPSHOT_ONLY:-}" = git ] || [ "${SNAPSHOT_ONLY:-}" = git-sidebar ] || [ "${SNAPSHOT_ONLY:-}" = explorer ]; then
  "$here/scripts/build-libgit2.sh"
fi
stage_natives bin
main=Snapshots
[ "${SNAPSHOT_ONLY:-}" != readiness ] || main=ExtensionLoadingChecks
[ "${SNAPSHOT_ONLY:-}" != context-menu ] || main=EditorContextMenuChecks
[ "${SNAPSHOT_ONLY:-}" != tab-context ] || main=TabContextMenuChecks
haxe "${ui_args[@]}" -cp tests -main "$main" -hl bin/snapshots.hl
export ASHUI_SNAPSHOT_DIR=${ASHUI_SNAPSHOT_DIR:-$here/bin/snapshots}
exec "$ash" --preset application bin/snapshots.hl "$@"
