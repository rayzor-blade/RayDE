#!/usr/bin/env bash
# Builds RayDE for a page: bytecode for wasm32-wasip1-threads, with ashui's web libraries and page staged beside it.
#
#   scripts/build-web.sh [output directory]      default: bin/web/rayde
#
# Needs Ash, Rust nightly with rust-src, and hlwindow/hlwgpu's web builds (WEB_LIBS selects their directory).
# The pinned renderer is built and cached by its Rust inputs. Serve the result with `ash serve`.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/scripts/deps.sh"
ash=${ASH:-$(command -v ash || true)}
[ -x "$ash" ] || { echo "build-web.sh: put ash on PATH or set ASH" >&2; exit 1; }
libs=${WEB_LIBS:-$siblings/ashui/tests/bin/web}
for need in hlwindow-web hlwgpu-web; do
  [ -e "$libs/$need" ] || { echo "build-web.sh: $libs/$need is missing; run ashui's tests/wasm/run.sh --no-open once, or set WEB_LIBS" >&2; exit 1; }
done
out=${1:-$here/bin/web/rayde}
channel=${ASH_CHANNEL_ROOT:-$siblings/ash}
channel_libs=${ASH_CHANNEL_WEB:-$channel/target/wasm-channel}
[ -f "$channel_libs/ash_channel.wasm" ] || fail "build Ash's ash-channel wasm side module first, or set ASH_CHANNEL_WEB"
[ -x "$here/web/session/node_modules/.bin/esbuild" ] || fail "run npm ci in web/session to build the page agent"
mkdir -p "$out"
abi=$(bash "$here/scripts/build-web-abi.sh")
cp "$abi" "$out/blinc_abi.wasm"
cp "$channel_libs/ash_channel.wasm" "$channel_libs/channel-agent.mjs" "$out/"
(cd "$here/web/session" && npm run build >/dev/null)
cp "$here/web/session/dist/rayde_session.js" "$out/rayde_session.mjs"
mkdir -p "$out/notices/marked"
cp "$here/web/session/node_modules/marked/LICENSE" "$out/notices/marked/LICENSE"
cd "$here"
haxe "${ui_args[@]}" -cp "$channel/haxelib/ash-channel" -D wasm -D ashui_no_hdll -D ashui_window -D rayde_page -D "hlwgpu_web=$libs/hlwgpu-web" -D "hlwindow_web=$libs/hlwindow-web" \
  -dce full --macro "ashui.core.render.UiFramework.register()" --macro "ashui.macro.DefaultFonts.stage()" --macro "rayde.workspace.PageFonts.stage()" --macro "ashui.macro.WebPage.stage()" \
  --macro "hlwgpu.macro.NativeInstall.stage()" --macro "hlwindow.macro.NativeInstall.stage()" \
  -main rayde.Main -hl "$out/rayde.hl"
# The window presents as a Mac, but shortcuts follow the visitor's keyboard: the page tells the program its platform before the host starts it.
cp "$here/web/platform.js" "$out/rayde-platform.js"
python3 - "$out/index.html" <<'PY'
import sys
path = sys.argv[1]
page = open(path).read()
marker = "rayde-platform.js"
if marker not in page:
    script = '<script src="./rayde-platform.js"></script>\n'
    page = page.replace('<script type="module"', script + '<script type="module"', 1)
    open(path, "w").write(page)
PY
ASH_WASM_FIBERS=1 "$ash" --build "$out/rayde.wasm" --target wasm32-wasip1-threads "$out/rayde.hl" 2>&1 | tail -8
ls -la "$out"/rayde.wasm | awk '{print "rayde.wasm", $5, "bytes"}'
