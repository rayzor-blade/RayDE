# Sourced by RayDE's scripts: where ashui and the native libraries are, and the
# compiler arguments every UI build shares.
#
# ashui is pinned to a commit, checked out under .deps and
# built once, so work in progress in ../ashui never breaks a run here.
# ASHUI=<dir> builds against that checkout instead, such as ../ashui.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
siblings=$(dirname "$here")
ashui_rev=3f07c51001b0c027f7c15a4853d79f3a91f2e6d6
ashui=${ASHUI:-$here/.deps/ashui-$ashui_rev}
hlwgpu=${HLWGPU:-$siblings/hlwgpu}
hlwindow=${HLWINDOW:-$siblings/hlwindow}
future=${ASH_FUTURE:-$siblings/ash/haxelib/ash-future}
simd=${ASH_SIMD:-$siblings/ash/haxelib/ash-simd}
# Keep the compiler and staged runtime from the same workspace build; ASH overrides either default.
ash=${ASH:-$siblings/ash/target/release/ash}
[ -x "$ash" ] || ash=${ASH:-$(command -v ash || true)}

fail() { echo "$(basename "$0"): $*" >&2; exit 1; }
[ -x "$ash" ] || fail "put ash on PATH or set ASH"
# Browser entrypoints need compiler classpaths and WASM libraries, not the desktop renderer.
case "${RAYDE_BUILD_TARGET:-${BASH_SOURCE[1]##*/}}" in
  web|build-web.sh|build-web-abi.sh) build_desktop_renderer=false ;;
  *) build_desktop_renderer=true ;;
esac
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
  if $build_desktop_renderer && [ ! -f "$ashui/target/release/${prefix}blinc_abi.$ext" ]; then
    echo "building ashui ${ashui_rev:0:7}'s native library, once for this pin" >&2
    (cd "$ashui" && nice -n 10 cargo build --release --quiet) || fail "could not build ashui's native library"
  fi
fi

# Copies the native libraries a UI program loads beside it, under the names it loads them by.
stage_natives() {
  local out=$1 lib
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
  local extension_host=rayde-extension-host
  [ "$ext" != dll ] || extension_host=rayde-extension-host.exe
  if [ "$(cd "$out" && pwd)" != "$here/bin" ]; then
    cp "$here/bin/$extension_host" "$out/$extension_host.next"
    mv -f "$out/$extension_host.next" "$out/$extension_host"
  fi
  mkdir -p "$out/notices/syntax-markdown"
  cp "$here/native/rayscript/notices/"* "$out/notices/syntax-markdown/"
  mkdir -p "$out/notices/icons"
  cp "$here/assets/notices/"* "$out/notices/icons/"
  stage_rayzor "$out"
}

# Stages an existing LSP executable; RayDE builds never start a Rayzor Cargo build.
stage_rayzor() {
  local out=$1 name=rayzor
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) name=rayzor.exe ;; esac
  local binary=${RAYZOR_LSP:-$siblings/rayzor/target/release/$name}
  [ -x "$binary" ] || binary=$(command -v "$name" || true)
  [ -n "$binary" ] && [ -x "$binary" ] || return 0
  if ! cmp -s "$binary" "$out/$name"; then
    cp "$binary" "$out/$name.next"
    mv -f "$out/$name.next" "$out/$name"
  fi
  local stdlib=${RAYZOR_STD_PATH:-$siblings/rayzor/compiler/haxe-std}
  if [ -f "$stdlib/Std.hx" ] && ! diff -qr "$stdlib" "$out/haxe-std" >/dev/null 2>&1; then
    mkdir -p "$out/haxe-std"
    cp -R "$stdlib/." "$out/haxe-std/"
  fi
  if [ -f "$siblings/rayzor/LICENSE" ]; then
    mkdir -p "$out/notices/rayzor"
    cp "$siblings/rayzor/LICENSE" "$out/notices/rayzor/LICENSE"
  fi
}

ui_args=(-cp src -lib hashlink -lib tink_hxx -D ash_simd -D ashui_scene_stencil -D "ashui_css=src/rayde/ui/rayde.css"
  --macro "ashui.core.render.UiFramework.register()" --macro "ashui.ui.Markup.enable()"
  -cp "$ashui/haxe" -cp "$ashui/components/haxe" -cp "$ashui/icons/haxe" -cp "$ashui/canvaskit/haxe" -cp "$ashui/media/haxe"
  -cp "$hlwgpu/haxe" -cp "$hlwindow/haxe" -cp "$future" -cp "$simd")
