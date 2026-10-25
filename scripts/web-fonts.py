#!/usr/bin/env python3
"""Rebuild the page's bundled fonts, or check their coverage with --check.

Requires fonttools[woff]==4.67.0. Normal web builds use the committed assets.
"""
from pathlib import Path
import sys
import tempfile
from urllib.request import urlopen

from fontTools import subset
from fontTools.merge import Merger
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = ROOT / "assets/fonts"
NOTICES = ROOT / "assets/notices"
GOOGLE = "https://raw.githubusercontent.com/google/fonts/e7db6ca603fd4862010383ff17ffd6cc4ffac1c0/ofl/"
JETBRAINS = "https://raw.githubusercontent.com/JetBrains/JetBrainsMono/cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9/"
KEYS = "⌘⇧⌥⌃←→↑↓⌫↩⎋⇥⏎⌦"


def check():
    for filename, family in [("JetBrainsMono-Regular.woff2", "JetBrains Mono"), ("KeyboardSymbols.ttf", "Blinc Noto Symbols")]:
        font = TTFont(FONTS / filename)
        assert font["name"].getDebugName(1) == family, filename
        missing = [c for c in KEYS if not font.getBestCmap().get(ord(c))]
        assert not missing, f"{filename}: missing {''.join(missing)}"
        for char in KEYS:
            glyph = font["glyf"][font.getBestCmap()[ord(char)]]
            assert glyph.isComposite() or glyph.numberOfContours > 0, f"{filename}: empty {char}"
        print(f"{filename}: all {len(KEYS)} keyboard symbols have outlines")


def build():
    FONTS.mkdir(parents=True, exist_ok=True)
    def fetch(url, destination):
        with urlopen(url, timeout=60) as response:
            destination.write_bytes(response.read())

    fetch(JETBRAINS + "fonts/webfonts/JetBrainsMono-Regular.woff2", FONTS / "JetBrainsMono-Regular.woff2")
    fetch(JETBRAINS + "OFL.txt", NOTICES / "font-jetbrains-mono-OFL.txt")
    # The renderer selects one symbol face, so complementary Noto faces share a subset.
    chars = {ord(c) for p in (ROOT / "src").rglob("*.hx") for c in p.read_text() if ord(c) > 127}
    chars.update(map(ord, KEYS))
    with tempfile.TemporaryDirectory() as work:
        parts = []
        for directory, filename in [("notosanssymbols", "NotoSansSymbols%5Bwght%5D.ttf"), ("notosansmath", "NotoSansMath-Regular.ttf"), ("notosanssymbols2", "NotoSansSymbols2-Regular.ttf")]:
            path = Path(work) / (directory + ".ttf")
            fetch(GOOGLE + directory + "/" + filename, path)
            fetch(GOOGLE + directory + "/OFL.txt", NOTICES / ("font-" + directory + "-OFL.txt"))
            font = TTFont(path)
            if "fvar" in font:
                font = instantiateVariableFont(font, {"wght": 400}, inplace=True)
            options = subset.Options()
            options.recalc_timestamp = False
            options.hinting = False
            cutter = subset.Subsetter(options=options)
            cutter.populate(unicodes=chars)
            cutter.subset(font)
            # The symbol face has no contextual layout; keep merging independent of font-specific feature tables.
            for table in ["GSUB", "GPOS", "GDEF", "vhea", "vmtx", "MATH", "STAT"]:
                if table in font:
                    del font[table]
            font.save(path)
            parts.append(str(path))
        font = Merger().merge(parts)
        font["head"].created = font["head"].modified = 2082844800
        names = {1: "Blinc Noto Symbols", 2: "Regular", 3: "RayDE Keyboard Symbols", 4: "RayDE Keyboard Symbols", 6: "RayDEKeyboardSymbols", 16: "Blinc Noto Symbols", 17: "Regular"}
        for record in font["name"].names:
            if record.nameID in names:
                record.string = names[record.nameID].encode(record.getEncoding())
        font.recalcTimestamp = False
        font.save(FONTS / "KeyboardSymbols.ttf")
    check()


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        check()
    elif not sys.argv[1:]:
        build()
    else:
        raise SystemExit(__doc__)
