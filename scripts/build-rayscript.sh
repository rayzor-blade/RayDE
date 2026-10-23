#!/usr/bin/env bash
# Builds the embedded runtime and isolated native extension host.
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
host_name=rayde-extension-host
[ "$ext" != dll ] || host_name=rayde-extension-host.exe
cp "$CARGO_TARGET_DIR/release/${prefix}rayde_rayscript.$ext" "$here/bin/rayscript.hdll.next"
mv -f "$here/bin/rayscript.hdll.next" "$here/bin/rayscript.hdll"
cp "$CARGO_TARGET_DIR/release/$host_name" "$here/bin/$host_name.next"
mv -f "$here/bin/$host_name.next" "$here/bin/$host_name"
