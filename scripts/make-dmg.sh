#!/bin/zsh
set -euo pipefail

# Packages dist/FocusFlow.app into a distributable disk image.
# Usage: ./scripts/make-dmg.sh [version]
ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/FocusFlow.app"

if [[ ! -d "$APP_DIR" ]]; then
    echo "Build the app first: ./build-app.sh" >&2
    exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")}"
STAGE="$ROOT_DIR/.build/dmg"
DMG="$ROOT_DIR/dist/FocusFlow-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/FocusFlow.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "FocusFlow $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "$DMG"
