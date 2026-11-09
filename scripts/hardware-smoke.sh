#!/bin/bash
# Live smoke test of build/Lidlight.app on a Mac with the lid logo. Drives the real logo for about
# a minute (steady level, pause rule, breathe, agents pulse, crash recovery) and checks that Apple's
# settings come back and that no NVRAM writes happen. Restores the app's saved settings at the end.
#
# Usage: scripts/hardware-smoke.sh        (lid open, display awake; run `make app` first)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lidlight.app"
CTL="$APP/Contents/Helpers/lidlightctl"
DOMAIN="app.lidlight.Lidlight"
FAILED=0

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILED=1; }

[ -x "$CTL" ] || { echo "Build the app first: make app"; exit 2; }
ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = No' || { echo "Open the lid first."; exit 2; }
command -v jq >/dev/null || { echo "jq is required"; exit 2; }
pgrep -x LidlightApp >/dev/null && { echo "Quit Lidlight first."; exit 2; }

nvram_writes() { ioreg -l -w0 | grep -o '"01:bklb-backlight-dc"={"Write"=[0-9]*' | grep -o '[0-9]*$'; }
status_json() { "$CTL" status --json 2>/dev/null; }
field() { status_json | jq -r "$1"; }
app_running() { pgrep -x LidlightApp >/dev/null; }
guard_running() { pgrep -f 'lidlightctl guard' >/dev/null; }

# `defaults export` of a missing domain prints an empty plist, so check existence first.
SAVED_SETTINGS=""
if defaults read "$DOMAIN" >/dev/null 2>&1; then SAVED_SETTINGS="$(defaults export "$DOMAIN" -)"; fi

# settings <mode> <brightness 0-1> <breathePeriod> <pauseWhileKeyboardLit true|false>
settings() {
    local json
    json=$(printf '{"isOn":true,"mode":"%s","effects":{"brightness":%s,"breathePeriod":%s,"musicIntensity":0.7,"musicStrobe":false,"fullBrightnessInAnyRoom":false,"pauseWhileKeyboardLit":%s,"agentAwayAfter":30},"openAtLogin":false,"globalShortcutEnabled":true,"agentsConnected":false}' "$1" "$2" "$3" "$4")
    defaults write "$DOMAIN" settings.v1 -data "$(printf '%s' "$json" | xxd -p | tr -d '\n')"
}

launch() {
    open -n "$APP"
    for _ in $(seq 1 50); do app_running && break; sleep 0.1; done
    sleep "${1:-2.5}"
}

quit_app() {
    osascript -e "tell application id \"$DOMAIN\" to quit" >/dev/null 2>&1
    for _ in $(seq 1 60); do app_running || break; sleep 0.1; done
    sleep 0.7
}

# sample_factor <seconds>: prints "min max" of LEPWMState.Factor sampled every ~0.1 s
sample_factor() {
    local end=$((SECONDS + $1)) values=""
    while [ "$SECONDS" -lt "$end" ]; do
        values="$values $(field .state.factor)"
        sleep 0.1
    done
    echo "$values" | tr ' ' '\n' | awk 'NF { if (min == "" || $1 < min) min = $1; if (max == "" || $1 > max) max = $1 } END { printf "%.3f %.3f\n", min, max }'
}

expect_restored() {
    local label="$1"
    [ "$(field .dirtyMarkerPresent)" = "false" ] && pass "$label: dirty marker removed" || fail "$label: dirty marker still present"
    [ "$(field .tablesAreAppleDefaults)" = "true" ] && pass "$label: Apple's tables restored" || fail "$label: tables not restored"
    [ "$(field .power)" = "2" ] && pass "$label: logo on" || fail "$label: logo power is $(field .power)"
    sleep 0.5
    local f; f=$(field .state.factor)
    awk -v f="$f" 'BEGIN { exit !(f > 0.95) }' && pass "$label: factor back to lit ($f)" || fail "$label: factor $f"
    guard_running && fail "$label: guardian still running" || pass "$label: guardian exited"
}

cleanup() {
    app_running && quit_app
    pkill -x LidlightApp 2>/dev/null
    "$CTL" restore >/dev/null 2>&1
    rm -f "$HOME/Library/Application Support/Lidlight/agents/lidlight-smoke.json"
    # `defaults import` merges, so clear the test settings first.
    defaults delete "$DOMAIN" >/dev/null 2>&1
    if [ -n "$SAVED_SETTINGS" ]; then printf '%s' "$SAVED_SETTINGS" | defaults import "$DOMAIN" -; fi
}
trap cleanup EXIT

NV_BEFORE=$(nvram_writes)
KEYBOARD_NOTE="(keyboard backlight state decides whether the pause test can trigger)"

echo "▶︎ 1. Steady at 50 % (220 nits)"
settings steady 0.5 6 true
launch
app_running && pass "app running" || fail "app did not start"
guard_running && pass "guardian running" || fail "guardian not running"
[ "$(field .dirtyMarkerPresent)" = "true" ] && pass "dirty marker written" || fail "no dirty marker"
[ "$(field .tablesAreAppleDefaults)" = "false" ] && pass "level tables written" || fail "tables still Apple's"
pre=$(field .state.preRestrictionNits)
echo "    pre-restriction now $pre nits (the mapping applies at the next display-brightness update)"
quit_app
expect_restored "quit"

echo "▶︎ 2. Breathe with 'pause while keyboard lit' on $KEYBOARD_NOTE"
settings breathe 0.8 4 true
launch
read -r lo hi <<<"$(sample_factor 5)"
echo "    factor range $lo … $hi"
quit_app
expect_restored "quit"

echo "▶︎ 3. Breathe (4 s) with the keyboard pause off"
settings breathe 0.8 4 false
launch
read -r lo hi <<<"$(sample_factor 9)"
awk -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(lo < 0.2 && hi > 0.8) }' && pass "breathing: factor $lo … $hi" || fail "no breathing: factor $lo … $hi"
quit_app
expect_restored "quit"

echo "▶︎ 4. Agents: a working session pulses"
settings agents 0.8 6 false
launch
printf '{"session_id":"lidlight-smoke","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' | "$CTL" agent-event
sleep 1
read -r lo hi <<<"$(sample_factor 6)"
awk -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(lo < 0.75 && hi > 0.9) }' && pass "working pulse: factor $lo … $hi" || fail "no pulse: factor $lo … $hi"
printf '{"session_id":"lidlight-smoke","hook_event_name":"SessionEnd","cwd":"/tmp"}' | "$CTL" agent-event
quit_app
expect_restored "quit"

echo "▶︎ 5. Crash: kill -9 while breathing, the guardian restores"
settings breathe 0.8 4 false
launch 3
pkill -9 -x LidlightApp
sleep 1.5
expect_restored "crash"

NV_AFTER=$(nvram_writes)
[ "$NV_BEFORE" = "$NV_AFTER" ] && pass "no NVRAM writes ($NV_AFTER)" || fail "NVRAM writes went $NV_BEFORE → $NV_AFTER"

echo
[ "$FAILED" = 0 ] && echo "Smoke test passed." || echo "Smoke test FAILED."
exit "$FAILED"
