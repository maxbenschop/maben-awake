#!/bin/bash
# Clean lid test. Run with: bash /tmp/aktest/lidtest2.sh
set -u
REPORT="$HOME/Desktop/MabenAwake-lidtest-$(date +%H.%M).txt"; LOG=$(mktemp)
PASS=0; FAIL=0; D=com.maxbenschop.sleepwalker
L="$HOME/Library/Application Support/MabenAwake/leases"
log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
pass() { PASS=$((PASS+1)); log "  ✅ $*"; }
fail() { FAIL=$((FAIL+1)); log "  ❌ $*"; log "     leases: $(ls "$L" | tr '\n' ' ')"; }
tmo()  { perl -e 'alarm shift; exec @ARGV' "$@"; }
ms()   { python3 -c 'import time;print(int(time.time()*1000))'; }
lid()  { ioreg -r -k AppleClamshellState -d 4 | grep -o 'AppleClamshellState" = [A-Za-z]*' | sed 's/.*= //'; }
st()   { [ -n "${1:-}" ] && ps -o state= -p "$1" 2>/dev/null | cut -c1; }
nh()   { pgrep -P "$1" | wc -l | tr -d ' '; }
fh()   { pgrep -P "$1" | xargs -I{} ps -o state= -p {} 2>/dev/null | grep -c '^T'; }
bright(){ "$(dirname "$0")/bright"; }
stopped_apps(){ ps -axo state=,comm= | awk '$1 ~ /^T/' | grep -c -E '\.app/Contents/MacOS/'; }
waitst(){ local s; s=$(ms); while [ $(( $(ms) - s )) -lt $(( $3 * 1000 )) ]; do [ "$(st "$1")" = "$2" ] && { echo $(( $(ms) - s )); return 0; }; sleep 0.05; done; echo timeout; return 1; }

# Clear app requests left by the AI session that started this test.
rm -f "$L"/need-*

log "=== Lid test (clean run) ==="
log "lid=$(lid)  brightness=$(bright)  saved=$(defaults read $D savedBrightness 2>/dev/null || echo none)"
log "leases: $(ls "$L" | tr '\n' ' ')"
[ "$(lid)" = "Yes" ] || { log "lid is open — waiting up to 5 min for it to close"; for i in $(seq 1 300); do [ "$(lid)" = "Yes" ] && break; sleep 1; done; }
[ "$(lid)" = "Yes" ] || { fail "lid never closed"; exit 1; }

log ""; log "## A. Lid closed"
[ "$(bright)" = "0.00" ] && pass "screen brightness is 0" || fail "brightness is $(bright)"
SAVED=$(defaults read $D savedBrightness 2>/dev/null); [ -n "$SAVED" ] && pass "previous brightness saved ($SAVED)" || fail "no saved brightness"
pmset -g | grep -q 'SleepDisabled.*1' && pass "closed-lid sleep disabled" || fail "SleepDisabled != 1"
pmset -g | grep -E '^ *sleep ' | grep -q MabenAwake && pass "system sleep prevented by Maben Awake" || fail "sleep not prevented"
tmo 8 curl -s -o /dev/null -w '%{http_code}' https://www.apple.com | grep -q 200 && pass "network up with lid closed" || fail "network down"
T3=$(ps -axo pid=,comm= | awk '/MacOS\/T3 Code \(Beta\)$/ {print $1; exit}')
[ -n "$T3" ] && [ "$(st "$T3")" != "T" ] && pass "T3 Code awake (Always on), pid $T3" || fail "T3 Code frozen or not found (pid='$T3')"

log ""; log "## B. Freezing with the lid closed"
B1=$(printf '\x44\x69\x61'); B2=$(printf 'Text%s' 'Edit')   # names built at runtime
BR=$(pgrep -x "$B1" | head -1)
[ -z "$BR" ] && { log "  starting browser"; open -g -b company.thebrowser.dia; sleep 2; BR=$(pgrep -x "$B1" | head -1); }
open -g -b com.apple.TextEdit; sleep 1; TE=$(pgrep -x "$B2" | head -1)
log "  browser=$BR  editor=$TE (editor just launched)"
sleep 3; [ "$(st "$TE")" != "T" ] && pass "freshly launched editor NOT frozen during 15s launch grace" || fail "editor frozen while launching"
t=$(waitst "$BR" T 25) && pass "browser frozen (${t}ms), helpers $(fh "$BR")/$(nh "$BR") frozen" || fail "browser not frozen"
t=$(waitst "$TE" T 25) && pass "editor frozen once launch grace ended (${t}ms)" || fail "editor not frozen after grace"
c1=$(ps -o cputime= -p "$BR"); sleep 5; c2=$(ps -o cputime= -p "$BR"); [ "$c1" = "$c2" ] && pass "frozen browser used 0 CPU over 5s" || fail "browser CPU moved $c1 -> $c2"

log ""; log "## C. AI uses the browser (hook input exactly as Claude Code sends it)"
# A browser tool wakes the default browser, which needn't be the one above.
DEFID=$(plutil -convert json -o - "$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist" 2>/dev/null \
    | python3 -c 'import json,sys; print(next((h["LSHandlerRoleAll"] for h in json.load(sys.stdin).get("LSHandlers", []) if h.get("LSHandlerURLScheme") == "https"), "com.apple.safari"))')
DEFAPP=$(mdfind "kMDItemCFBundleIdentifier == '$DEFID'" | head -1)
DEFEXE=$(plutil -extract CFBundleExecutable raw "$DEFAPP/Contents/Info.plist" 2>/dev/null)
DB=$(pgrep -x "$DEFEXE" | head -1)
if [ -z "$DB" ]; then log "  starting the default browser ($DEFID)"; open -g -b "$DEFID"; sleep 2; DB=$(pgrep -x "$DEFEXE" | head -1); fi
log "  default browser: $DEFID, pid $DB"
waitst "$DB" T 25 >/dev/null || fail "default browser not frozen before the hook"
S='"session_id":"lidtest2-x"'
t0=$(ms); printf '%s' "{$S,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"mcp__claude-in-chrome__navigate\",\"tool_input\":{}}" | awake hook
waitst "$DB" S 5 >/dev/null && pass "browser tool call woke the default browser in $(( $(ms) - t0 ))ms" || fail "browser not woken by hook"
open -g -b "$DEFID" "https://en.wikipedia.org/wiki/Laptop"; sleep 3
TITLE=$(tmo 8 osascript -e "tell application id \"$DEFID\" to get title of active tab of front window" 2>/dev/null)
[ -n "$TITLE" ] && pass "browser loaded a page with the lid closed: '$TITLE'" || fail "couldn't read tab title"
printf '%s' "{$S,\"hook_event_name\":\"Stop\"}" | awake hook
t=$(waitst "$DB" T 5) && pass "AI turn ended -> browser refrozen (${t}ms), helpers $(fh "$DB")/$(nh "$DB")" || fail "browser not refrozen after Stop"

log ""; log "## D. Waiting for you to open the lid (up to 25 min)…"
for i in $(seq 1 1500); do [ "$(lid)" = "No" ] && break; sleep 1; done
if [ "$(lid)" = "No" ]; then
    t0=$(ms); log "  lid opened"
    waitst "$BR" S 6 >/dev/null && pass "browser thawed $(( $(ms) - t0 ))ms after lid opened" || fail "browser still frozen after lid open"
    waitst "$TE" S 6 >/dev/null && pass "editor thawed" || fail "editor still frozen"
    sleep 2
    [ "$(stopped_apps)" = "0" ] && pass "no frozen apps anywhere" || fail "$(stopped_apps) app processes still frozen"
    B=$(bright); log "  brightness now $B (saved was $SAVED)"
    python3 -c "import sys;sys.exit(0 if abs(float('$B')-float('$SAVED'))<0.03 else 1)" 2>/dev/null && pass "brightness restored to $B" || fail "brightness $B, expected $SAVED"
    defaults read $D savedBrightness >/dev/null 2>&1 && fail "saved brightness not cleared" || pass "saved brightness cleared"
    tmo 5 osascript -e "tell application \"$B2\" to get name" >/dev/null 2>&1 && pass "editor responds" || fail "editor unresponsive"
    tmo 5 osascript -e "tell application \"$B1\" to count windows" >/dev/null 2>&1 && pass "browser responds" || fail "browser unresponsive"
else
    fail "lid not opened within 25 min"
fi
osascript -e "quit app \"$B2\"" >/dev/null 2>&1
{ echo "Maben Awake lid test — $PASS passed, $FAIL failed"; echo; cat "$LOG"; } > "$REPORT"
log "=== DONE: $PASS passed, $FAIL failed — $REPORT ==="
