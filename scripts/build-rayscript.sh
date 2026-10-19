#!/usr/bin/env bash
# Builds the embedded runtime using the existing RayScript target directory.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in
  Darwin) ext=dylib; prefix=lib ;;
  Linux) ext=so; prefix=lib ;;
  *) ext=dll; prefix= ;;
esac
export CARGO_TARGET_DIR="${RAYSCRIPT_TARGET_DIR:-$(dirname "$here")/rayscript/target}"
cargo build --manifest-path "$here/native/rayscript/Cargo.toml" --release --locked --quiet
mkdir -p "$here/bin"
rm -f "$here/bin/rayscript.hdll"
cp "$CARGO_TARGET_DIR/release/${prefix}rayde_rayscript.$ext" "$here/bin/rayscript.hdll"
