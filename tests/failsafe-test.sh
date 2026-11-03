#!/bin/sh
# Exercises the failsafe daemon's lid-open logic as the current user, with a
# fake lid, a temporary heartbeat file and a dry run, so nothing real is
# unfrozen, dimmed or restarted. Safe to run while Sleepwalker is running.
#   tests/failsafe-test.sh [path to sleepwalker-failsafe]
set -e
cd "$(dirname "$0")/.."
BIN=${1:-$(swift build -c release --show-bin-path)/SleepwalkerFailsafe}
[ -x "$BIN" ] || swift build -c release --product SleepwalkerFailsafe >/dev/null
TMP=$(mktemp -d)
trap 'kill $PID 2>/dev/null || true; rm -rf "$TMP"' EXIT
export SLEEPWALKER_FAILSAFE_TEST_LID="$TMP/lid" SLEEPWALKER_FAILSAFE_TEST_HEARTBEAT="$TMP/hb.json" \
       SLEEPWALKER_FAILSAFE_DRY_RUN=1 SLEEPWALKER_FAILSAFE_TEST_FAST=1
fail=0
hb() { printf '{"time":%s,"pid":1,"lidClosed":%s,"dimmed":%s,"savedBrightness":0.6,"quit":false}' "$(date +%s)" "$1" "$2" > "$TMP/hb.json"; }
# Each case: heartbeat after the lid opens, expected log lines (grep -E), unexpected ones.
check() { # name, lid-closed hb, dimmed hb (after open), expect, reject, [recover-midway]
    : > "$TMP/log"; echo closed > "$TMP/lid"; hb true true
    "$BIN" daemon 2>"$TMP/log" & PID=$!
    sleep 1; echo open > "$TMP/lid"; sleep 0.5
    hb "$2" "$3"
    sleep 2.2   # past the 6 s check (1.5 s scaled)
    [ -n "$6" ] && hb false false
    sleep 3     # past the 16 s restart (4 s scaled)
    kill $PID; wait $PID 2>/dev/null || true
    if grep -qE "$4" "$TMP/log" && { [ -z "$5" ] || ! grep -qE "$5" "$TMP/log"; }; then echo "ok   $1"
    else echo "FAIL $1"; sed 's/^/     /' "$TMP/log"; fail=1; fi
}
check "healthy: Sleepwalker reports lid open"   false false "started" "would"
check "hung: unfreeze, then restart"            true  true  "would unfreeze.*|would restart" "" 
grep -q "would restart" "$TMP/log" || { echo "FAIL hung case did not restart"; fail=1; }
check "hung, recovers after unfreeze"           true  true  "recovered after being unfrozen" "would restart" midway
check "lid seen open but screen still dimmed"   false true  "would restore brightness to 0.6" "would restart"
exit $fail
