#!/usr/bin/env bash
# Builds RayDE.app, RayDE as a macOS application with its icon in the Dock and in Finder.
#   scripts/package-macos.sh [folder]      the app goes in the folder, bin by default
# The app runs the program with ash, which is not part of it: RAYDE_ASH names it, else it is looked for in
# ~/.ash/bin, /opt/homebrew/bin, /usr/local/bin and on PATH. Without a project on the command line it asks for one.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
out=${1:-$here/bin}
version=${RAYDE_VERSION:-0.1.0}
app="$out/RayDE.app"
res="$app/Contents/Resources"
cd "$here"
"$here/scripts/build-libgit2.sh"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$res"
stage_natives "$res"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$res/rayde.hl"
sed "s/@VERSION@/$version/g" packaging/macos/Info.plist > "$app/Contents/Info.plist"
mkdir -p "$res/extensions"
[ ! -d extensions ] || cp -R extensions/. "$res/extensions/"
cp assets/icons/rayde.icns "$res/RayDE.icns"
cat > "$app/Contents/MacOS/RayDE" <<'LAUNCH'
#!/bin/sh
# Starts RayDE on ash: a project given on the command line, else one chosen in a dialog.
res=$(cd "$(dirname "$0")/../Resources" && pwd)
ash=${RAYDE_ASH:-}
if [ -z "$ash" ]; then
  for candidate in "$HOME/.ash/bin/ash" /opt/homebrew/bin/ash /usr/local/bin/ash "$(command -v ash 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && ash=$candidate && break
  done
fi
if [ -z "$ash" ]; then
  osascript -e 'display alert "RayDE needs ash" message "Install ash, or set RAYDE_ASH to its path."' >/dev/null 2>&1
  exit 1
fi
if [ $# -eq 0 ]; then
  project=$(osascript -e 'POSIX path of (choose file with prompt "Open a project: a .hxml build file, a .rayext extension or a .raytheme theme" of type {"hxml", "rayext", "raytheme"})' 2>/dev/null) || exit 0
  set -- "$project"
fi
exec "$ash" --preset application "$res/rayde.hl" "$@"
LAUNCH
chmod +x "$app/Contents/MacOS/RayDE"
plutil -lint "$app/Contents/Info.plist" >/dev/null
echo "built ${app#"$here/"}"
