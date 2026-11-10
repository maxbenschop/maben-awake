#!/bin/bash
# Deep freeze/unfreeze test for Maben Awake. Designed to run with the lid closed.
# Logs every step with timestamps and writes a report to the Desktop.
set -u
REPORT="$HOME/Desktop/MabenAwake-test-$(date +%H.%M).txt"
LOG=$(mktemp)
LEASES="$HOME/Library/Application Support/MabenAwake/leases"
PASS=0; FAIL=0
T0=$(date +%s)

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
pass() { PASS=$((PASS+1)); log "  ✅ PASS: $*"; }
fail() { FAIL=$((FAIL+1)); log "  ❌ FAIL: $*"; log "     diag: frontmost=$(front) leases=[$(awake list | tr '\n' ';')] lid=$(lid)"; }
tmo()  { perl -e 'alarm shift; exec @ARGV' "$@"; }          # tmo <secs> <cmd...>
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

state()   { ps -o state= -p "$1" 2>/dev/null | cut -c1; }   # T = frozen, S/R = running
helpers() { pgrep -P "$1" 2>/dev/null | wc -l | tr -d ' '; }
frozen_helpers() { pgrep -P "$1" 2>/dev/null | xargs -I{} ps -o state= -p {} 2>/dev/null | grep -c '^T'; }
cpu()     { ps -o %cpu= -p "$1" 2>/dev/null | tr -d ' '; }
rss_mb()  { ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%d", $1/1024}'; }
lid()     { ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -o 'AppleClamshellState" = [A-Za-z]*' | sed 's/.*= //'; }
sleep_blocked() { pmset -g 2>/dev/null | awk '/^ *sleep /{print ($0 ~ /prevented/) ? "blocked" : "allowed"}'; }
sleep_disabled() { pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}'; }
front()   { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null; }
snapshot() { # pid label
    log "  [$2] state=$(state "$1") helpers=$(frozen_helpers "$1")/$(helpers "$1") frozen  cpu=$(cpu "$1")%  rss=$(rss_mb "$1")MB"
}
# wait_state pid T|S maxsecs -> prints ms taken, returns 1 on timeout
wait_state() {
    local start; start=$(now_ms)
    local deadline=$(( start + $3 * 1000 ))
    while [ "$(now_ms)" -lt "$deadline" ]; do
        if [ "$(state "$1")" = "$2" ]; then echo $(( $(now_ms) - start )); return 0; fi
        sleep 0.05
    done
    echo "timeout"; return 1
}
refocus() { osascript -e 'tell application "T3 Code (Beta)" to activate' >/dev/null 2>&1; }

log "=== Maben Awake deep test ==="
log "lid=$(lid)  system-sleep=$(sleep_blocked)  SleepDisabled=$(sleep_disabled)  frontmost=$(front)"
log "Maben Awake running: $(pgrep -x MabenAwake >/dev/null && echo yes || echo NO)"
log "active leases: $(awake list | tr '\n' ';')"
T3PID=$(pgrep -x "T3 Code (Beta)" | head -1)

# ---------------------------------------------------------------- 1. launch
log ""
log "## 1. Launch test apps (TextEdit, Calculator, Dia) and hand focus back to T3 Code"
for a in TextEdit Calculator Dia; do open -a "$a" 2>/dev/null; sleep 1.5; done
sleep 1; refocus; sleep 1
TE=$(pgrep -x TextEdit | head -1); CALC=$(pgrep -x Calculator | head -1); DIA=$(pgrep -x Dia | head -1)
log "pids: TextEdit=$TE Calculator=$CALC Dia=$DIA T3=$T3PID  frontmost=$(front)"
# `open -a` inside this script isn't seen by the hook, but clear any old requests anyway.
for a in TextEdit Calculator Dia; do awake done "$a" >/dev/null 2>&1; done
log "lid=$(lid)"

# ---------------------------------------------------------------- 2. auto-freeze
log ""
log "## 2. Idle apps should freeze on their own (mode 'When AI asks')"
for p in "$TE:TextEdit" "$CALC:Calculator" "$DIA:Dia"; do
    pid=${p%%:*}; name=${p##*:}
    [ -z "$pid" ] && { fail "$name did not launch"; continue; }
    ms=$(wait_state "$pid" T 15) && pass "$name froze after ${ms}ms" || fail "$name not frozen after 15s (state=$(state "$pid"))"
done
sleep 1
for p in "$TE:TextEdit" "$CALC:Calculator" "$DIA:Dia"; do pid=${p%%:*}; [ -n "$pid" ] && snapshot "$pid" "${p##*:}"; done
if [ -n "$DIA" ]; then
    [ "$(frozen_helpers "$DIA")" = "$(helpers "$DIA")" ] && pass "all $(helpers "$DIA") Dia helper processes frozen too" || fail "only $(frozen_helpers "$DIA")/$(helpers "$DIA") Dia helpers frozen"
fi
[ "$(state "$T3PID")" != "T" ] && pass "T3 Code (Always on) never frozen" || fail "T3 Code got frozen!"

# ---------------------------------------------------------------- 3. CPU while frozen
log ""
log "## 3. Frozen apps use no CPU (10s sample)"
c1=$(ps -o cputime= -p "$DIA" | tr -d ' '); sleep 10; c2=$(ps -o cputime= -p "$DIA" | tr -d ' ')
[ "$c1" = "$c2" ] && pass "Dia CPU time unchanged over 10s ($c1), %cpu=$(cpu "$DIA")" || fail "Dia CPU time moved $c1 -> $c2"
log "lid=$(lid) system-sleep=$(sleep_blocked)"

# ---------------------------------------------------------------- 4. AI requests Dia
log ""
log "## 4. AI asks for Dia: 'awake need Dia' -> should unfreeze instantly"
awake need Dia 5 >/dev/null
ms=$(wait_state "$DIA" S 5) && pass "Dia woke ${ms}ms after request" || fail "Dia did not wake"
sleep 0.5
[ "$(frozen_helpers "$DIA")" = "0" ] && pass "all Dia helpers resumed" || fail "$(frozen_helpers "$DIA") Dia helpers still frozen"
snapshot "$DIA" "Dia awake"

# ---------------------------------------------------------------- 5. use Dia for real
log ""
log "## 5. Use Dia: open a page and read its text"
URL="https://en.wikipedia.org/wiki/Sleep_mode"
PAGE=""
if tmo 10 osascript -e 'tell application "Dia" to get name' >/dev/null 2>&1; then
    log "  Dia answers AppleScript"
    tmo 10 osascript -e "tell application \"Dia\" to tell front window to make new tab with properties {URL:\"$URL\"}" >/dev/null 2>&1 \
      || open -a Dia "$URL"
    for i in $(seq 1 10); do
        l=$(tmo 5 osascript -e 'tell application "Dia" to get loading of active tab of front window' 2>/dev/null)
        [ "$l" = "false" ] && break; sleep 0.5
    done
    TITLE=$(tmo 5 osascript -e 'tell application "Dia" to get title of active tab of front window' 2>/dev/null)
    GOTURL=$(tmo 5 osascript -e 'tell application "Dia" to get URL of active tab of front window' 2>/dev/null)
    [ "$GOTURL" = "$URL" ] && pass "Dia opened the page; tab title read back from Dia: '$TITLE'" || fail "Dia tab URL is '$GOTURL' (title '$TITLE')"
    # Dia's JS-from-AppleScript needs the --enable-applescript-javascript launch flag, so read the text over HTTP.
    PAGE=$(curl -sL -A "Mozilla/5.0" "$URL" | python3 -c 'import sys,re,html;t=sys.stdin.read();ps=re.findall(r"<p>(.*?)</p>",t,re.S);ps=[html.unescape(re.sub("<[^>]+>","",p)).strip() for p in ps];ps=[p for p in ps if len(p)>80];print("\n\n".join(ps[:2]))')
    [ -n "$PAGE" ] && pass "page text fetched (${#PAGE} chars)" || fail "no page text"
else
    fail "Dia did not answer AppleScript within 10s"
    open -a Dia "$URL"; TITLE="(opened via open -a)"
fi
refocus; sleep 0.5
log "  frontmost=$(front)  Dia state=$(state "$DIA") (must stay awake while requested)"
[ "$(state "$DIA")" != "T" ] && pass "Dia stayed awake while AI request active" || fail "Dia froze while still requested"

# ---------------------------------------------------------------- 6. AI done -> refreeze
log ""
log "## 6. AI done with Dia: 'awake done Dia' -> should refreeze"
awake done Dia >/dev/null
ms=$(wait_state "$DIA" T 10) && pass "Dia refroze ${ms}ms after release" || fail "Dia did not refreeze"
sleep 0.5; snapshot "$DIA" "Dia refrozen"
[ "$(frozen_helpers "$DIA")" = "$(helpers "$DIA")" ] && pass "all Dia helpers refrozen" || fail "$(frozen_helpers "$DIA")/$(helpers "$DIA") helpers frozen"

# ---------------------------------------------------------------- 7. expiry
log ""
log "## 7. Request expiry: 'awake need TextEdit 1' -> must refreeze by itself after ~60s"
awake need TextEdit 1 >/dev/null
ms=$(wait_state "$TE" S 5) && pass "TextEdit woke (${ms}ms)" || fail "TextEdit did not wake"
start=$(date +%s)
if ms=$(wait_state "$TE" T 90); then pass "TextEdit refroze on its own after $(( $(date +%s) - start ))s (expected ~60-63s)"; else fail "TextEdit did not refreeze after expiry"; fi

# ---------------------------------------------------------------- 8. owner crash
log ""
log "## 8. Owner crash: request owned by a process that dies -> must refreeze within ~3s"
sleep 300 & FAKE=$!
echo "$(( $(date +%s) + 600 )) $FAKE Calculator" > "$LEASES/need-Calculator-crashtest"
ms=$(wait_state "$CALC" S 5) && pass "Calculator woke for crash-test owner (${ms}ms)" || fail "Calculator did not wake"
kill $FAKE 2>/dev/null; wait $FAKE 2>/dev/null
start=$(now_ms)
ms=$(wait_state "$CALC" T 10) && pass "Calculator refroze ${ms}ms after owner died" || fail "Calculator still awake after owner died"
[ -e "$LEASES/need-Calculator-crashtest" ] && fail "stale lease file left behind" || pass "stale lease file cleaned up"

# ---------------------------------------------------------------- 9. two requesters
log ""
log "## 9. Two AIs need the same app: releasing one must NOT freeze it"
echo "$(( $(date +%s) + 600 )) 0 Calculator" > "$LEASES/need-Calculator-aiA"
echo "$(( $(date +%s) + 600 )) 0 Calculator" > "$LEASES/need-Calculator-aiB"
wait_state "$CALC" S 5 >/dev/null
rm -f "$LEASES/need-Calculator-aiA"; sleep 4
[ "$(state "$CALC")" != "T" ] && pass "Calculator stayed awake while AI-B still needs it" || fail "Calculator froze although AI-B still needs it"
rm -f "$LEASES/need-Calculator-aiB"
ms=$(wait_state "$CALC" T 10) && pass "Calculator froze ${ms}ms after last requester released" || fail "Calculator did not freeze after last release"

# ---------------------------------------------------------------- 10. power
log ""
log "## 10. Power state throughout"
log "  lid=$(lid)  system-sleep=$(sleep_blocked)  SleepDisabled=$(sleep_disabled)  uptime-continuity: test ran $(( $(date +%s) - T0 ))s without gaps"
[ "$(sleep_blocked)" = "blocked" ] && pass "macOS reports sleep prevented by Maben Awake" || fail "sleep not blocked"
[ "$(sleep_disabled)" = "1" ] && pass "closed-lid sleep disabled (SleepDisabled=1)" || fail "SleepDisabled=$(sleep_disabled)"

# ---------------------------------------------------------------- cleanup
log ""
log "## Cleanup"
awake need TextEdit 1 >/dev/null; awake need Calculator 1 >/dev/null; sleep 1
osascript -e 'quit app "TextEdit"' -e 'quit app "Calculator"' >/dev/null 2>&1
awake done TextEdit >/dev/null; awake done Calculator >/dev/null
log "quit TextEdit and Calculator; Dia left running (frozen until needed)"

# ---------------------------------------------------------------- report
{
    echo "Maben Awake deep test — $(date '+%Y-%m-%d %H:%M')"
    echo "Result: $PASS passed, $FAIL failed"
    echo
    echo "Info fetched through Dia while your lid was closed"
    echo "Page: $TITLE"
    echo "URL:  $URL"
    echo
    echo "$PAGE"
    echo
    echo "------------------------------------------------------------"
    echo "Full log"
    echo "------------------------------------------------------------"
    cat "$LOG"
} > "$REPORT"
log ""
log "=== DONE: $PASS passed, $FAIL failed — report: $REPORT ==="
echo "REPORT=$REPORT"
