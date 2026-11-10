#!/usr/bin/env python3
"""Feeds the hook what each supported agent sends (as in that agent's hook docs),
with the arguments Settings → Agents installs, and checks the leases it leaves.
Usage: agent-hooks-test.py <maben-awake-hook>   (e.g. .build/debug/MabenAwakeHook)"""
import json, os, subprocess, sys, tempfile, time

HOOK = sys.argv[1]
SID = "0198c2f4-7a11-7c3e-9d55-aabbccdd0042"   # leases use the last 8 characters
OPEN = "osascript -e 'tell application \"Dia\" to get URL' && open -a Spotify"

def call(agent, event, payload, folder, flags=True):
    args = [HOOK] + (["--agent", agent, "--event", event] if flags else [])
    env = {**os.environ, "MABEN_AWAKE_LEASES": folder, "MABEN_AWAKE_HOOK_LOG": folder + "/../agent-hook.log"}
    env.pop("DEVIN_PROJECT_DIR", None)
    r = subprocess.run(args, input=json.dumps(payload).encode(), env=env, capture_output=True)
    assert r.returncode == 0, f"exit {r.returncode}: {r.stderr.decode()}"
    return r.stdout.decode()

def leases(folder):
    now = time.time(); found = {}
    for f in sorted(os.listdir(folder)):
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

print(f"\n{failed} failed" if failed else "\nALL PASSED")
sys.exit(1 if failed else 0)
