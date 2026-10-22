#!/usr/bin/env bash
# Builds a self-contained AOT RayDE.app with its runtime, extensions and Dock icon.
#   scripts/package-macos.sh [folder]      the app goes in the folder, bin by default
# Without a project argument, the bundled executable opens a project picker.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
out=${1:-$here/bin}
version=${RAYDE_VERSION:-0.1.0}
cd "$here"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "$out/.rayde-app.XXXXXX")
trap 'rm -rf "$work"' EXIT
app="$work/RayDE.app"
res="$app/Contents/Resources"
mac="$app/Contents/MacOS"
"$here/scripts/build-libgit2.sh"
mkdir -p "$mac" "$res"
stage_natives "$res"
# Ash loads native libraries beside the executable; data stays under Resources.
for library in "$res/"*.hdll; do mv "$library" "$mac/"; done
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$mac/rayde.hl"
"$ash" --build "$mac/RayDE" "$mac/rayde.hl"
rm "$mac/rayde.hl"
sed "s/@VERSION@/$version/g" packaging/macos/Info.plist > "$app/Contents/Info.plist"
mkdir -p "$res/extensions"
[ ! -d extensions ] || cp -R extensions/. "$res/extensions/"
cp assets/icons/rayde.icns "$res/RayDE.icns"
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app"
rm -rf "$out/RayDE.app"
mv "$app" "$out/RayDE.app"
echo "built ${out#"$here/"}/RayDE.app (AOT)"
