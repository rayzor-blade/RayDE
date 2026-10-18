#!/usr/bin/env bash
# Regenerates the app icons for every platform from assets/rayde-icon.png, into assets/icons.
# The results are committed, so only whoever changes the icon needs ImageMagick (magick); macOS also uses iconutil.
#
#   macOS    assets/icons/rayde.icns         the icon on the Big Sur grid, with its shadow
#   Windows  assets/icons/rayde.ico          16 to 256 px, PNG-compressed
#   Linux    assets/icons/hicolor/<n>x<n>/apps/rayde.png
#   window   assets/icons/rayde-256.rgba     raw RGBA, embedded in the program as its window icon
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src="$here/assets/rayde-icon.png"
out="$here/assets/icons"
command -v magick >/dev/null || { echo "icons.sh: needs ImageMagick (magick)" >&2; exit 1; }
[ -f "$src" ] || { echo "icons.sh: no $src" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$out"
mkdir -p "$out"

# The master is a rounded square already, with the margin of macOS's grid and nothing else around it.
# macOS: that on a 1024 px canvas, with a soft shadow below it.
magick "$src" -resize 1024x1024 -background none -gravity center -extent 1024x1024 "$work/body-1024.png"
magick "$work/body-1024.png" \( +clone -background black -shadow 35x14+0+10 \) +swap -background none -layers merge +repage -gravity center -extent 1024x1024 "$work/mac-1024.png"
# Windows and Linux: the shape trimmed of its margin, so it fills the canvas as their icons do.
magick "$src" -trim +repage -resize 1008x1008 -background none -gravity center -extent 1024x1024 "PNG32:$work/flat-1024.png"

# Linux, in the hicolor theme, and the sizes the other platforms are built from.
for s in 16 24 32 48 64 128 256 512; do
  mkdir -p "$out/hicolor/${s}x${s}/apps"
  magick "$work/flat-1024.png" -filter Lanczos -resize "${s}x${s}" "PNG32:$out/hicolor/${s}x${s}/apps/rayde.png"
done
mkdir -p "$out/hicolor/1024x1024/apps"
cp "$work/flat-1024.png" "$out/hicolor/1024x1024/apps/rayde.png"

# Windows: one .ico holding several sizes, each a 32-bit PNG (the container is a directory of them, as Vista and later read it).
python3 - "$out" <<'PY'
import struct, sys
out = sys.argv[1]
sizes = [16, 24, 32, 48, 64, 128, 256]
images = [open(f"{out}/hicolor/{s}x{s}/apps/rayde.png", "rb").read() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries, data = b"", b""
for s, png in zip(sizes, images):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(png), offset + len(data))
    data += png
open(f"{out}/rayde.ico", "wb").write(header + entries + data)
PY

# The window's own icon, as raw pixels the program can hand to the window without decoding anything.
magick "$out/hicolor/256x256/apps/rayde.png" -depth 8 "rgba:$out/rayde-256.rgba"

# macOS: an iconset of the sizes it asks for, made into an .icns.
set="$work/rayde.iconset"
mkdir -p "$set"
for s in 16 32 128 256 512; do
  magick "$work/mac-1024.png" -filter Lanczos -resize "${s}x${s}" "PNG32:$set/icon_${s}x${s}.png"
  magick "$work/mac-1024.png" -filter Lanczos -resize "$((s * 2))x$((s * 2))" "PNG32:$set/icon_${s}x${s}@2x.png"
done
if command -v iconutil >/dev/null; then
  iconutil -c icns "$set" -o "$out/rayde.icns"
else
  magick "$set/icon_512x512@2x.png" "$out/rayde.icns"
fi
echo "icons written to ${out#"$here/"}:"
find "$out" -type f | sed "s|$here/||" | sort
