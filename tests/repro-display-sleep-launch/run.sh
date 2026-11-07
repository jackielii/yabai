#!/bin/bash
# Repro: an app launched while the display is asleep is never tracked by yabai.
#
# This is how the Rex Beta window got lost: Sparkle auto-updated Rex and relaunched it at night with
# the display asleep. With no active display, the AX API returns none of the new app's windows at
# launch, and nothing retries later, so the window stays untracked (has-ax-reference false,
# is-visible false) until yabai restarts. skhd's cmd-g (@cycle_visible) then skips it.
#
# The test needs no hands: it sleeps the display, launches the probe app, wakes the display with
# caffeinate, then checks the probe window is tracked, visible, and in the cmd-g cycle list.
#
# Usage: run.sh [yabai-binary]
#   With a binary, that build is swapped into ~/.local/bin/yabai for the test and the original put back.
#   The binary must be signed with the same identity as the installed one (yabai-cert), so that the
#   Accessibility grant applies to it.
# Exit status: 0 pass, 1 fail, 2 setup error.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${TMPDIR:-/tmp}/yabai-repro-display-sleep
APP=$WORK/YabaiProbe.app
INSTALLED=$HOME/.local/bin/yabai
YABAI=$INSTALLED

mkdir -p "$WORK"

# Build the probe app bundle (an app bundle, so its activation policy is regular from launch, like Rex).
if [ ! -x "$APP/Contents/MacOS/YabaiProbe" ] || [ "$HERE/probe.swift" -nt "$APP/Contents/MacOS/YabaiProbe" ]; then
    mkdir -p "$APP/Contents/MacOS"
    swiftc -O "$HERE/probe.swift" -o "$APP/Contents/MacOS/YabaiProbe" || exit 2
    cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>YabaiProbe</string>
<key>CFBundleIdentifier</key><string>local.yabai-probe</string>
<key>CFBundleName</key><string>YabaiProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
fi

# Replace the installed binary by moving a new file into place. Copying over it in place makes the
# kernel kill every process running it (the signed pages no longer match), with "Killed: 9".
install_yabai() {
    cp "$1" "$INSTALLED.new" && mv -f "$INSTALLED.new" "$INSTALLED"
}

restart_yabai() {
    "$INSTALLED" --restart-service >/dev/null 2>&1 || "$INSTALLED" --start-service >/dev/null 2>&1
    for _ in $(seq 1 20); do
        sleep 0.5
        "$INSTALLED" -m query --windows >/dev/null 2>&1 && return 0
    done
    echo "setup error: yabai is not responding (Accessibility not granted to this build?)" >&2
    return 1
}

# Swap in the build under test, and put the original back on exit.
if [ $# -ge 1 ]; then
    cp "$INSTALLED" "$WORK/yabai.orig" || exit 2
    trap 'install_yabai "$WORK/yabai.orig"; restart_yabai; pkill -x YabaiProbe' EXIT
    install_yabai "$1" || exit 2
    echo "testing $1 ($(shasum -a 256 "$1" | cut -c1-12))"
    restart_yabai || exit 2
else
    trap 'pkill -x YabaiProbe' EXIT
    echo "testing installed $INSTALLED ($(shasum -a 256 "$INSTALLED" | cut -c1-12))"
    "$YABAI" -m query --windows >/dev/null 2>&1 || { echo "setup error: yabai is not running" >&2; exit 2; }
fi

pkill -x YabaiProbe; sleep 1

# Sleep the display, launch the probe while it is off, then wake the display.
pmset displaysleepnow
sleep 4
open -g --env PROBE_CMD="$WORK/probe.cmd" --stderr "$WORK/probe.log" "$APP"
sleep 4
caffeinate -u -t 2
sleep 4

pid=$(pgrep -x YabaiProbe) || { echo "setup error: probe did not launch" >&2; exit 2; }

# The probe window, and the same list cmd-g cycles through (skhdrc @cycle_visible).
window=$("$YABAI" -m query --windows | jq -c --argjson p "$pid" 'map(select(.pid == $p)) | first // empty')
in_cycle=$("$YABAI" -m query --windows | jq --argjson p "$pid" \
    'map(select(."is-visible" == true and .role != "AXUnknown")) | any(.pid == $p)')

echo "probe window: ${window:-none}"
echo "in cmd-g cycle: $in_cycle"

if [ -n "$window" ] &&
   [ "$(jq -r '."has-ax-reference"' <<<"$window")" = true ] &&
   [ "$(jq -r '."is-visible"' <<<"$window")" = true ] &&
   [ "$in_cycle" = true ]; then
    echo "PASS: the window of an app launched during display sleep is tracked after wake"
    exit 0
fi
echo "FAIL: the window of an app launched during display sleep is not tracked after wake"
exit 1
