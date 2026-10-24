#!/bin/bash
# FocusFlow installer.
#
#   curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/macflow/main/install.sh | bash
#
# Downloads the latest release disk image, copies FocusFlow.app into
# /Applications, and clears the download quarantine flag.

set -euo pipefail

REPO="aadityakumarsah/macflow"
APP="FocusFlow"
TARGET="${FOCUSFLOW_PREFIX:-/Applications}"

# ---------------------------------------------------------------- appearance

# Degrade to plain text when stdout is not a terminal, when NO_COLOR is set,
# or on a dumb terminal — otherwise a piped log fills up with escape codes.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    TTY=1
    DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
    TEAL=$'\033[38;5;30m'; MIST=$'\033[38;5;109m'
    GREEN=$'\033[38;5;35m'; RED=$'\033[38;5;167m'
    HIDE=$'\033[?25l'; SHOW=$'\033[?25h'; CLEAR=$'\033[2K\r'
else
    TTY=0
    DIM=""; BOLD=""; RESET=""; TEAL=""; MIST=""; GREEN=""; RED=""
    HIDE=""; SHOW=""; CLEAR=$'\r'
fi

COLUMNS_=$(tput cols 2>/dev/null || echo 80)
[[ "$COLUMNS_" -lt 48 ]] && COLUMNS_=48

cleanup_tty() { [[ "$TTY" == 1 ]] && printf '%s' "$SHOW"; }
trap cleanup_tty EXIT

die() {
    printf '%s  %s%s%s %s\n' "$CLEAR" "$RED" "✗" "$RESET" "$1" >&2
    exit 1
}

step()  { printf '%s  %s%s%s  %s\n' "$CLEAR" "$GREEN" "✓" "$RESET" "$1"; }
note()  { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }

banner() {
    [[ "$TTY" == 0 ]] && { printf '\nFocusFlow installer\n\n'; return; }
    printf '\n'
    printf '  %s╭───────────────────────────────────────────╮%s\n' "$TEAL" "$RESET"
    printf '  %s│%s  %sFocusFlow%s  %s· record your Mac%s             %s│%s\n' \
        "$TEAL" "$RESET" "$BOLD" "$RESET" "$MIST" "$RESET" "$TEAL" "$RESET"
    printf '  %s╰───────────────────────────────────────────╯%s\n\n' "$TEAL" "$RESET"
}

# Spinner that runs while $1 (a pid) is alive.
spin() {
    local pid=$1 label=$2
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    [[ "$TTY" == 0 ]] && { wait "$pid"; return $?; }
    printf '%s' "$HIDE"
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf '%s  %s%s%s  %s' "$CLEAR" "$TEAL" "${frames:$i:1}" "$RESET" "$label"
        sleep 0.08
    done
    printf '%s' "$SHOW"
    wait "$pid"
}

# Renders curl's progress as a single bar line.
# curl writes "dlnow dltotal" pairs to the pipe; we repaint on each one.
progress_bar() {
    local width=$(( COLUMNS_ - 34 ))
    [[ "$width" -gt 34 ]] && width=34
    [[ "$width" -lt 10 ]] && width=10

    local now total pct filled empty mb_now mb_total
    while read -r now total; do
        [[ -z "${total:-}" || "$total" -le 0 ]] && continue
        pct=$(( now * 100 / total ))
        [[ "$pct" -gt 100 ]] && pct=100
        filled=$(( pct * width / 100 ))
        empty=$(( width - filled ))

        if [[ "$TTY" == 0 ]]; then continue; fi

        mb_now=$(awk -v b="$now" 'BEGIN{printf "%.1f", b/1048576}')
        mb_total=$(awk -v b="$total" 'BEGIN{printf "%.1f", b/1048576}')

        printf '%s  %s⠿%s  Downloading  %s' "$CLEAR" "$TEAL" "$RESET" "$TEAL"
        # printf repeats its format once even with no arguments, so an empty
        # seq would still draw a block at 0%.
        [[ "$filled" -gt 0 ]] && printf '█%.0s' $(seq 1 "$filled")
        printf '%s' "$RESET$DIM"
        [[ "$empty" -gt 0 ]] && printf '░%.0s' $(seq 1 "$empty")
        printf '%s  %3d%%  %s%s/%s MB%s' "$RESET" "$pct" "$DIM" "$mb_now" "$mb_total" "$RESET"
    done
    [[ "$TTY" == 1 ]] && printf '%s' "$CLEAR"
    return 0
}

# ---------------------------------------------------------------- preflight

banner

[[ "$(uname -s)" == "Darwin" ]] || die "FocusFlow only runs on macOS."

major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$major" -ge 14 ]] || die "macOS 14 or later is required (found $(sw_vers -productVersion))."

work=$(mktemp -d)
mount=""
cleanup() {
    cleanup_tty
    [[ -n "$mount" ]] && hdiutil detach "$mount" -quiet 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# ---------------------------------------------------------------- resolve

curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" > "$work/release.json" 2>/dev/null &
spin $! "Resolving the latest release" || die "Could not reach the GitHub releases API."

asset=$(grep -o 'https://[^"]*\.dmg' "$work/release.json" | head -n 1 || true)
[[ -n "$asset" ]] || die "No .dmg asset found in the latest release."
tag=$(grep -o '"tag_name": *"[^"]*"' "$work/release.json" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)

step "Release resolved${tag:+          $DIM$tag$RESET}"

# ---------------------------------------------------------------- download

# curl's own --progress-bar writes a '#' bar to stderr that cannot be parsed
# back into a percentage, so ask for the size up front, let curl run quietly in
# the background, and draw the bar from the file as it lands.
#
# The size is only used to draw that bar, so the extra request is skipped
# entirely when there is no terminal to draw it on. It is also capped: release
# assets redirect to signed storage URLs, and a slow HEAD there would otherwise
# stall the install before the download has even started.
total=""
if [[ "$TTY" == 1 ]]; then
    total=$(curl -fsSLI --connect-timeout 10 --max-time 25 "$asset" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub(/\r/,""); print $2}' \
        | tail -n1) || true
fi

curl -fL --silent --show-error \
     --connect-timeout 20 --retry 2 --retry-delay 2 \
     --output "$work/focusflow.dmg" "$asset" &
dl_pid=$!

if [[ "$TTY" == 1 && -n "${total:-}" && "$total" -gt 0 ]]; then
    {
        while kill -0 "$dl_pid" 2>/dev/null; do
            printf '%s %s\n' "$(stat -f%z "$work/focusflow.dmg" 2>/dev/null || echo 0)" "$total"
            sleep 0.09
        done
        printf '%s %s\n' "$total" "$total"
    } | progress_bar
else
    spin "$dl_pid" "Downloading the disk image" || true
fi

wait "$dl_pid" || die "Download failed."
[[ -s "$work/focusflow.dmg" ]] || die "Download produced an empty file."

size=$(awk -v b="$(stat -f%z "$work/focusflow.dmg")" 'BEGIN{printf "%.1f", b/1048576}')
step "Downloaded            ${DIM}${size} MB${RESET}"

# ---------------------------------------------------------------- install

mount="$work/mnt"
mkdir -p "$mount"
hdiutil attach "$work/focusflow.dmg" -nobrowse -readonly -mountpoint "$mount" -quiet \
    || die "Could not mount the disk image."
[[ -d "$mount/$APP.app" ]] || die "$APP.app was not found inside the disk image."
step "Disk image mounted"

if [[ -d "$TARGET/$APP.app" ]]; then
    rm -rf "$TARGET/$APP.app" 2>/dev/null \
        || die "Cannot replace $TARGET/$APP.app — quit $APP, or rerun with sudo."
fi

cp -R "$mount/$APP.app" "$TARGET/$APP.app" 2>/dev/null \
    || die "Cannot write to $TARGET — rerun with sudo, or set FOCUSFLOW_PREFIX=\"\$HOME/Applications\"."

# The app is ad-hoc signed, not notarized, so clear the quarantine flag that
# would otherwise make Gatekeeper refuse the first launch.
xattr -cr "$TARGET/$APP.app" 2>/dev/null || true
step "Installed             ${DIM}${TARGET}${RESET}"

# ---------------------------------------------------------------- done

printf '\n'
if [[ "$TTY" == 1 ]]; then
    printf '  %s%sFocusFlow is ready.%s  %s→%s  %sopen -a FocusFlow%s\n\n' \
        "$BOLD" "$GREEN" "$RESET" "$MIST" "$RESET" "$BOLD" "$RESET"
else
    printf '  FocusFlow is ready.  Run: open -a FocusFlow\n\n'
fi
note "Screen Recording permission is requested on your first recording:"
note "System Settings → Privacy & Security → Screen Recording."
printf '\n'
