#!/usr/bin/env python3
"""Feeds the hook what each supported agent sends (as in that agent's hook docs),
with the arguments Settings → Agents installs, and checks the leases it leaves.
Usage: agent-hooks-test.py <maben-awake-hook>   (e.g. .build/debug/MabenAwakeHook)"""
import json, os, subprocess, sys, tempfile, time

HOOK = sys.argv[1]
SID = "0198c2f4-7a11-7c3e-9d55-aabbccdd0042"   # leases use the last 8 characters
OPEN = "osascript -e 'tell application \"Dia\" to get URL' && open -a Spotify"

def call(agent, event, payload, folder, flags=True, frozen=None):
    args = [HOOK] + (["--agent", agent, "--event", event] if flags else [])
    env = {**os.environ, "MABEN_AWAKE_LEASES": folder, "MABEN_AWAKE_HOOK_LOG": folder + "/../agent-hook.log"}
    env.pop("DEVIN_PROJECT_DIR", None)
    env.pop("MABEN_AWAKE_FROZEN", None)
    if frozen is not None: env["MABEN_AWAKE_FROZEN"] = frozen
    env["MABEN_AWAKE_BROWSER"] = "company.thebrowser.dia"   # the default browser, whatever this Mac uses
    r = subprocess.run(args, input=json.dumps(payload).encode(), env=env, capture_output=True)
    assert r.returncode == 0, f"exit {r.returncode}: {r.stderr.decode()}"
    return r.stdout.decode()

def leases(folder):
    now = time.time(); found = {}
    for f in sorted(os.listdir(folder)):
        if f.startswith("."): continue   # the hook's own state (last hint), not a lease
        parts = open(os.path.join(folder, f)).read().split()
        found[f.rsplit("-", 1)[0] if f.startswith("need-") else f] = round((int(parts[0]) - now) / 60)
    return found

# agent: (prompt, tool start, tool end, stop, session end), each (event, payload)
claude_like = lambda prompt, shell, stop="Stop", **extra: (
    (prompt, {"session_id": SID, "hook_event_name": prompt, "prompt": "fix it", **extra}),
    ("PreToolUse", {"session_id": SID, "hook_event_name": "PreToolUse", "tool_name": shell, "tool_input": {"command": OPEN}, **extra}),
    ("PostToolUse", {"session_id": SID, "hook_event_name": "PostToolUse", "tool_name": shell, "tool_input": {"command": OPEN}, **extra}),
    (stop, {"session_id": SID, "hook_event_name": stop, **extra}),
    ("SessionEnd", {"session_id": SID, "hook_event_name": "SessionEnd", **extra}))

AGENTS = {
    "codex": claude_like("UserPromptSubmit", "shell"),
    "cursor": (
        ("beforeSubmitPrompt", {"conversation_id": SID, "generation_id": "g1", "hook_event_name": "beforeSubmitPrompt", "cursor_version": "2.4.0", "prompt": "fix it"}),
        ("preToolUse", {"conversation_id": SID, "hook_event_name": "preToolUse", "cursor_version": "2.4.0", "tool_name": "Shell",
                        "tool_input": {"command": OPEN, "working_directory": "/project"}, "tool_use_id": "abc123"}),
        ("postToolUse", {"conversation_id": SID, "hook_event_name": "postToolUse", "cursor_version": "2.4.0", "tool_name": "Shell",
                         "tool_input": {"command": OPEN}, "tool_output": "{}", "duration": 5}),
        ("stop", {"conversation_id": SID, "hook_event_name": "stop", "cursor_version": "2.4.0", "status": "completed", "loop_count": 0}),
        ("sessionEnd", {"conversation_id": SID, "session_id": SID, "hook_event_name": "sessionEnd", "reason": "user_close"})),
    "gemini": (
        ("BeforeAgent", {"session_id": SID, "hook_event_name": "BeforeAgent", "timestamp": "2026-11-10T10:00:00Z", "prompt": "fix it"}),
        ("BeforeTool", {"session_id": SID, "hook_event_name": "BeforeTool", "tool_name": "run_shell_command", "tool_input": {"command": OPEN}}),
        ("AfterTool", {"session_id": SID, "hook_event_name": "AfterTool", "tool_name": "run_shell_command", "tool_input": {"command": OPEN}, "tool_response": {}}),
        ("AfterAgent", {"session_id": SID, "hook_event_name": "AfterAgent", "prompt": "fix it", "prompt_response": "done", "stop_hook_active": False}),
        ("SessionEnd", {"session_id": SID, "hook_event_name": "SessionEnd", "reason": "exit"})),
    # Copilot's older payload: no event name, camelCase fields, arguments as a JSON string.
    "copilot": (
        ("UserPromptSubmit", {"sessionId": SID, "timestamp": 1704614400000, "cwd": "/tmp", "prompt": "fix it"}),
        ("PreToolUse", {"sessionId": SID, "timestamp": 1704614400000, "cwd": "/tmp", "toolName": "bash", "toolArgs": json.dumps({"command": OPEN})}),
        ("PostToolUse", {"sessionId": SID, "timestamp": 1704614400000, "toolName": "bash", "toolArgs": json.dumps({"command": OPEN}), "toolResult": {}}),
        ("Stop", {"sessionId": SID, "timestamp": 1704614400000, "stopReason": "end_turn"}),
        ("SessionEnd", {"sessionId": SID, "timestamp": 1704614400000, "reason": "exit"})),
    "copilot (Claude-style payload)": claude_like("UserPromptSubmit", "Bash"),
    "opencode": (   # what the plugin in Integration.swift sends
        ("UserPromptSubmit", {"session_id": SID, "tool_name": "", "tool_input": {}}),
        ("PreToolUse", {"session_id": SID, "tool_name": "bash", "tool_input": {"command": OPEN}}),
        ("PostToolUse", {"session_id": SID, "tool_name": "bash", "tool_input": {}}),
        ("Stop", {"session_id": SID, "tool_name": "", "tool_input": {}}),
        ("SessionEnd", {"session_id": SID, "tool_name": "", "tool_input": {}})),
    "qwen": claude_like("UserPromptSubmit", "run_shell_command", permission_mode="default"),
    "droid": claude_like("UserPromptSubmit", "Execute", permission_mode="default"),
    "devin": claude_like("UserPromptSubmit", "exec", prompt_id="b71e9d40"),
    "auggie": (
        ("PromptSubmit", {"conversation_id": SID, "hook_event_name": "PromptSubmit", "user_prompt": "fix it"}),
        ("PreToolUse", {"conversation_id": SID, "hook_event_name": "PreToolUse", "tool_name": "bash", "tool_input": {"command": OPEN}, "is_mcp_tool": False}),
        ("PostToolUse", {"conversation_id": SID, "hook_event_name": "PostToolUse", "tool_name": "bash", "tool_input": {"command": OPEN}}),
        ("Stop", {"conversation_id": SID, "hook_event_name": "Stop", "agent_stop_cause": "end_turn"}),
        ("SessionEnd", {"conversation_id": SID, "hook_event_name": "SessionEnd"})),
    "kiro": claude_like("UserPromptSubmit", "execute_bash"),
}

failed = 0
def check(title, ok, detail=""):
    global failed
    print(("✅ " if ok else "❌ ") + title + ("" if ok else f"   {detail}"))
    failed += 0 if ok else 1

for label, (prompt, start, end, stop, close) in AGENTS.items():
    agent = label.split()[0]; lease = f"{agent}-{SID[-8:]}"
    with tempfile.TemporaryDirectory() as d:
        # Cursor is connected without a tool-start event, so its hold is 2 h from the prompt on.
        idle = 120 if agent == "cursor" else 15
        out = call(agent, *prompt, d); got = leases(d)
        check(f"{label}: prompt holds {idle} min", got == {lease: idle} and out == "", f"{got} {out!r}")
        out = call(agent, *start, d); got = leases(d)
        check(f"{label}: tool start holds 2 h and wakes Dia and Spotify, and prints nothing",
              got == {lease: 120, "need-Dia": 10, "need-Spotify": 10} and out == "", f"{got} {out!r}")
        call(agent, *end, d); got = leases(d)
        check(f"{label}: tool end drops to {idle} min", got.get(lease) == idle, f"{got}")
        call(agent, *stop, d); got = leases(d)
        check(f"{label}: end of turn releases everything", got == {}, f"{got}")
        call(agent, *start, d); call(agent, *close, d); got = leases(d)
        check(f"{label}: session end releases everything", got == {}, f"{got}")

with tempfile.TemporaryDirectory() as d:
    # Droid reports a cancelled turn as a notification, not as Stop.
    call("droid", "UserPromptSubmit", {"session_id": SID, "hook_event_name": "UserPromptSubmit"}, d)
    call("droid", "Notification", {"session_id": SID, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, d)
    check("droid: a permission prompt keeps the hold", len(leases(d)) == 1, f"{leases(d)}")
    call("droid", "Notification", {"session_id": SID, "hook_event_name": "Notification", "notification_type": "idle_prompt"}, d)
    check("droid: a cancelled turn releases the hold", leases(d) == {}, f"{leases(d)}")
with tempfile.TemporaryDirectory() as d:
    call("gemini", "BeforeTool", {"session_id": SID, "tool_name": "run_shell_command", "tool_input": {"command": "npm run dev", "is_background": True}}, d)
    check("gemini: background command gets its own hold", leases(d).get(f"gemini-{SID[-8:]}-bg") == 30, f"{leases(d)}")
with tempfile.TemporaryDirectory() as d:
    call("cursor", "postToolUse", {"conversation_id": SID, "tool_name": "Shell", "tool_input": {"command": OPEN}}, d)
    check("cursor: a finished command wakes the apps it named, for the next try", {"need-Dia", "need-Spotify"} <= set(leases(d)), f"{leases(d)}")
with tempfile.TemporaryDirectory() as d:
    # Cursor also runs the hooks in Claude Code's settings (no --agent); the lease is still Cursor's, and nothing is printed.
    out = call("", "", {"conversation_id": SID, "hook_event_name": "PreToolUse", "cursor_version": "2.4.0", "tool_name": "Shell", "tool_input": {"command": "ls"}}, d, flags=False)
    check("cursor through Claude Code's settings: one Cursor lease, no output", leases(d) == {f"cursor-{SID[-8:]}": 120} and out == "", f"{leases(d)} {out!r}")
with tempfile.TemporaryDirectory() as d:
    a, b = "ses_e39d1f0a2bffe001", "ses_e39d1f0a2bffe002"   # started in the same second
    call("opencode", "UserPromptSubmit", {"session_id": a}, d); call("opencode", "UserPromptSubmit", {"session_id": b}, d)
    call("opencode", "Stop", {"session_id": a}, d)
    check("two sessions started together keep separate holds", len(leases(d)) == 1, f"{leases(d)}")

# --- 1.6: the agent no longer has to think about Maben Awake ---------------
LEASE = f"claude-{SID[:8]}"
def claude(event, folder, frozen=None, **payload):
    return call("", "", {"session_id": SID, "hook_event_name": event, **payload}, folder, flags=False, frozen=frozen)
def bash(command, **extra): return {"tool_name": "Bash", "tool_input": {"command": command, **extra}}
def needs(folder):   # the app each need- lease asks for (third field of the file)
    return {" ".join(open(os.path.join(folder, f)).read().split()[2:]) for f in os.listdir(folder) if f.startswith("need-")}

# Background work: Claude Code lists what is still running when a turn ends.
with tempfile.TemporaryDirectory() as d:
    claude("PreToolUse", d, **bash("npm run build:watch", run_in_background=True))
    check("background command: 30 min hold while the turn runs", leases(d).get(LEASE + "-bg") == 30, f"{leases(d)}")
    claude("Stop", d, background_tasks=[{"id": "b1", "type": "shell", "status": "running", "command": "npm run build:watch"}])
    check("end of turn with background work running: held up to 8 h", leases(d) == {LEASE + "-bg": 480}, f"{leases(d)}")
    claude("Stop", d, background_tasks=[{"id": "b1", "type": "shell", "status": "completed"}])
    check("the turn after it finished releases it", leases(d) == {}, f"{leases(d)}")
    claude("PreToolUse", d, **bash("sleep 600", run_in_background=True)); claude("Stop", d, background_tasks=[])
    check("an empty list releases it straight away", leases(d) == {}, f"{leases(d)}")
    claude("PreToolUse", d, **bash("sleep 600", run_in_background=True)); claude("Stop", d)
    check("without the list (older Claude Code) the 30 min hold stands", leases(d) == {LEASE + "-bg": 30}, f"{leases(d)}")
with tempfile.TemporaryDirectory() as d:
    claude("Stop", d, background_tasks=[{"id": "a1", "type": "agent", "status": "running"}, {"id": "b2", "type": "shell", "status": "killed"}])
    check("any kind of task still running counts", leases(d) == {LEASE + "-bg": 480}, f"{leases(d)}")
for command, detached in [("npm run dev > /tmp/dev.log 2>&1 &", True), ("nohup ./server &", True), ("python3 -m http.server 8000 & disown", True),
                          ("npm test 2>&1 | tail -5", False), ("./a & ./b & wait", False), ("make && make test", False),
                          ("./server & sleep 2; curl -s localhost:8000; kill %1", False),
                          ("(swift test > /tmp/t.log 2>&1; echo DONE >> /tmp/t.log) &", True),
                          ("npm run dev > /tmp/dev.log 2>&1 & sleep 3; curl -s localhost:3000", True),
                          ("curl -s 'https://api.example.com/v1?a=1&b=2' | head", False),
                          ("osascript -e 'set out to out & (URL of t) & \" | \"'", False),
                          ("git commit -m 'Run nohup in the docs & more'", False),
                          ("python3 - <<'EOF'\nprint('nohup' + ' & ')\nEOF", False)]:
    with tempfile.TemporaryDirectory() as d:
        claude("PreToolUse", d, **bash(command))
        got = leases(d).get(LEASE + "-detached")
        check(f"detached: {command!r} " + ("holds 1 h" if detached else "holds nothing extra"), got == (60 if detached else None), f"{leases(d)}")

# Waking: commands are compared with the apps that are frozen right now. What
# 1.5 recognised wakes an app either way; what 1.6 added only wakes a frozen app.
FROZEN_APPS = "company.thebrowser.dia\tDia\ncom.apple.dt.Xcode\tXcode\nnet.maben.chain\tChain\ncom.apple.Notes\tNotes\n"
with tempfile.TemporaryDirectory() as scratch:
    live = os.path.join(scratch, "frozen"); open(live, "w").write(f"pid {os.getpid()}\n" + FROZEN_APPS)
    stale = os.path.join(scratch, "stale"); open(stale, "w").write("pid 99999999\n" + FROZEN_APPS)
    for title, command, want, frozen in [
        ("System Events: tell process", "osascript -e 'tell application \"System Events\" to tell process \"Xcode\" to get name of windows'", {"com.apple.dt.Xcode"}, live),
        ("JavaScript for Automation", "osascript -l JavaScript -e 'Application(\"Notes\").notes.length'", {"com.apple.Notes"}, live),
        ("quit app", "osascript -e 'quit app \"Dia\"'", {"company.thebrowser.dia"}, live),
        ("pkill a frozen app", "pkill -x Chain; sleep 1; pgrep -x Chain", {"net.maben.chain"}, live),
        ("bundle ID after open -b", "open -b com.apple.Notes", {"com.apple.Notes"}, live),
        ("bundle ID elsewhere is not a request", "defaults read com.apple.Notes", set(), live),
        ("its .app in Applications", "open -g /Applications/Chain.app", {"net.maben.chain"}, live),
        ("its .app by name", "open Chain.app", {"net.maben.chain"}, live),
        ("relaunching a build doesn't wake the installed copy", "pkill -f \"Debug/Chain.app/Contents/MacOS/Chain\"; open -n build/Debug/Chain.app", set(), live),
        ("pkill -f with the app's path", "pkill -f \"Chain.app/Contents/MacOS/Chain\"", {"net.maben.chain"}, live),
        ("pkill -f with a pattern names no app", "pkill -f 'next start -p 3100'; pkill -f \"/Chain$\"", set(), live),
        ("pgrep only looks", "pgrep -lx Chain; open https://example.com", {"browser"}, live),
        ("a defaults domain next to a kill is not a request", "pkill -f fake-relay.mjs; defaults delete net.maben.chain", set(), live),
        ("lsappinfo only asks the system", "lsappinfo info -only pid net.maben.chain", set(), live),
        ("osascript with a bundle ID", "osascript -e 'tell application id \"net.maben.chain\" to activate'", {"net.maben.chain"}, live),
        ("in quotes in an osascript call", "osascript ./tools/windows.scpt \"Dia\"", {"company.thebrowser.dia"}, live),
        ("an AppleScript heredoc fed to osascript", "osascript <<'EOF'\ntell application \"System Events\" to tell process \"Xcode\" to get windows\nEOF", {"com.apple.dt.Xcode"}, live),
        ("app names in code being written are not requests", "cat > tool.swift <<'EOF'\nlet s = \"osascript -e 'quit app \\\"Notes\\\"'\"\nEOF\nswiftc tool.swift", set(), live),
        ("in quotes in code being written is not a request", "python3 - <<'EOF'\ns = open('a.swift').read().replace('\"Dia\"', '\"Arc\"')\nEOF", set(), live),
        ("its .app in a file path is not a request", "plutil -p build/Chain.app/Contents/Info.plist", set(), live),
        ("a word in a path is not a request", "cd ~/Projects/chain && grep -rn Chain Sources/ | head", set(), live),
        ("lowercase name is not a request", "git commit -m 'fix notes view'", set(), live),
        ("a list left by an app that is gone is ignored", "defaults read com.apple.Notes", set(), stale),
        ("tell application, as in 1.5, also when not frozen", "osascript -e 'tell application \"Dia\" to get URL'", {"Dia"}, None),
        ("open -a, as in 1.5, also when not frozen", "open -a Safari https://example.com", {"Safari"}, None),
        ("open a link: the default browser when it is frozen", "open https://localhost:3000/settings", {"browser"}, live),
        ("open a page: the default browser when it is frozen", "open -g dist/index.html", {"browser"}, live),
        ("open a link: nothing when the browser isn't frozen", "open https://localhost:3000/settings", set(), None),
        ("tell application id of an app that isn't frozen: nothing", "osascript -e 'tell application id \"com.apple.TextEdit\" to quit'", set(), live),
        ("open -b of an app that isn't frozen: nothing", "open -b com.apple.TextEdit notes.txt", set(), live),
        ("relaunching a build that isn't frozen: nothing", "pkill -x Chain; sleep 1; open build/Debug/Chain.app", set(), None),
        ("killall of an app that isn't frozen: nothing", "killall \"Visual Studio Code\"", set(), live),
        ("tell process of an app that isn't frozen: nothing", "osascript -e 'tell application \"System Events\" to tell process \"Freeform\" to get windows'", set(), live),
        ("app \"X\" outside a script is ignored", "echo 'rename app \"Foo\"' >> notes.md", set(), None),
    ]:
        with tempfile.TemporaryDirectory() as d:
            claude("PreToolUse", d, frozen=frozen, **bash(command))
            check(f"wake: {title}", needs(d) == want, f"{needs(d)} for {command!r}")
    with tempfile.TemporaryDirectory() as d:
        claude("PreToolUse", d, frozen=live, tool_name="mcp__computer-use__open_application", tool_input={"app": "Freeform"})
        claude("PreToolUse", d, frozen=live, tool_name="mcp__computer-use__open_application", tool_input={"app": "Dia"})
        claude("PreToolUse", d, frozen=live, tool_name="mcp__notes__search", tool_input={"query": "groceries", "target": "com.apple.Notes"})
        claude("PreToolUse", d, frozen=live, tool_name="mcp__claude-in-chrome__computer", tool_input={"action": "Notes"})
        claude("PreToolUse", d, frozen=live, tool_name="Read", tool_input={"file_path": "Notes"})
        check("wake: an MCP tool's frozen app argument or bundle ID (not an app that isn't frozen)", needs(d) == {"company.thebrowser.dia", "com.apple.Notes", "browser"}, f"{needs(d)}")

    # A failed command while apps are frozen: one line for Claude Code.
    def hint(out):
        if not out.strip(): return None
        reply = json.loads(out)["hookSpecificOutput"]
        return reply["hookEventName"] + ": " + reply["additionalContext"]
    with tempfile.TemporaryDirectory() as d:
        out = claude("PostToolUseFailure", d, frozen=live, **bash("./tools/front-title.sh"),
                     error="Exit code 1\n12:40: execution error: Notes got an error: AppleEvent timed out. (-1712)")
        check("failure naming a frozen app: woken, and told to retry", hint(out) == "PostToolUseFailure: Maben Awake: Notes was frozen and is awake now (10 min). Retry the command."
              and needs(d) == {"com.apple.Notes"}, f"{out!r} {needs(d)}")
        out = claude("PostToolUseFailure", d, frozen=live, **bash("./tools/check-ui.sh"), error="Exit code 1\nERROR: no response (timeout)")
        check("timeout naming no app: told which apps are frozen", hint(out) == "PostToolUseFailure: Maben Awake: these apps are frozen: Dia, Xcode, Chain, Notes. If the command needed one, run `awake need \"<App>\"` and retry.", f"{out!r}")
        out = claude("PostToolUseFailure", d, frozen=live, **bash("./tools/check-ui.sh"), error="Exit code 1\nERROR: no response (timeout)")
        check("the same hint again within 10 min: nothing", out == "", f"{out!r}")
        out = claude("PostToolUseFailure", d, frozen=live, **bash("make"), error="Exit code 2\nmake: *** [all] Error 2 (see Release Notes)")
        check("an ordinary failure: nothing", out == "", f"{out!r}")
        out = claude("PostToolUse", d, frozen=live, **bash("./tools/try-ui.sh"), tool_response={"stdout": "error: Xcode got an error: AppleEvent timed out. (-1712)", "stderr": ""})
        check("a script that swallowed the timeout: still caught", hint(out) == "PostToolUse: Maben Awake: Xcode was frozen and is awake now (10 min). Retry the command.", f"{out!r}")
        out = claude("PostToolUse", d, frozen=live, **bash("npm test"), tool_response={"stdout": "3 passed, request timed out once", "stderr": ""})
        check("a successful command: nothing", out == "", f"{out!r}")
        claude("SessionEnd", d)
        check("session end forgets the last hint", not [f for f in os.listdir(d) if f.startswith(".hint")], f"{os.listdir(d)}")
    with tempfile.TemporaryDirectory() as d:
        out = claude("PostToolUseFailure", d, frozen=live, **bash("./tools/front-title.sh"), error="Exit code 1\nerror: Chain did not answer (timed out after 15 s)")
        check("a plain timeout naming a frozen app: woken, retry if it was needed", hint(out) == "PostToolUseFailure: Maben Awake: Chain was frozen and is awake now (10 min). If the command needed it, retry it."
              and needs(d) == {"net.maben.chain"}, f"{out!r} {needs(d)}")
    # Words that happen to be a frozen app's name must not wake it or ask for a retry.
    common = os.path.join(scratch, "common"); open(common, "w").write(f"pid {os.getpid()}\n" + "com.apple.iWork.Pages\tPages\ncom.apple.Preview\tPreview\ncom.apple.Home\tHome\n")
    for title, command, error in [
        ("a test timeout in pages/", "npm test", "Exit code 1\nError: Timeout of 5000ms exceeded in pages/index.test.ts"),
        ("a missing file under home/", "open dist/report.pdf", "Exit code 1\nThe file /Users/me/home/dist/report.pdf does not exist."),
        ("a timed-out URL ending in preview", "curl -s --max-time 5 https://example.com/preview", "Exit code 28\ncurl: (28) Operation timed out"),
    ]:
        with tempfile.TemporaryDirectory() as d:
            out = claude("PostToolUseFailure", d, frozen=common, **bash(command), error=error)
            check(f"no false wake: {title}", needs(d) == set() and "was frozen" not in (hint(out) or ""), f"{out!r} {needs(d)}")
    with tempfile.TemporaryDirectory() as d:
        out = claude("PostToolUseFailure", d, **bash("osascript -e 'tell application \"Dia\" to get URL'"), error="AppleEvent timed out. (-1712)")
        check("nothing frozen (lid open): nothing", out == "", f"{out!r}")
    for agent, event in [("codex", "PostToolUse"), ("gemini", "AfterTool"), ("cursor", "postToolUse"), ("copilot", "PostToolUse")]:
        with tempfile.TemporaryDirectory() as d:
            out = call(agent, event, {"session_id": SID, "hook_event_name": event, "tool_name": "shell", "tool_input": {"command": "./x.sh"},
                                      "error": "Dia got an error: AppleEvent timed out. (-1712)"}, d, frozen=live)
            check(f"{agent}: never prints a hint", out == "", f"{out!r}")

print(f"\n{failed} failed" if failed else "\nALL PASSED")
sys.exit(1 if failed else 0)
