#!/bin/bash
# Full real-lid test: freezing, AI browser use incl. cleanup, lid open recovery.
set -u
REPORT="$HOME/Desktop/Sleepwalker-fulltest-$(date +%H.%M).txt"; LOG=$(mktemp)
PASS=0; FAIL=0; D=com.maxbenschop.sleepwalker
L="$HOME/Library/Application Support/Sleepwalker/leases"
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
BR=$(printf '\x44\x69\x61'); BRID=company.thebrowser.dia; ED=$(printf 'Text%s' 'Edit')
tabs() { tmo 8 osascript -e "tell application \"$BR\" to get id of every tab of every window" 2>/dev/null | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort; }
ntabs(){ tabs | grep -c .; }
need() { echo "$(( $(date +%s) + 600 )) 0 $1" > "$L/need-fulltest-$1"; }
done_(){ rm -f "$L/need-fulltest-$1"; }
warm() { for i in $(seq 1 30); do tmo 5 osascript -e "tell application \"$BR\" to count windows" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
rm -f "$L"/need-* 2>/dev/null
# Quit an app cleanly even if it's frozen: wake it, quit, wait until gone.
quitapp() { echo "$(( $(date +%s) + 120 )) 0 $1" > "$L/need-quit-$1"; sleep 1
    tmo 10 osascript -e "quit app \"$1\"" >/dev/null 2>&1
    for i in $(seq 1 20); do pgrep -x "$1" >/dev/null || break; sleep 0.5; done
    pgrep -x "$1" >/dev/null && { pkill -x "$1"; sleep 1; }
    rm -f "$L/need-quit-$1"; }

log "=== Full lid test ==="
log "lid=$(lid)  brightness=$(bright)"
if [ "$(lid)" = "No" ]; then log "waiting for you to close the lid (up to 5 min)…"; for i in $(seq 1 300); do [ "$(lid)" = "Yes" ] && break; sleep 1; done; fi
[ "$(lid)" = "Yes" ] || { fail "lid never closed"; exit 1; }
log "lid closed — starting in 5s"; sleep 5

log ""; log "## A. Power & screen with lid closed"
[ "$(bright)" = "0.00" ] && pass "brightness 0" || fail "brightness $(bright)"
SAVED=$(defaults read $D savedBrightness 2>/dev/null); [ -n "$SAVED" ] && pass "previous brightness saved ($SAVED)" || fail "no saved brightness"
pmset -g | grep -q 'SleepDisabled.*1' && pass "closed-lid sleep disabled" || fail "SleepDisabled != 1"
pmset -g | grep -E '^ *sleep ' | grep -q Sleepwalker && pass "sleep prevented by Sleepwalker" || fail "sleep not prevented"
T3=$(ps -axo pid=,comm= | awk '/MacOS\/T3 Code \(Beta\)$/ {print $1; exit}'); [ -n "$T3" ] && [ "$(st "$T3")" != "T" ] && pass "T3 Code awake" || fail "T3 frozen/not found"

log ""; log "## B. Browser CLOSED, AI needs it -> opens, uses, quits it"
quitapp "$BR"
pgrep -x "$BR" >/dev/null && fail "browser still running at start" || pass "browser not running"
need "$BR"; sleep 1
open -g -b $BRID "https://en.wikipedia.org/wiki/MacBook_Air"; sleep 2
P=$(pgrep -x "$BR" | head -1); [ -n "$P" ] && pass "AI launched browser (pid $P)" || fail "browser didn't launch"
warm && pass "browser answers AppleScript" || fail "browser not answering"
sleep 2; T=$(tmo 8 osascript -e "tell application \"$BR\" to get title of active tab of front window" 2>/dev/null); [ -n "$T" ] && pass "page loaded with lid closed: '$T'" || fail "no page title"
[ "$(st "$P")" != "T" ] && pass "browser kept awake while AI needs it" || fail "browser frozen while needed"
done_ "$BR"
for i in $(seq 1 30); do pgrep -x "$BR" >/dev/null || break; sleep 0.5; done
pgrep -x "$BR" >/dev/null && fail "browser still running after AI done" || pass "browser QUIT after AI done (${i}×0.5s)"

log ""; log "## C. Browser OPEN with your tab, AI adds tabs -> only its tabs close, then browser freezes"
open -g -b $BRID "https://example.net"; sleep 3; warm; sleep 2   # "user's" browser with one tab
P=$(pgrep -x "$BR" | head -1); BEFORE=$(tabs); log "  user tabs: $(ntabs)"
sleep 14; t=$(waitst "$P" T 20) && pass "idle browser froze after launch grace (${t}ms), helpers $(fh $P)/$(nh $P)" || fail "browser not frozen"
need "$BR"; t=$(waitst "$P" S 5) && pass "AI request woke browser (${t}ms)" || fail "browser not woken"
sleep 2; BEFORE=$(tabs)
for u in https://example.com https://example.org; do tmo 8 osascript -e "tell application \"$BR\" to tell front window to make new tab with properties {URL:\"$u\"}" >/dev/null 2>&1; done
sleep 2; [ "$(ntabs)" -eq $(( $(echo "$BEFORE" | grep -c .) + 2 )) ] && pass "AI opened 2 tabs (now $(ntabs))" || fail "tab count $(ntabs)"
done_ "$BR"; sleep 6
AFTER=$(tabs); [ "$AFTER" = "$BEFORE" ] && pass "AI's tabs closed, user's tabs kept, no blank tab ($(ntabs))" || fail "tabs before=[$BEFORE] after=[$AFTER]"
pgrep -x "$BR" >/dev/null && pass "browser left running" || fail "browser was quit"
t=$(waitst "$P" T 10) && pass "browser frozen again (${t}ms)" || fail "browser not refrozen"

log ""; log "## D. Non-browser app the AI launches -> quits after"
quitapp "$ED"
need "$ED"; sleep 1; open -g -b com.apple.TextEdit; sleep 3
pgrep -x "$ED" >/dev/null && pass "AI launched $ED" || fail "$ED didn't launch"
done_ "$ED"; for i in $(seq 1 20); do pgrep -x "$ED" >/dev/null || break; sleep 0.5; done
pgrep -x "$ED" >/dev/null && fail "$ED still running" || pass "$ED quit after AI done"

log ""; log "## E. Waiting for you to OPEN the lid (up to 25 min)…"
for i in $(seq 1 1500); do [ "$(lid)" = "No" ] && break; sleep 1; done
if [ "$(lid)" = "No" ]; then
    t0=$(ms); log "  lid opened"
    t=$(waitst "$P" S 8) && pass "browser thawed $(( $(ms) - t0 ))ms after lid open" || fail "browser still frozen"
    sleep 3; [ "$(stopped_apps)" = "0" ] && pass "no frozen apps anywhere" || fail "$(stopped_apps) still frozen"
    B=$(bright); log "  brightness now $B (saved $SAVED)"
    python3 -c "import sys;sys.exit(0 if float('$B')>0.05 else 1)" && pass "screen back on (brightness $B)" || fail "screen still dark"
    defaults read $D savedBrightness >/dev/null 2>&1 && fail "saved brightness not cleared" || pass "saved brightness cleared"
    [ "$(ntabs)" -ge 1 ] && pass "browser responds, your tab still there ($(ntabs))" || fail "browser not responding"
else
    fail "lid not opened within 25 min"
fi
{ echo "Sleepwalker full lid test — $PASS passed, $FAIL failed"; echo; cat "$LOG"; } > "$REPORT"
log "=== DONE: $PASS passed, $FAIL failed — $REPORT ==="
