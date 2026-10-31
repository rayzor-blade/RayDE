#!/usr/bin/env bash
# Builds the Heaps project in the current directory with RayDE's surface hook and runs it headless, speaking the surface protocol on stdout.
# Build output goes to stderr so the protocol stays clean. HXML=native.hxml, ASH and ASH_HEAPS_BIN (a folder with SDL3's sdl.hdll and the other hdlls) override the defaults.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
siblings=$(dirname "$here")
hxml=${HXML:-native.hxml}
ash=${ASH:-$siblings/ash/target/release/ash}
[ -x "$ash" ] || ash=$(command -v ash || true)
[ -x "$ash" ] || { echo "heaps-surface.sh: put ash on PATH or set ASH" >&2; exit 1; }
[ -f "$hxml" ] || { echo "heaps-surface.sh: no $hxml in $(pwd)" >&2; exit 1; }
natives=${ASH_HEAPS_BIN:-$siblings/ash/examples/heaps_base2d/bin}
mkdir -p bin
# The project's own output target is replaced by the surface build's.
grep -v '^-hl ' "$hxml" > bin/rayde-surface.hxml || true

# What the build depends on: the compiler, the hxml files, every .hx in the class paths, libraries by version (or by content when they are
# dev or git checkouts), the Heaps resources folder and RayDE's own shim. An unchanged key reuses the last build.
inputs() {
  local file=$1 depth=${2:-0} line value lib path repo
  echo "hxml $file"; cat "$file"
  [ "$depth" -lt 4 ] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    case "$line" in
      -cp\ *|--class-path\ *) value=${line#* }; [ -d "$value" ] && find "$value" -name '*.hx' -type f -print0 | sort -z | xargs -0 shasum -a 256 ;;
      -lib\ *|--library\ *) lib=${line#* }; lib=${lib%%:*}; path=$(haxelib path "$lib" 2>/dev/null | grep -v '^-' | head -1 || true)
        echo "lib $lib $path"
        repo=$(haxelib config 2>/dev/null || true)
        case "$path" in "$repo"*) ;; ?*) [ -d "$path" ] && find "$path" -name '*.hx' -type f -print0 | sort -z | xargs -0 shasum -a 256 ;; esac ;;
      *.hxml) [ -f "$line" ] && inputs "$line" $((depth + 1)) ;;
    esac
  done < "$file"
}
res=res
key=$({ haxe --version; inputs "$hxml"; [ -d "$res" ] && find "$res" -type f -print0 | sort -z | xargs -0 shasum -a 256
  find "$here/shims/heaps" "$here/src/rayde/preview" -name '*.hx' -type f -print0 | sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1)
if [ -f bin/rayde-surface.hl ] && [ "$(cat bin/rayde-surface.key 2>/dev/null)" = "$key" ]; then
  echo "heaps-surface.sh: unchanged since the last build" >&2
else
  rm -f bin/rayde-surface.key
  # Built beside the old one and moved over it, so an app already running keeps the file it started from.
  haxe bin/rayde-surface.hxml -cp "$here/shims/heaps" -cp "$here/src" --macro 'rayde.surface.Inject.apply()' -hl bin/rayde-surface.hl.next >&2
  mv -f bin/rayde-surface.hl.next bin/rayde-surface.hl
  echo "$key" > bin/rayde-surface.key
fi
for lib in "$natives"/*.hdll "$natives"/libhl*; do
  [ -e "$lib" ] && [ ! -e "bin/$(basename "$lib")" ] && cp "$lib" bin/
done
exec "$ash" --mode hybrid bin/rayde-surface.hl
