#!/usr/bin/env bash
# Builds RayDE's checks and runs them with ash.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/scripts/deps.sh"
ash=${ASH:-$(command -v ash || true)}
[ -x "$ash" ] || { echo "check.sh: put ash on PATH or set ASH" >&2; exit 1; }
mkdir -p "$here/bin"
"$here/scripts/build-terminal.sh"
bash "$here/scripts/build-rayscript.sh"
cd "$here"
siblings=$(dirname "$here")
haxe "${ui_args[@]}" -cp tests -main Checks -hl bin/checks.hl
exec "$ash" --preset application bin/checks.hl "$@"
