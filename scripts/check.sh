#!/usr/bin/env bash
# Builds RayDE's checks and runs them with ash.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ash=${ASH:-$(command -v ash || true)}
[ -x "$ash" ] || { echo "check.sh: put ash on PATH or set ASH" >&2; exit 1; }
mkdir -p "$here/bin"
"$here/scripts/build-terminal.sh"
bash "$here/scripts/build-rayscript.sh"
cd "$here"
siblings=$(dirname "$here")
haxe -cp src -cp tests -cp "${HLWINDOW:-$siblings/hlwindow}/haxe" -main Checks -hl bin/checks.hl
exec "$ash" --preset application bin/checks.hl "$@"
