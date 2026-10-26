#!/usr/bin/env bash
# Rebuilds ashui's WASM renderer when its pinned Rust inputs or toolchain change.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/scripts/deps.sh"
nightly=${RUST_NIGHTLY:-nightly-2026-08-25}
compiler=$(rustc +"$nightly" --version)
key=$(python3 - "$ashui" "$compiler" "$here/scripts/build-web-abi.sh" <<'PY'
from pathlib import Path
import hashlib,os,sys
root=Path(sys.argv[1]);digest=hashlib.sha256(sys.argv[2].encode())
digest.update(Path(sys.argv[3]).read_bytes())
for option in ('CARGO_PROFILE_RELEASE_LTO','CARGO_PROFILE_RELEASE_OPT_LEVEL','CARGO_PROFILE_RELEASE_CODEGEN_UNITS','CARGO_ENCODED_RUSTFLAGS'):
    digest.update((option+'='+os.environ.get(option,'')).encode())
files=[root/'Cargo.toml',root/'Cargo.lock',root/'build.rs',root/'scripts/build_wasm.sh']+sorted(p for p in (root/'native').rglob('*') if p.is_file())
for path in files:
    name=path.relative_to(root).as_posix().encode();data=path.read_bytes()
    digest.update(len(name).to_bytes(8,'little'));digest.update(name)
    digest.update(len(data).to_bytes(8,'little'));digest.update(data)
print(digest.hexdigest())
PY
)
out="$here/bin/web/abi-$key"
if [ ! -s "$out/blinc_abi.wasm" ] || [ ! -s "$out/complete" ]; then
  mkdir -p "$out"
  work=$(mktemp -d "$here/bin/web/.abi-build.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  echo "building the pinned WASM renderer ($compiler)" >&2
  RUST_NIGHTLY="$nightly" CARGO_TARGET_DIR="$here/bin/web/abi-target" bash "$ashui/scripts/build_wasm.sh" "$work" >&2
  mv "$work/blinc_abi.wasm" "$out/blinc_abi.wasm"
  printf '%s\n' "$compiler" > "$work/complete"
  mv "$work/complete" "$out/complete"
fi
printf '%s\n' "$out/blinc_abi.wasm"
