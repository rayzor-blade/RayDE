#!/usr/bin/env bash
# Builds a self-contained AOT RayDE.app with its runtime, extensions and Dock icon.
#   scripts/package-macos.sh [folder]      the app goes in the folder, bin by default
# Without a workspace argument, the bundled executable opens Welcome.
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
mv "$res/rayde-extension-host" "$mac/"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$mac/rayde.hl"
"$ash" --build "$mac/RayDE" "$mac/rayde.hl"
rm "$mac/rayde.hl"
RAYDE_PLIST_VERSION="$version" python3 - "$app/Contents/Info.plist" <<'PY'
import os, pathlib, plistlib, re, sys
version = os.environ['RAYDE_PLIST_VERSION']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?', version):
    raise SystemExit('RAYDE_VERSION must be a semantic version')
info = plistlib.loads(pathlib.Path('packaging/macos/Info.plist').read_bytes())
info['CFBundleShortVersionString'] = info['CFBundleVersion'] = re.split(r'[-+]', version)[0]
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
mkdir -p "$res/extensions"
[ ! -d extensions ] || cp -R extensions/. "$res/extensions/"
cp assets/icons/rayde.icns "$res/RayDE.icns"
plutil -lint "$app/Contents/Info.plist" >/dev/null
python3 scripts/distribution.py "$app" --platform macos --version "$version"
rm -rf "$out/RayDE.app"
mv "$app" "$out/RayDE.app"
echo "built ${out#"$here/"}/RayDE.app (AOT)"
