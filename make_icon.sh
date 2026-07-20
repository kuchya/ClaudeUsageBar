#!/bin/bash
# Generate AppIcon.icns from make_icon.swift. Run once (or when the design changes).
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
BASE="$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "→ Rendering master 1024px icon…"
swift make_icon.swift "$BASE"

echo "→ Generating iconset sizes…"
for s in 16 32 64 128 256 512 1024; do
    sips -z $s $s "$BASE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
# Retina (@2x) variants
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

echo "→ Building AppIcon.icns…"
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$TMP"
echo "✅ Wrote ./AppIcon.icns"
