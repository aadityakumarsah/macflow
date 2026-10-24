#!/bin/zsh
set -euo pipefail

# Renders the hero plate from scripts/hero-art.svg.html.
#
# The art is procedural SVG — the fog, grain and aquatint are real filter
# passes — so it is rendered through headless Chrome rather than stored as a
# binary we cannot regenerate. Re-run after editing the SVG.

ROOT_DIR="${0:A:h:h}"
SOURCE="$ROOT_DIR/scripts/hero-art.svg.html"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ ! -x "$CHROME" ]]; then
    echo "Google Chrome is required to render the hero art." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$CHROME" --headless --disable-gpu --hide-scrollbars \
    --force-color-profile=srgb \
    --window-size=2400,1350 \
    --virtual-time-budget=5000 \
    --screenshot="$WORK/hero.png" \
    "file://$SOURCE" 2>/dev/null

# WebP: film grain is near-incompressible in PNG (5.5MB) but sits around
# 300KB here, which is what altur.io serves its gradient plates as too.
if ! command -v cwebp >/dev/null; then
    echo "cwebp is required (brew install webp)." >&2
    exit 1
fi

# The small plate is rendered at its own size rather than downscaled:
# downsampling averages the grain away, and the result compresses to a
# smooth, plastic-looking 14KB that does not match the full plate.
"$CHROME" --headless --disable-gpu --hide-scrollbars \
    --force-color-profile=srgb \
    --window-size=1200,675 \
    --virtual-time-budget=5000 \
    --screenshot="$WORK/hero-sm.png" \
    "file://$SOURCE" 2>/dev/null

cwebp -q 80 -quiet "$WORK/hero.png"    -o "$ROOT_DIR/docs/hero.webp"
cwebp -q 80 -quiet "$WORK/hero-sm.png" -o "$ROOT_DIR/docs/hero-sm.webp"

echo "$ROOT_DIR/docs/hero.webp"
