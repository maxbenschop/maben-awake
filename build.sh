#!/bin/sh
# Builds "Maben Awake.app" into ./build and optionally installs it.
#   ./build.sh            -> build only
#   ./build.sh install    -> build, copy to /Applications, install `awake` CLI,
#                            add Claude Code hooks, launch (migrates installs
#                            under the old names Sleepwalker and AwakeKeeper)
#
# The app was called Sleepwalker until 1.5. The app itself moves an older
# install to the current names when it starts (Sources/MabenAwake/Legacy.swift).
set -e
cd "$(dirname "$0")"

# INSTALL_APP=<path to a built .app> ./build.sh install installs that app (e.g. the notarized release from
# ./release.sh) instead of building a development copy.
if [ -n "$INSTALL_APP" ]; then
    [ -d "$INSTALL_APP" ] || { echo "No app at $INSTALL_APP"; exit 1; }
    APP="$INSTALL_APP"
    INSTALLED="/Applications/Maben Awake.app"
    echo "Installing $APP"
else
    swift build -c release
    BIN=$(swift build -c release --show-bin-path)/MabenAwake
    HOOK=$(swift build -c release --show-bin-path)/MabenAwakeHook
    FAILSAFE=$(swift build -c release --show-bin-path)/MabenAwakeFailsafe

    # App icon: render once, then build the .icns from the 1024px PNG.
    if [ ! -f build/AppIcon.icns ] || [ Resources/make-icon.swift -nt build/AppIcon.icns ]; then
        mkdir -p build/AppIcon.iconset
        swift Resources/make-icon.swift build/icon-1024.png >/dev/null
        for s in 16 32 128 256 512; do
            sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
            sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
        done
        iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    fi

    APP="build/Maben Awake.app"
    INSTALLED="/Applications/Maben Awake.app"
    rm -rf "$APP" build/Sleepwalker.app
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/MabenAwake"
    cp "$HOOK" "$APP/Contents/MacOS/maben-awake-hook"
    cp "$FAILSAFE" "$APP/Contents/MacOS/maben-awake-failsafe"
    # The names 1.4 used, as links: its launch agent starts the app by the old
    # name once after updating, and open agent sessions still call the old hook.
    ln -s MabenAwake "$APP/Contents/MacOS/Sleepwalker"
    ln -s maben-awake-hook "$APP/Contents/MacOS/sleepwalker-hook"
    cp Info.plist "$APP/Contents/Info.plist"
    # Unique build number per build: macOS only refreshes its background-item record
    # (which pins the launchd agent to one code signature) when the version changes.
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
    cp build/AppIcon.icns "$APP/Contents/Resources/"
    cp Resources/awake Resources/install-lid-helper.sh Resources/install-failsafe.sh CHANGELOG.md "$APP/Contents/Resources/"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "Built $APP"
fi

[ "$1" = "install" ] || exit 0

# --- Stop running copies (gracefully, so frozen apps get thawed) --------
for name in "Maben Awake" Sleepwalker AwakeKeeper; do
    osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true
done
sleep 1; for p in MabenAwake Sleepwalker AwakeKeeper; do pkill -x "$p" 2>/dev/null || true; done

# --- Migrate from AwakeKeeper -----------------------------------------
if [ -d /Applications/AwakeKeeper.app ]; then
    if ! defaults read com.maxbenschop.sleepwalker >/dev/null 2>&1; then
        defaults export com.maxbenschop.awakekeeper - | defaults import com.maxbenschop.sleepwalker -
        defaults delete com.maxbenschop.sleepwalker didOfferLogin 2>/dev/null || true
        echo "Migrated AwakeKeeper settings"
    fi
    OLD="$HOME/Library/Application Support/AwakeKeeper"
    NEW="$HOME/Library/Application Support/MabenAwake"
    [ -d "$OLD" ] && [ ! -d "$NEW" ] && mv "$OLD" "$NEW"
    rm -rf /Applications/AwakeKeeper.app
    echo "Removed /Applications/AwakeKeeper.app"
fi

# --- App ---------------------------------------------------------------
# Replaces a copy installed under the old name.
[ -d /Applications/Sleepwalker.app ] && { rm -rf /Applications/Sleepwalker.app; echo "Removed /Applications/Sleepwalker.app"; }
rm -rf "$INSTALLED"
cp -R "$APP" /Applications/
echo "Installed $INSTALLED"

# --- CLI ---------------------------------------------------------------
CLI="$INSTALLED/Contents/Resources/awake"
for bindir in /opt/homebrew/bin /usr/local/bin; do
    if [ -w "$bindir" ]; then ln -sf "$CLI" "$bindir/awake"; echo "Linked $bindir/awake"; break; fi
done

# --- Claude Code hooks -------------------------------------------------
# Hold a lease on every prompt / tool call, release when Claude stops.
# Replaces hooks that point at the app or the hook under an older name
# (Sleepwalker.app, AwakeKeeper.app, sleepwalker-hook). ~/.claude always gets the hooks; any other Claude Code
# config folder (~/.claude-*) that already had them is moved to the new path.
python3 - "$INSTALLED/Contents/MacOS/maben-awake-hook" <<'PY'
import glob, json, os, re, sys
hook = sys.argv[1]
cmd = {"type": "command", "command": f'"{hook}"'}
old_hooks = ("AwakeKeeper.app", "Sleepwalker.app/", "/sleepwalker-hook")
events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
main = os.path.expanduser("~/.claude/settings.json")
paths = [main] + sorted(p for p in glob.glob(os.path.expanduser("~/.claude*/settings.json")) if p != main)
for path in paths:
    s = json.load(open(path)) if os.path.exists(path) else {}
    text = json.dumps(s.get("hooks", {}))
    had = any(o in text for o in old_hooks) or hook in text
    if path != main and not had:
        continue
    hooks = s.setdefault("hooks", {})
    for event in events:
        lst = hooks.setdefault(event, [])
        for g in lst:
            g["hooks"] = [h for h in g.get("hooks", []) if not any(o in h.get("command", "") for o in old_hooks)]
        lst[:] = [g for g in lst if g.get("hooks")]
        if not any(h.get("command") == cmd["command"] for g in lst for h in g.get("hooks", [])):
            lst.append({"matcher": "", "hooks": [cmd]} if event.endswith("ToolUse") else {"hooks": [cmd]})
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(s, open(path, "w"), indent=2)
    print("Claude Code hooks set in", path)
# Codex (if set up on this Mac): the same hook with --agent codex in ~/.codex/hooks.json.
codex_dir = os.path.expanduser("~/.codex")
if os.path.isdir(codex_dir):
    path = os.path.join(codex_dir, "hooks.json")
    s = json.load(open(path)) if os.path.exists(path) and open(path).read().strip() else {}
    hooks = s.setdefault("hooks", {})
    ccmd = {"type": "command", "command": f'"{hook}" --agent codex'}
    for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]:
        lst = hooks.setdefault(event, [])
        for g in lst:
            g["hooks"] = [h for h in g.get("hooks", []) if "maben-awake-hook" not in h.get("command", "") and "sleepwalker-hook" not in h.get("command", "")]
        lst[:] = [g for g in lst if g.get("hooks")]
        lst.append({"hooks": [ccmd]})
    json.dump(s, open(path, "w"), indent=2)
    print("Codex hooks set in", path, "(run /hooks in Codex once to trust them)")
# The old names in prose.
for md in glob.glob(os.path.expanduser("~/.claude*/CLAUDE.md")):
    t = open(md).read()
    new = re.sub(r"(?<![/\w.-])(AwakeKeeper|Sleepwalker)(?![\w/-]|\.\w)", "Maben Awake", t)
    if new != t:
        open(md, "w").write(new)
        print("Updated name in", md)
PY

# Start the crash-safe launchd copy if the agent exists; otherwise the app
# installs the agent on first start. An agent with the old name is removed
# first, so it can't start the app a second time.
OLD_AGENT=com.maxbenschop.sleepwalker.agent
if [ -f "$HOME/Library/LaunchAgents/$OLD_AGENT.plist" ]; then
    launchctl bootout "gui/$(id -u)/$OLD_AGENT" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$OLD_AGENT.plist"
    echo "Removed the launch agent with the old name"
fi
AGENT="$HOME/Library/LaunchAgents/gg.maben.awake.agent.plist"
DOMAIN="gui/$(id -u)"
EXE="$INSTALLED/Contents/MacOS/MabenAwake"
if [ -f "$AGENT" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT" 2>/dev/null)" != "$EXE" ]; then
    launchctl bootout "$DOMAIN/gg.maben.awake.agent" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $EXE" "$AGENT"
    launchctl bootstrap "$DOMAIN" "$AGENT"      # RunAtLoad starts it
    echo "Pointed the launch agent at $INSTALLED"
elif [ -f "$AGENT" ] && \
   launchctl print "$DOMAIN/gg.maben.awake.agent" 2>/dev/null | grep -q "LaunchAgents/gg.maben"; then
    launchctl kickstart -k "$DOMAIN/gg.maben.awake.agent"
else
    open "$INSTALLED"
fi
echo "Launched. Maben Awake starts at login and restarts itself after a crash."
echo "Claude sessions that were already open still call the hook at its old path;"
echo "restart them so they keep the Mac awake again."
