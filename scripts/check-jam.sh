#!/usr/bin/env bash
# Checks the local Jam core and editor; optional --ssh uses a prebuilt remote client.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
cargo test --manifest-path native/jam/Cargo.toml --locked
cargo build --manifest-path native/jam/Cargo.toml --locked
python3 tests/jam_peer_checks.py "$@"
python3 tests/jam_recovery_checks.py "$@"
stage_natives bin
haxe "${ui_args[@]}" -cp "$ashui/tests" -main CodeCollaboration -hl bin/ashui-jam-check.hl
haxe "${ui_args[@]}" -cp tests -main JamWorkbenchChecks -hl bin/jam-ui-check.hl
export ASHUI_SNAPSHOT_DIR="$here/bin/jam-artifacts"
"$ash" --preset application bin/ashui-jam-check.hl | tee bin/ashui-jam-check.log
"$ash" --preset application bin/jam-ui-check.hl | tee bin/jam-ui-check.log
python3 - <<'PY'
from pathlib import Path
for file, marker in [('bin/ashui-jam-check.log', 'Editor collaboration:'), ('bin/jam-ui-check.log', 'Jam UI:')]:
    if marker not in Path(file).read_text():
        raise SystemExit(f'{file}: checks did not finish')
PY
