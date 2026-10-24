#!/bin/bash
# FocusFlow installer.
#
#   curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/focusflow/main/install.sh | bash
#
# Downloads the latest release disk image, copies FocusFlow.app into
# /Applications, and clears the download quarantine flag.

set -euo pipefail

REPO="aadityakumarsah/focusflow"
APP="FocusFlow"
TARGET="${FOCUSFLOW_PREFIX:-/Applications}"

die() { printf '\033[31merror\033[0m  %s\n' "$1" >&2; exit 1; }
info() { printf '\033[32m==>\033[0m %s\n' "$1"; }

[[ "$(uname -s)" == "Darwin" ]] || die "FocusFlow only runs on macOS."

major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$major" -ge 14 ]] || die "macOS 14 or later is required (found $(sw_vers -productVersion))."

info "Looking up the latest release"
release=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") \
    || die "Could not reach the GitHub releases API."
asset=$(printf '%s' "$release" | grep -o 'https://[^"]*\.dmg' | head -n 1 || true)
[[ -n "$asset" ]] || die "No .dmg asset found in the latest release."

work=$(mktemp -d)
mount=""
cleanup() {
    [[ -n "$mount" ]] && hdiutil detach "$mount" -quiet 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

info "Downloading ${asset##*/}"
curl -fL# -o "$work/focusflow.dmg" "$asset" || die "Download failed."

info "Mounting the disk image"
mount="$work/mnt"
mkdir -p "$mount"
hdiutil attach "$work/focusflow.dmg" -nobrowse -readonly -mountpoint "$mount" -quiet \
    || die "Could not mount the disk image."
[[ -d "$mount/$APP.app" ]] || die "$APP.app was not found inside the disk image."

if [[ -d "$TARGET/$APP.app" ]]; then
    info "Replacing the existing copy in $TARGET"
    rm -rf "$TARGET/$APP.app" 2>/dev/null \
        || die "Cannot replace $TARGET/$APP.app — quit $APP, or rerun with sudo."
fi

info "Installing to $TARGET"
cp -R "$mount/$APP.app" "$TARGET/$APP.app" 2>/dev/null \
    || die "Cannot write to $TARGET — rerun with sudo, or set FOCUSFLOW_PREFIX=\"\$HOME/Applications\"."

# The app is ad-hoc signed, not notarized, so clear the quarantine flag that
# would otherwise make Gatekeeper refuse the first launch.
xattr -cr "$TARGET/$APP.app" 2>/dev/null || true

info "Installed $APP to $TARGET"
printf '\n    open -a %s\n\n' "$APP"
printf 'Grant Screen Recording permission on the first recording:\n'
printf 'System Settings → Privacy & Security → Screen Recording.\n'
