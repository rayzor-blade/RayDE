#!/usr/bin/env bash
# Checks the Git bindings against pinned libgit2 in a real extension host.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/scripts/build-libgit2.sh"
exec python3 "$here/tests/git_native_checks.py" "$@"
