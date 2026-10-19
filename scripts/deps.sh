# Sourced by RayDE's scripts: where ashui and the native libraries are, and the
# compiler arguments every UI build shares.
#
# ashui is pinned to a commit on its pushed main, checked out under .deps and
# built once, so work in progress in ../ashui never breaks a run here.
# ASHUI=<dir> builds against that checkout instead, such as ../ashui.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
siblings=$(dirname "$here")
ashui_rev=60d89f0cfb47e030eddb2ee9ba4e2c90ed2468d4
ashui=${ASHUI:-$here/.deps/ashui-$ashui_rev}
hlwgpu=${HLWGPU:-$siblings/hlwgpu}
hlwindow=${HLWINDOW:-$siblings/hlwindow}
future=${ASH_FUTURE:-$siblings/ash/haxelib/ash-future}
simd=${ASH_SIMD:-$siblings/ash/haxelib/ash-simd}
ash=${ASH:-$(command -v ash || true)}

fail() { echo "$(basename "$0"): $*" >&2; exit 1; }
[ -x "$ash" ] || fail "put ash on PATH or set ASH"
case "$(uname -s)" in
  Darwin) ext=dylib; prefix=lib ;;
  Linux) ext=so; prefix=lib ;;
  *) ext=dll; prefix= ;;
esac

if [ -z "${ASHUI:-}" ]; then
  if [ ! -d "$ashui" ]; then
    source_repo=https://github.com/rayzor-blade/ashui.git
    git -C "$siblings/ashui" cat-file -e "$ashui_rev^{commit}" 2>/dev/null && source_repo="$siblings/ashui"
    echo "checking out ashui ${ashui_rev:0:7} from $source_repo" >&2
    rm -rf "$ashui.partial"
    git clone --quiet --no-checkout "$source_repo" "$ashui.partial" || fail "could not clone ashui"
    git -C "$ashui.partial" checkout --quiet --detach "$ashui_rev" || fail "ashui has no commit $ashui_rev"
    mv "$ashui.partial" "$ashui"
  fi
  if [ ! -f "$ashui/target/release/${prefix}blinc_abi.$ext" ]; then
    echo "building ashui ${ashui_rev:0:7}'s native library, once for this pin" >&2
    (cd "$ashui" && nice -n 10 cargo build --release --quiet) || fail "could not build ashui's native library"
  fi
fi

# Copies the native libraries a UI program loads beside it, under the names it loads them by.
stage_natives() {
  local out=$1
  mkdir -p "$out"
  local ui="$ashui/target/release/${prefix}blinc_abi.$ext" gpu="$hlwgpu/target/release/${prefix}hlwgpu.$ext" window="$hlwindow/target/release/${prefix}hlwindow.$ext"
  for lib in "$ui" "$gpu" "$window"; do [ -f "$lib" ] || fail "missing native library: $lib"; done
  # Each is put in as a new file: macOS kills a program that loads a library copied over its old file in place.
  rm -f "$out/blinc_abi.hdll" "$out/xgpu.hdll" "$out/xwindow.hdll"
  cp "$ui" "$out/blinc_abi.hdll"
  cp "$gpu" "$out/xgpu.hdll"
  cp "$window" "$out/xwindow.hdll"
  "$here/scripts/build-terminal.sh"
  [ "$(cd "$out" && pwd)" = "$here/bin" ] || cp "$here/bin/cterm.hdll" "$out/cterm.hdll"
  bash "$here/scripts/build-rayscript.sh"
  [ "$(cd "$out" && pwd)" = "$here/bin" ] || cp "$here/bin/rayscript.hdll" "$out/rayscript.hdll"
}

ui_args=(-cp src -lib hashlink -lib tink_hxx -D ash_simd -D ashui_scene_stencil -D "ashui_css=src/rayde/ui/rayde.css"
  --macro "ashui.core.render.UiFramework.register()" --macro "ashui.ui.Markup.enable()"
  -cp "$ashui/haxe" -cp "$ashui/components/haxe" -cp "$ashui/icons/haxe" -cp "$ashui/canvaskit/haxe" -cp "$ashui/media/haxe"
  -cp "$hlwgpu/haxe" -cp "$hlwindow/haxe" -cp "$future" -cp "$simd")
