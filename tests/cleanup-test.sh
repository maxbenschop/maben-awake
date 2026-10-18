#!/bin/bash
# Tests AI cleanup with the lid open (via the test-only switch):
# close AI-opened tabs without leaving a blank tab, close AI-only windows,
# quit AI-launched apps (also when an old instance was quitting), leave pre-existing apps alone.
set -u
D=com.maxbenschop.sleepwalker
L="$HOME/Library/Application Support/Sleepwalker/leases"
PASS=0; FAIL=0
log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
pass() { PASS=$((PASS+1)); log "  ✅ $*"; }
fail() { FAIL=$((FAIL+1)); log "  ❌ $*"; }
tmo()  { perl -e 'alarm shift; exec @ARGV' "$@"; }
BR=$(printf '\x44\x69\x61'); ED=$(printf 'Text%s' 'Edit'); CA=$(printf 'Calcu%s' 'lator')
osa()  { tmo 10 osascript -e "tell application \"$BR\" to $1" 2>/dev/null; }
tabs() { osa "get id of every tab of every window" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort; }
urls() { osa "get URL of every tab of every window"; }
nwin() { osa "count windows"; }
need() { echo "$(( $(date +%s) + 600 )) 0 $1" > "$L/need-cleanuptest-$1"; }
done_() { rm -f "$L/need-cleanuptest-$1"; }
warm() { for i in $(seq 1 30); do osa "count windows" >/dev/null && return 0; sleep 1; done; return 1; }

defaults write $D testCleanupWithLidOpen -bool YES
trap 'defaults delete '$D' testCleanupWithLidOpen 2>/dev/null; rm -f "$L"/need-cleanuptest-*' EXIT
sleep 3

log "## 1. AI opens 2 tabs in your window (one ends up active) -> only those close, no blank tab"
pgrep -x "$BR" >/dev/null || { open -g -b company.thebrowser.dia; sleep 3; }
warm || fail "browser not answering"
[ "$(nwin)" = "0" ] && { osa "make new window" >/dev/null; sleep 1; }
BEFORE=$(tabs); BURLS=$(urls); log "  before: $(echo "$BEFORE" | grep -c .) tab(s): $BURLS"
need "$BR"; sleep 2
for u in https://example.com https://example.org; do osa "tell front window to make new tab with properties {URL:\"$u\"}" >/dev/null; done
sleep 2; log "  during: $(tabs | grep -c .) tabs, active: $(osa 'get URL of active tab of front window')"
[ "$(tabs | grep -c .)" -eq $(( $(echo "$BEFORE" | grep -c .) + 2 )) ] && pass "AI opened 2 tabs" || fail "expected 2 new tabs"
done_ "$BR"; sleep 5
AFTER=$(tabs); log "  after: $(echo "$AFTER" | grep -c .) tab(s): $(urls)"
[ "$AFTER" = "$BEFORE" ] && pass "only AI tabs closed, no blank tab left" || fail "before=[$BEFORE] after=[$AFTER]"

log ""; log "## 2. AI opens its own window -> whole window closes"
W0=$(nwin); need "$BR"; sleep 2
osa "make new window" >/dev/null; sleep 1; osa "tell front window to make new tab with properties {URL:\"https://example.com\"}" >/dev/null; sleep 2
[ "$(nwin)" -eq $(( W0 + 1 )) ] && pass "AI opened a window (now $(nwin))" || fail "window count $(nwin)"
done_ "$BR"; sleep 5
[ "$(nwin)" -eq "$W0" ] && pass "AI's window closed (back to $W0)" || fail "windows $(nwin), expected $W0"
[ "$(tabs)" = "$BEFORE" ] && pass "your tabs untouched" || fail "tabs changed"

log ""; log "## 3. App NOT running: AI launches it -> quits after"
osascript -e "quit app \"$ED\"" >/dev/null 2>&1; sleep 2; pgrep -x "$ED" >/dev/null && { pkill -x "$ED"; sleep 1; }
need "$ED"; sleep 1.5; open -g -b com.apple.TextEdit; sleep 3
pgrep -x "$ED" >/dev/null && pass "AI launched $ED" || fail "$ED didn't launch"
done_ "$ED"; for i in $(seq 1 20); do pgrep -x "$ED" >/dev/null || break; sleep 0.5; done
pgrep -x "$ED" >/dev/null && fail "$ED still running" || pass "$ED quit after AI done"

log ""; log "## 4. App was quitting when AI asked, AI relaunches it -> new instance quits after"
open -g -b com.apple.TextEdit; sleep 3; OLD=$(pgrep -x "$ED")
need "$ED"; sleep 1.5                                   # request while the old instance is still up
pkill -x "$ED"; sleep 1                                 # old instance goes away
open -g -b com.apple.TextEdit; sleep 3; NEW=$(pgrep -x "$ED")
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && pass "AI relaunched $ED (pid $OLD -> $NEW)" || fail "relaunch didn't happen"
done_ "$ED"; for i in $(seq 1 20); do pgrep -x "$ED" >/dev/null || break; sleep 0.5; done
pgrep -x "$ED" >/dev/null && fail "relaunched $ED still running" || pass "relaunched $ED quit after AI done"

log ""; log "## 5. App already running, not a browser -> left running"
pgrep -x "$CA" >/dev/null || { open -g -b com.apple.calculator; sleep 3; }
need "$CA"; sleep 2; done_ "$CA"; sleep 4
pgrep -x "$CA" >/dev/null && pass "$CA (already open) left running" || fail "$CA was quit"
osascript -e "quit app \"$CA\"" >/dev/null 2>&1

log ""; log "=== $PASS passed, $FAIL failed ==="
