#!/usr/bin/env bash
# Builds RayDE for a page: bytecode for wasm32-wasip1-threads, with ashui's web libraries and page staged beside it.
#
#   scripts/build-web.sh [output directory]      default: bin/web/rayde
#
# Needs Ash, and the web builds of blinc_abi, hlwindow and hlwgpu (ashui's tests/wasm/run.sh makes them in ashui/tests/bin/web;
# WEB_LIBS names another directory holding blinc_abi.wasm, hlwindow-web/ and hlwgpu-web/). Serve the result with `ash serve`.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/scripts/deps.sh"
ash=${ASH:-$(command -v ash || true)}
[ -x "$ash" ] || { echo "build-web.sh: put ash on PATH or set ASH" >&2; exit 1; }
libs=${WEB_LIBS:-$siblings/ashui/tests/bin/web}
for need in blinc_abi.wasm hlwindow-web hlwgpu-web; do
  [ -e "$libs/$need" ] || { echo "build-web.sh: $libs/$need is missing; run ashui's tests/wasm/run.sh --no-open once, or set WEB_LIBS" >&2; exit 1; }
done
out=${1:-$here/bin/web/rayde}
mkdir -p "$out"
cp "$libs/blinc_abi.wasm" "$out/"
cd "$here"
haxe "${ui_args[@]}" -D wasm -D ashui_no_hdll -D ashui_window -D rayde_page -D "hlwgpu_web=$libs/hlwgpu-web" -D "hlwindow_web=$libs/hlwindow-web" \
  -dce full --macro "ashui.core.render.UiFramework.register()" --macro "ashui.macro.DefaultFonts.stage()" --macro "ashui.macro.WebPage.stage()" \
  --macro "hlwgpu.macro.NativeInstall.stage()" --macro "hlwindow.macro.NativeInstall.stage()" \
  -main rayde.Main -hl "$out/rayde.hl"
# The window presents as a Mac, but shortcuts follow the visitor's keyboard: the page tells the program its platform before the host starts it.
python3 - "$out/index.html" <<'PY'
import sys
path = sys.argv[1]
page = open(path).read()
marker = "RAYDE_VISITOR"
if marker not in page:
    script = """<script>
  // RayDE's shortcuts follow this keyboard (RAYDE_VISITOR), whatever platform its window presents as.
  (function () {
    var query = new URLSearchParams(location.search);
    if (query.getAll("env").some(function (e) { return e.indexOf("RAYDE_VISITOR=") === 0; })) return;
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    query.append("env", "RAYDE_VISITOR=" + (/mac|iphone|ipad/i.test(platform) ? "Mac" : /win/i.test(platform) ? "Windows" : "Linux"));
    // An installed web app is RayDE's own window; embedded in another page it is not.
    if (window.matchMedia("(display-mode: standalone), (display-mode: window-controls-overlay), (display-mode: fullscreen)").matches && window.top === window && !query.getAll("env").some(function (e) { return e.indexOf("RAYDE_STANDALONE=") === 0; })) query.append("env", "RAYDE_STANDALONE=1");
    history.replaceState(null, "", "?" + query.toString());
  })();
</script>
"""
    page = page.replace('<script type="module"', script + '<script type="module"', 1)
    open(path, "w").write(page)
PY
ASH_WASM_FIBERS=1 "$ash" --build "$out/rayde.wasm" --target wasm32-wasip1-threads "$out/rayde.hl" 2>&1 | tail -8
ls -la "$out"/rayde.wasm | awk '{print "rayde.wasm", $5, "bytes"}'
