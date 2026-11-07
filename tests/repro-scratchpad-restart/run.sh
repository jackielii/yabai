#!/bin/bash
# Repro: a window put away as a scratchpad when yabai restarts comes back untracked.
#
# yabai puts a scratchpad window away by ordering it out of the screen. After a restart the new
# yabai has to find that window again and re-apply the scratchpad rule (yabairc ends with
# `yabai -m rule --apply`). If it cannot resolve the window, the window stays untracked
# (has-ax-reference false) and the scratchpad hotkey cannot bring it back.
#
# Usage: run.sh [--other-space]
#   --other-space  leave a different space active during the restart, so the put-away window is on
#                  an inactive space (the AX API does not return windows on inactive spaces).
# The test runs yabai as a temporary launchd job with --verbose (log in $WORK/yabai.log) and puts the
# launchd service back when it finishes.
# Exit status: 0 pass, 1 fail, 2 setup error.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE_SRC=$HERE/../repro-display-sleep-launch/probe.swift
WORK=${TMPDIR:-/tmp}/yabai-repro-scratchpad
APP=$WORK/YabaiProbe.app
YABAI=$HOME/.local/bin/yabai
OTHER_SPACE=false
[ "${1:-}" = "--other-space" ] && OTHER_SPACE=true

mkdir -p "$WORK"

if [ ! -x "$APP/Contents/MacOS/YabaiProbe" ] || [ "$PROBE_SRC" -nt "$APP/Contents/MacOS/YabaiProbe" ]; then
    mkdir -p "$APP/Contents/MacOS"
    swiftc -O "$PROBE_SRC" -o "$APP/Contents/MacOS/YabaiProbe" || exit 2
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

wait_yabai() {
    for _ in $(seq 1 20); do
        sleep 0.5
        "$YABAI" -m query --windows >/dev/null 2>&1 && return 0
    done
    return 1
}

probe_rule() {
    "$YABAI" -m rule --add label=probe-scratch app="^YabaiProbe$" manage=off scratchpad=probe >/dev/null
    "$YABAI" -m rule --apply probe-scratch
}

probe_window() {
    "$YABAI" -m query --windows | jq -c --argjson p "$(pgrep -x YabaiProbe)" \
        'map(select(.pid == $p)) | first // empty | {id, ax: ."has-ax-reference", vis: ."is-visible", scratchpad, space}'
}

start_space=$("$YABAI" -m query --spaces --space | jq .index)
cleanup() {
    "$YABAI" -m rule --remove probe-scratch >/dev/null 2>&1
    pkill -x YabaiProbe
    if [ -n "${YPID:-}" ]; then
        launchctl remove yabai-repro-verbose 2>/dev/null; sleep 1
        "$YABAI" --start-service >/dev/null 2>&1
        wait_yabai
        sudo -n "$YABAI" --load-sa >/dev/null 2>&1
    fi
    "$YABAI" -m space --focus "$start_space" >/dev/null 2>&1
}
trap cleanup EXIT

# Launch the probe, make it a scratchpad, and put it away.
pkill -x YabaiProbe; sleep 1
open -g --env PROBE_CMD="$WORK/probe.cmd" --stderr "$WORK/probe.log" "$APP"
for _ in $(seq 1 10); do sleep 0.5; [ -n "$(probe_window)" ] && break; done
probe_rule
sleep 0.5
"$YABAI" -m window --toggle probe >/dev/null 2>&1   # shown after the rule; this puts it away
sleep 1
before=$(probe_window)
echo "before restart: $before"
[ "$(jq -r .scratchpad <<<"$before")" = probe ] && [ "$(jq -r .vis <<<"$before")" = false ] ||
    { echo "setup error: probe is not a put-away scratchpad" >&2; exit 2; }
probe_space=$(jq .space <<<"$before")

if $OTHER_SPACE; then
    other=$(( probe_space == 1 ? 2 : 1 ))
    "$YABAI" -m space --focus "$other"
    sleep 1
fi
echo "active space during restart: $("$YABAI" -m query --spaces --space | jq .index) (probe on $probe_space)"

# Restart yabai with startup logging.
"$YABAI" --stop-service >/dev/null 2>&1; sleep 1
# A launchd job, so Accessibility is checked against the yabai binary, not this shell's app.
launchctl remove yabai-repro-verbose 2>/dev/null
: > "$WORK/yabai.log"
launchctl submit -l yabai-repro-verbose -o "$WORK/yabai.log" -e "$WORK/yabai.log" -- "$YABAI" --verbose
YPID=launchd
wait_yabai || { echo "setup error: yabai did not start" >&2; exit 2; }
sleep 2
probe_rule   # what yabairc's `yabai -m rule --apply` does for the real scratchpads
sleep 1

after=$(probe_window)
echo "after restart:  $after"
"$YABAI" -m window --toggle probe >/dev/null 2>&1
sleep 1
shown=$(probe_window)
echo "after toggle:   $shown"
grep -i "YabaiProbe" "$WORK/yabai.log" | grep -iv "title_changed" | head -8

if [ "$(jq -r .ax <<<"$after")" = true ] && [ "$(jq -r .scratchpad <<<"$after")" = probe ] &&
   [ "$(jq -r .vis <<<"$shown")" = true ]; then
    echo "PASS: the put-away scratchpad window is tracked after a restart and its hotkey shows it"
    exit 0
fi
echo "FAIL: the put-away scratchpad window is not tracked after a restart"
exit 1
