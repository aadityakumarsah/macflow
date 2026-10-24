#!/bin/zsh
set -euo pipefail

# Builds Resources/AppIcon.icns from the brand logo.
ROOT_DIR="${0:A:h:h}"
SOURCE="$ROOT_DIR/Resources/Brand/logo.png"
ICONSET="$ROOT_DIR/.build/AppIcon.iconset"
OUTPUT="$ROOT_DIR/Resources/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z $size $size "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
rm -rf "$ICONSET"
echo "$OUTPUT"
