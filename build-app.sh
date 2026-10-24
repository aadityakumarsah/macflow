#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
DIST_APP="$ROOT_DIR/dist/FocusFlow.app"
WORK=$(mktemp -d)
APP_DIR="$WORK/FocusFlow.app"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT_DIR"
swift build -c release
"$ROOT_DIR/scripts/make-icon.sh" >/dev/null
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/FocusFlow" "$APP_DIR/Contents/MacOS/FocusFlow"
cp -R "$ROOT_DIR/.build/release/FocusFlow_FocusFlow.bundle" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - \
    --requirements '=designated => identifier "app.focusflow.recorder"' \
    "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$DIST_APP"
ditto --norsrc "$APP_DIR" "$DIST_APP"

echo "$DIST_APP"
