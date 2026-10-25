#!/usr/bin/env bash
# Builds the pinned libgit2 with system OpenSSH, bundled zlib and bundled regex.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
version=1.9.7
checksum=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
cache="$here/.deps"
archive="$cache/libgit2-$version.tar.gz"
source_dir="$cache/libgit2-$version"
build_dir="$cache/libgit2-$version-build"
mkdir -p "$cache"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 2 "https://github.com/libgit2/libgit2/archive/refs/tags/v$version.tar.gz" -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
sha256() { python3 -c 'import hashlib,sys; print(hashlib.file_digest(open(sys.argv[1], "rb"), "sha256").hexdigest())' "$1"; }
actual=$(sha256 "$archive")
[ "$actual" = "$checksum" ] || { echo "libgit2: source checksum mismatch" >&2; exit 1; }
if [ ! -d "$source_dir" ]; then
  # Disabled test fixtures contain symlinks that require extra Windows privileges.
  tar --exclude="libgit2-$version/tests" -xzf "$archive" -C "$cache"
fi
cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF \
  -DUSE_SSH=exec -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin \
  -DEXPERIMENTAL_SHA256=OFF -DCMAKE_MACOSX_RPATH=ON
cmake --build "$build_dir" --config Release --parallel "${BUILD_JOBS:-4}"
case "$(uname -s)" in
  Darwin) library=libgit2.dylib ;;
  Linux) library=libgit2.so ;;
  MINGW*|MSYS*|CYGWIN*) library=git2.dll ;;
  *) echo "libgit2: unsupported platform" >&2; exit 1 ;;
esac
built="$build_dir/$library"
[ -f "$built" ] || built="$build_dir/Release/$library"
[ -f "$built" ] || { echo "libgit2: missing $library" >&2; exit 1; }
out="$here/extensions/git/natives"
mkdir -p "$out"
if [ ! -f "$out/$library" ] || ! cmp -s "$built" "$out/$library"; then
  cp -L "$built" "$out/$library.new"
  mv "$out/$library.new" "$out/$library"
fi
cp "$source_dir/COPYING" "$out/libgit2.COPYING"
digest=$(sha256 "$out/$library")
sed -e "s/@LIBRARY@/$library/g" -e "s/@SHA256@/$digest/g" \
  "$here/extensions/git/git.rayext.in" > "$here/extensions/git/git.rayext"
echo "libgit2 $version: $out/$library"
