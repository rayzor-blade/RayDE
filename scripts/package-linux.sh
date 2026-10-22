#!/usr/bin/env bash
# Installs RayDE the way a Linux desktop expects it: a launcher, the program, the desktop entry, the file types
# and the icon in every size of the hicolor theme.
#   scripts/package-linux.sh [prefix]      /usr/local, or ~/.local for one user; bin/install by default
# The launcher runs the program with ash, which is not part of it: RAYDE_ASH names it, else ~/.ash/bin/ash or PATH.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
prefix=${1:-$here/bin/install}
cd "$here"
"$here/scripts/build-libgit2.sh"
lib="$prefix/lib/rayde"
mkdir -p "$prefix/bin" "$lib" "$prefix/share/applications" "$prefix/share/mime/packages"
stage_natives "$lib"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$lib/rayde.hl"
mkdir -p "$prefix/share/rayde/extensions"
[ ! -d extensions ] || cp -R extensions/. "$prefix/share/rayde/extensions/"
cp -R assets/icons/hicolor "$prefix/share/icons/" 2>/dev/null || { mkdir -p "$prefix/share/icons"; cp -R assets/icons/hicolor "$prefix/share/icons/"; }
install -m 644 packaging/linux/rayde.desktop "$prefix/share/applications/rayde.desktop"
install -m 644 packaging/linux/rayde-mime.xml "$prefix/share/mime/packages/rayde.xml"
cat > "$prefix/bin/rayde" <<'LAUNCH'
#!/bin/sh
# Starts RayDE on Welcome, or a workspace supplied on the command line.
lib=$(cd "$(dirname "$(readlink -f "$0")")/../lib/rayde" && pwd)
ash=${RAYDE_ASH:-$(command -v ash 2>/dev/null || echo "$HOME/.ash/bin/ash")}
[ -x "$ash" ] || { echo "rayde: ash was not found; install it or set RAYDE_ASH" >&2; exit 1; }
export RAYDE_EXTENSIONS="$(cd "$lib/../../share/rayde/extensions" && pwd)"
exec "$ash" --preset application "$lib/rayde.hl" "$@"
LAUNCH
chmod +x "$prefix/bin/rayde"
command -v update-desktop-database >/dev/null && update-desktop-database "$prefix/share/applications" 2>/dev/null || true
command -v update-mime-database >/dev/null && update-mime-database "$prefix/share/mime" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
echo "installed in ${prefix#"$here/"}"
