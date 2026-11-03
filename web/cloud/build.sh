#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
export RUSTUP_TOOLCHAIN="${RAYDE_CLOUD_RUST_TOOLCHAIN:-nightly-2026-10-06}"
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target wasm32-unknown-unknown

tools="${RAYDE_CLOUD_TOOLS_ROOT:-${CARGO_HOME:-$HOME/.cargo}/rayde-worker-tools/0.8.7}"
cargo install worker-build --version 0.8.7 --locked --root "$tools"
export PATH="$tools/bin:$PATH"
worker-build --release
node prebuilt.mjs stamp
