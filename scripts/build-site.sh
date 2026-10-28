#!/usr/bin/env bash
# Regenerates the standalone editor bundle used by the landing page.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bash "$here/scripts/build-web.sh" "${1:-$here/site/dist}"
python3 "$here/scripts/package-demo.py" "${1:-$here/site/dist}/demo-workspace.json"
python3 "$here/scripts/stage-preview.py" --bundle "${1:-$here/site/dist}" ${ASH_RUNTIME:+--runtime "$ASH_RUNTIME"}
python3 - "${1:-$here/site/dist}/index.html" <<'PY'
from pathlib import Path
import sys
page=Path(sys.argv[1])
text=page.read_text()
if 'name="rayde-demo"' not in text:
    text=text.replace('<meta name="ashui-module"', '<meta name="rayde-demo" content="demo-workspace.json">\n<meta name="ashui-module"', 1)
page.write_text(text)
PY
