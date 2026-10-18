#!/usr/bin/env bash
# Builds the terminal's native library (native/terminal) and puts it in bin as cterm.hdll, where the program loads it from.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in
  Darwin) ext=dylib; prefix=lib ;;
  Linux) ext=so; prefix=lib ;;
  *) ext=dll; prefix= ;;
esac
(cd "$here/native/terminal" && nice -n 10 cargo build --release --quiet)
mkdir -p "$here/bin"
# A new file, not a copy over the old: macOS keeps a library's signature by its file, and kills a program that loads one copied over in place.
rm -f "$here/bin/cterm.hdll"
cp "$here/native/terminal/target/release/${prefix}rayde_terminal.$ext" "$here/bin/cterm.hdll"
