#!/usr/bin/env bash
# Installs RayDE the way a Linux desktop expects it: a launcher, the program, the desktop entry, the file types
# and the icon in every size of the hicolor theme.
#   scripts/package-linux.sh [prefix]      /usr/local, or ~/.local for one user; bin/install by default
# The launcher runs the program with ash, which is not part of it: RAYDE_ASH names it, else ~/.ash/bin/ash or PATH.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
prefix=${1:-$here/bin/install}
cd "$here"
lib="$prefix/lib/rayde"
mkdir -p "$prefix/bin" "$lib" "$prefix/share/applications" "$prefix/share/mime/packages"
stage_natives "$lib"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$lib/rayde.hl"
host=${RAYSCRIPT_HOST:-$siblings/rayscript/target/release/rayscript-host}
[ -x "$host" ] && cp "$host" "$lib/rayscript-host"
cp -R assets/icons/hicolor "$prefix/share/icons/" 2>/dev/null || { mkdir -p "$prefix/share/icons"; cp -R assets/icons/hicolor "$prefix/share/icons/"; }
install -m 644 packaging/linux/rayde.desktop "$prefix/share/applications/rayde.desktop"
install -m 644 packaging/linux/rayde-mime.xml "$prefix/share/mime/packages/rayde.xml"
cat > "$prefix/bin/rayde" <<'LAUNCH'
#!/bin/sh
# Starts RayDE on ash: a project given on the command line, else one chosen in a dialog when there is one.
lib=$(cd "$(dirname "$(readlink -f "$0")")/../lib/rayde" && pwd)
ash=${RAYDE_ASH:-$(command -v ash 2>/dev/null || echo "$HOME/.ash/bin/ash")}
[ -x "$ash" ] || { echo "rayde: ash was not found; install it or set RAYDE_ASH" >&2; exit 1; }
if [ $# -eq 0 ]; then
  if command -v zenity >/dev/null 2>&1; then
    project=$(zenity --file-selection --title="Open a project (.hxml, .rayext or .raytheme)" 2>/dev/null) || exit 0
    set -- "$project"
  elif command -v kdialog >/dev/null 2>&1; then
    project=$(kdialog --getopenfilename . "*.hxml *.rayext *.raytheme" 2>/dev/null) || exit 0
    set -- "$project"
  fi
fi
[ -x "$lib/rayscript-host" ] && export RAYSCRIPT_HOST="$lib/rayscript-host"
exec "$ash" --preset application "$lib/rayde.hl" "$@"
LAUNCH
chmod +x "$prefix/bin/rayde"
command -v update-desktop-database >/dev/null && update-desktop-database "$prefix/share/applications" 2>/dev/null || true
command -v update-mime-database >/dev/null && update-mime-database "$prefix/share/mime" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$prefix/share/icons/hicolor" 2>/dev/null || true
echo "installed in ${prefix#"$here/"}"
