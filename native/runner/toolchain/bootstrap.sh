#!/bin/sh
# Runs only in the isolated, network-enabled image builder, never in a user's workspace.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git neko python3 libgit2-1.9
mkdir -p /opt/rayde/haxe /opt/rayde/haxelib
tar -xzf /opt/rayde/haxe.tar.gz --strip-components=1 -C /opt/rayde/haxe
cp /opt/rayde/haxe/haxe /opt/rayde/bin/haxe
cp /opt/rayde/haxe/haxelib /opt/rayde/bin/haxelib
rm /opt/rayde/haxe.tar.gz
haxelib install ashui-components 0.2.2 --always --quiet
haxelib install ashui-icons 0.2.2 --always --quiet
mkdir -p /opt/rayde/extensions/git/natives
cp -L /usr/lib/x86_64-linux-gnu/libgit2.so.1.9 /opt/rayde/extensions/git/natives/libgit2.so
python3 - <<'PY'
import hashlib,json,pathlib
root=pathlib.Path('/opt/rayde/extensions/git');path=root/'git.rayext'
manifest=json.loads(path.read_text());native=root/'natives/libgit2.so'
manifest['natives']['git2']={'path':'natives/libgit2.so','sha256':hashlib.sha256(native.read_bytes()).hexdigest()}
path.write_text(json.dumps(manifest,indent=2)+'\n')
PY
mkdir -p /tmp/rayde-probe
printf 'class Main { static function main() trace("toolchain-ready"); }\n' > /tmp/rayde-probe/Main.hx
haxe -cp /tmp/rayde-probe -main Main -hl /tmp/rayde-probe/main.hl
ash /tmp/rayde-probe/main.hl | grep toolchain-ready
if [ -d /opt/rayde/preview ]; then
  ASH_RUNTIME=/opt/rayde/preview/ash_runtime.o ASH_WASM_FIBERS=1 ash --build /tmp/rayde-probe/main.wasm \
    -O3 --codegen-opt-level 0 --target wasm32-wasip1-threads /tmp/rayde-probe/main.hl
  test -s /tmp/rayde-probe/main.wasm
fi
cd /opt/rayde/pocket-studio
haxe build.hxml
if [ -d /opt/rayde/preview ]; then
  haxe build.hxml -D wasm -cp /opt/rayde/preview/haxe
fi
rm -rf bin .rayde .rayzor /tmp/rayde-probe
apt-get clean
rm -rf /var/lib/apt/lists/*
python3 /opt/rayde/finalize.py
