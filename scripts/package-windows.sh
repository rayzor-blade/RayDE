#!/usr/bin/env bash
# Builds a portable AOT distribution from Git Bash in an MSVC developer environment.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
out=${1:-$here/bin/RayDE}
cd "$here"
mkdir -p "$out"
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); sys.exit("Choose an empty package folder: " + str(p) if any(p.iterdir()) else 0)' "$out"
out=$(cd "$out" && pwd)
"$here/scripts/build-libgit2.sh"
stage_natives "$out"
haxe "${ui_args[@]}" -D ashui_window -main rayde.Main -hl "$out/rayde.hl"
cp assets/icons/rayde.ico "$out/"
resource=$(mktemp -d "$here/.deps/windows-resource.XXXXXX")
trap 'rm -rf "$resource"' EXIT
printf '1 ICON "%s"\n' "$(cygpath -m "$out/rayde.ico")" > "$out/rayde.rc"
MSYS2_ARG_CONV_EXCL='*' rc.exe /nologo "/fo$(cygpath -w "$resource/app.res")" "$(cygpath -w "$out/rayde.rc")"
export CC=${CC:-cl}
export ASH_LINK_ARGS="${resource#"$here/"}/app.res /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup ${ASH_LINK_ARGS:-}"
"$ash" --build "$out/RayDE.exe" "$out/rayde.hl"
rm "$out/rayde.hl" "$out/rayde.rc"
mkdir -p "$out/extensions"
cp -R extensions/. "$out/extensions/"
cp assets/icons/rayde.ico packaging/windows/install-shortcut.ps1 packaging/windows/RayDE.cmd "$out/"
python3 scripts/distribution.py "$out" --platform windows
echo "built $out (AOT)"
