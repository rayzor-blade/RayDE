#!/usr/bin/env bash
# Builds a portable tree with a launcher, desktop entry, file types and icons.
#   scripts/package-linux.sh [empty folder]      bin/install by default
# The launcher runs the bundled AOT executable.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
install_prefix=${1:-$here/bin/install}
cd "$here"
mkdir -p "$install_prefix"
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); sys.exit("Choose an empty package folder: " + str(p) if any(p.iterdir()) else 0)' "$install_prefix"
install_prefix=$(cd "$install_prefix" && pwd)
"$here/scripts/build-libgit2.sh"
lib="$install_prefix/lib/rayde"
mkdir -p "$install_prefix/bin" "$lib" "$install_prefix/share/applications" "$install_prefix/share/mime/packages"
stage_natives "$lib"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$lib/rayde.hl"
"$ash" --build "$lib/rayde" "$lib/rayde.hl"
rm "$lib/rayde.hl"
mkdir -p "$install_prefix/share/rayde/extensions" "$install_prefix/share/icons"
[ ! -d extensions ] || cp -R extensions/. "$install_prefix/share/rayde/extensions/"
cp -R assets/icons/hicolor "$install_prefix/share/icons/"
install -m 644 packaging/linux/rayde.desktop "$install_prefix/share/applications/rayde.desktop"
install -m 644 packaging/linux/rayde-mime.xml "$install_prefix/share/mime/packages/rayde.xml"
cat > "$install_prefix/bin/rayde" <<'LAUNCH'
#!/bin/sh
# Starts RayDE on Welcome, or a workspace supplied on the command line.
lib=$(cd "$(dirname "$(readlink -f "$0")")/../lib/rayde" && pwd)
export RAYDE_EXTENSIONS="${RAYDE_EXTENSIONS:-$(cd "$lib/../../share/rayde/extensions" && pwd)}"
exec "$lib/rayde" "$@"
LAUNCH
chmod +x "$install_prefix/bin/rayde"
python3 scripts/distribution.py "$install_prefix" --platform linux
echo "installed in ${install_prefix#"$here/"} (AOT)"
