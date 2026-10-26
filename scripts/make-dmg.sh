#!/bin/zsh
set -euo pipefail

# Packages dist/FocusFlow.app into a styled disk image.
#
# Usage: ./scripts/make-dmg.sh [version]
#
# A disk image cannot animate — what it can carry is a window that is already
# laid out when it opens: a background plate, both icons placed on it, no
# toolbar or sidebar. That layout lives in the volume's .DS_Store, which only
# the Finder can write, so the styling pass drives the Finder through
# AppleScript. The first run may ask for permission to control the Finder, and
# a window will appear briefly. If that pass fails for any reason the script
# still emits a working, unstyled image rather than nothing.

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/FocusFlow.app"
BG_SOURCE="$ROOT_DIR/scripts/dmg-background.svg.html"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

VOLNAME="FocusFlow"
WIN_W=640
WIN_H=440
ICON_SIZE=112
APP_X=160; APP_Y=198
LINK_X=480; LINK_Y=198

if [[ ! -d "$APP_DIR" ]]; then
    echo "Build the app first: ./build-app.sh" >&2
    exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")}"
DMG="$ROOT_DIR/dist/FocusFlow-$VERSION.dmg"

WORK=$(mktemp -d)
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
MOUNT="/Volumes/$VOLNAME"

cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------ staging

mkdir -p "$STAGE/.background"
cp -R "$APP_DIR" "$STAGE/FocusFlow.app"
# Desktop-backed folders may attach Finder metadata to the app after the
# build. Strip that metadata and sign the staged copy before sealing the DMG.
xattr -cr "$STAGE/FocusFlow.app"
codesign --force --deep --sign - \
    --requirements '=designated => identifier "app.focusflow.recorder"' \
    "$STAGE/FocusFlow.app"
codesign --verify --deep --strict "$STAGE/FocusFlow.app"
ln -s /Applications "$STAGE/Applications"

# Render the background at 2x, then tag it 144 dpi so the Finder lays it out
# at WIN_W x WIN_H points instead of pixels.
if [[ -x "$CHROME" ]]; then
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
        --user-data-dir="$WORK/chrome-profile" --no-first-run \
        --force-color-profile=srgb \
        --window-size=$((WIN_W * 2)),$((WIN_H * 2)) \
        --virtual-time-budget=6000 \
        --screenshot="$WORK/bg.png" \
        "file://$BG_SOURCE" 2>/dev/null
    # JPEG, not PNG: the plate is a grainy gradient, which PNG stores at
    # ~1.3MB and JPEG at a fraction of that, straight off the disk image size.
    sips -s format jpeg -s formatOptions 82 \
        -s dpiHeight 144 -s dpiWidth 144 "$WORK/bg.png" \
        --out "$STAGE/.background/background.jpg" >/dev/null
else
    echo "note: Chrome not found, building without a background plate." >&2
fi

# Give the mounted volume the app's own icon.
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

# ------------------------------------------------------------- read-write

rm -f "$RW" "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
    -ov -format UDRW -fs HFS+ "$RW" >/dev/null

hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
hdiutil attach "$RW" -nobrowse -mountpoint "$MOUNT" -quiet

# ------------------------------------------------------------------ styling

style_volume() {
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, $((200 + WIN_W)), $((140 + WIN_H))}

        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 12
        set background picture of opts to file ".background:background.jpg"

        set position of item "FocusFlow.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$LINK_X, $LINK_Y}

        close
        open
        update without registering applications
        delay 1.5
        close
    end tell
end tell
APPLESCRIPT
}

if style_volume 2>/dev/null; then
    echo "styled the volume window"
else
    echo "note: could not style the volume (Finder automation unavailable)." >&2
    echo "      The disk image is still valid, just unstyled." >&2
fi

# Mark the volume so the Finder uses .VolumeIcon.icns.
if [[ -f "$MOUNT/.VolumeIcon.icns" ]]; then
    SetFile -a C "$MOUNT" 2>/dev/null || true
fi

sync
hdiutil detach "$MOUNT" -quiet

# ------------------------------------------------------------- compress

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

echo "$DMG"
