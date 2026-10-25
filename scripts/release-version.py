#!/usr/bin/env python3
"""Select a validated package version without evaluating CI input as shell code."""
import json
import os
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
version = os.environ.get("INPUT_VERSION") or json.loads((root / "haxelib.json").read_text())["version"]
ref = os.environ.get("GITHUB_REF", "")
if ref.startswith("refs/tags/"):
    version = ref.removeprefix("refs/tags/v")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", version):
    raise SystemExit("Release version must be a semantic version (tag vX.Y.Z)")
print("RAYDE_VERSION=" + version)
