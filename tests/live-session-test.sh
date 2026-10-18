#!/bin/bash
# End-to-end: a real headless Claude Code session runs one command that names an
# app. A watcher records every lease while it runs. Expected: the session's
# "claude-…" lease and a need-Calculator lease appear during the turn, and both
# are gone after the session ends. Costs a few cents of Haiku tokens.
L="$HOME/Library/Application Support/Sleepwalker/leases"
LOG=$(mktemp)
before=$(ls "$L" | sort)

( while :; do
    now=$(ls "$L" | sort | comm -13 <(echo "$before") - | tr '\n' ' ')
    echo "$(date +%T.%N | cut -c1-12) ${now:-(none)}" >> "$LOG"; sleep 0.2
  done ) & watcher=$!

start=$(date +%s)
out=$(cd /tmp && claude -p 'Run exactly this bash command and nothing else, then reply "done": echo "tell application \"Calculator\" is just text"' \
      --model claude-haiku-5-5 --allowedTools 'Bash(echo:*)' --output-format json 2>&1)
end=$(date +%s)
sleep 1.5; kill $watcher 2>/dev/null

echo "session finished in $((end - start))s: $(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("result:", d.get("result","?")[:40], "| turns:", d.get("num_turns"), "| cost: $%.4f" % d.get("total_cost_usd",0))' 2>/dev/null || echo "$out" | head -3)"
echo "--- leases seen while it ran (new ones only, deduplicated):"
awk '{ $1=""; print }' "$LOG" | uniq -c | sed 's/^ */   /'
after=$(ls "$L" | sort | comm -13 <(echo "$before") - | tr '\n' ' ')
echo "--- left behind after the session: ${after:-none}"
grep -q "need-Calculator" "$LOG" && echo "✅ app request created during the turn" || echo "❌ no app request seen"
grep -q "claude-" "$LOG" && echo "✅ session lease created" || echo "❌ no session lease"
[ -z "$after" ] && echo "✅ everything released when the session ended" || echo "❌ leftovers: $after"
