#!/usr/bin/env bash
# Produces an archive only after checking the relocated, extracted installation.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
name="rayde-${RAYDE_VERSION:?}-${PACKAGE_PLATFORM:?}-${PACKAGE_ARCH:?}"
mkdir -p dist
case "$PACKAGE_PLATFORM" in
  macos) scripts/package-macos.sh "$here/bin/distribution"; root="$here/bin/distribution/RayDE.app"; suffix=zip ;;
  linux) root="$here/bin/distribution/$name"; scripts/package-linux.sh "$root"; suffix=tar.gz ;;
  windows) root="$here/bin/distribution/$name"; bash scripts/package-windows.sh "$root"; suffix=zip ;;
  *) echo "unsupported platform: $PACKAGE_PLATFORM" >&2; exit 1 ;;
esac
python3 scripts/distribution.py "$root" --platform "$PACKAGE_PLATFORM" --validate-only --archive "$here/dist/$name.$suffix"
python3 tests/distribution_smoke.py "$here/dist/$name.$suffix" --platform "$PACKAGE_PLATFORM"
