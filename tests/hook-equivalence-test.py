#!/usr/bin/env python3
"""Runs every hook scenario through the old shell hook (`awake hook`) and the
compiled one (maben-awake-hook) in scratch lease folders and compares the
leases they leave behind. Usage: hook-equivalence-test.py <awake> <maben-awake-hook>"""
import json, os, subprocess, sys, tempfile, time

SHELL, BINARY = sys.argv[1], sys.argv[2]
S = {"session_id": "eqtest01-abcd", "transcript_path": "/tmp/x.jsonl", "cwd": "/tmp/project"}

def ev(name, **kw): return {**S, "hook_event_name": name, **kw}
def bash(cmd, **kw): return ev("PreToolUse", tool_name="Bash", tool_input={"command": cmd, **kw})

# (title, events, expect_same)  expect_same=False marks intended improvements
SCENARIOS = [
    ("prompt submitted", [ev("UserPromptSubmit", prompt="fix it")], True),
    ("tool starts (2 h hold)", [ev("PreToolUse", tool_name="Read", tool_input={"file_path": "/x"})], True),
    ("tool finished (15 min hold)", [ev("PostToolUse", tool_name="Read", tool_input={}, tool_response="ok")], True),
    ("turn ends releases everything", [bash("osascript -e 'tell application \"Dia\" to get URL'"), ev("Stop")], True),
    ("scheduled wake-up 20 min", [ev("PreToolUse", tool_name="ScheduleWakeup", tool_input={"delaySeconds": 1200, "prompt": "x"})], True),
    ("scheduled wake-up then stop", [ev("PreToolUse", tool_name="ScheduleWakeup", tool_input={"delaySeconds": 600}),
                                     ev("PreToolUse", tool_name="ScheduleWakeup", tool_input={"stop": True})], True),
    ("cron create + delete", [ev("PreToolUse", tool_name="CronCreate", tool_input={}),
                              ev("PreToolUse", tool_name="CronDelete", tool_input={})], True),
    ("monitor", [ev("PreToolUse", tool_name="Monitor", tool_input={"command": "tail -f x"})], True),
    ("background command", [bash("npm run dev", run_in_background=True)], True),
    ("osascript + open -a", [bash("osascript -e 'tell application \"Dia\" to get URL' && open -a Spotify")], True),
    ("open -a with spaces", [bash('open -a "Visual Studio Code" .')], True),
    ("browser extension tool", [ev("PreToolUse", tool_name="mcp__claude-in-chrome__navigate", tool_input={"url": "x"})], True),
    ("docker command", [bash("docker ps -a")], True),
    ("System Events ignored", [bash("osascript -e 'tell application \"System Events\" to keystroke \"a\"'")], True),
    ("agent-desktop --app", [bash("agent-desktop snapshot --app Dia -i && agent-desktop find --app=Slack")], True),
    ("agent-desktop quoted --app", [bash("agent-desktop snapshot --app \"Visual Studio Code\" -i; agent-desktop snapshot --app 'Google Chrome'")], True),
    ("agent-desktop launch / close-app", [bash("agent-desktop launch --activate Spotify && agent-desktop close-app \"Microsoft Word\"")], True),
    ("agent-desktop ref action names no app", [bash("agent-desktop click @s8f3k2p9:e8")], True),
    ("--app without agent-desktop ignored", [bash("mytool --app Dia")], True),
    ("session end clears all", [bash("open -a Spotify"), ev("PreToolUse", tool_name="Monitor", tool_input={}), ev("SessionEnd")], True),
    ("garbage input", ["not json at all"], True),
    # Intended improvements:
    ("escaped quotes (double-quoted osascript)", [bash('osascript -e "tell application \\"Dia\\" to get URL"')], False),
    ("open -g -a (flags before -a)", [bash("open -g -a TextEdit")], False),
    ("'docker' only in folder path", [{**bash("ls"), "cwd": "/Users/me/docker-stuff"}], False),
    # 1.6 (compiled hook only; the shell hook is the fallback):
    ("background work still running at Stop", [bash("npm run dev", run_in_background=True),
                                               ev("Stop", background_tasks=[{"id": "b1", "type": "shell", "status": "running"}])], False),
    ("System Events tell process", [bash("osascript -e 'tell application \"System Events\" to tell process \"Xcode\" to get windows'")], False),
    ("open a link", [bash("open https://localhost:3000")], False),
    ("detached server", [bash("npm run dev > /tmp/dev.log 2>&1 &")], False),
]

def run(hook, events, folder):
    env = {**os.environ, "MABEN_AWAKE_LEASES": folder, "MABEN_AWAKE_HOOK_LOG": folder + "/../hook.log"}
    total = 0.0
    for e in events:
        payload = e if isinstance(e, str) else json.dumps(e)
        args = [hook, "hook"] if hook == SHELL else [hook]
        t = time.perf_counter()
        r = subprocess.run(args, input=payload.encode(), env=env, capture_output=True)
        total += time.perf_counter() - t
        assert r.returncode == 0, f"{hook} exited {r.returncode}: {r.stderr.decode()}"
    now = time.time(); leases = {}
    for f in sorted(os.listdir(folder)):
        parts = open(os.path.join(folder, f)).read().split()
        leases[f] = (round((int(parts[0]) - now) / 60), parts[1], " ".join(parts[2:]))
    return leases, total / len(events)

passed = failed = 0; shell_t = []; bin_t = []
for title, events, expect_same in SCENARIOS:
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        old, t1 = run(SHELL, events, a); new, t2 = run(BINARY, events, b)
    shell_t.append(t1); bin_t.append(t2)
    same = old == new
    fmt = lambda d: ", ".join(f"{k} ({v[0]}m{', app ' + v[2] if v[2] else ''})" for k, v in d.items()) or "none"
    if same == expect_same:
        passed += 1
        print(f"✅ {title:<34} {'identical' if same else 'improved'}: {fmt(new)}" + ("" if same else f"   (old: {fmt(old)})"))
    else:
        failed += 1
        print(f"❌ {title:<34} old: {fmt(old)}\n   {'':<34} new: {fmt(new)}")
print(f"\n{passed} passed, {failed} failed")
print(f"avg per hook call: shell {1000*sum(shell_t)/len(shell_t):.1f} ms, compiled {1000*sum(bin_t)/len(bin_t):.1f} ms")
sys.exit(1 if failed else 0)
