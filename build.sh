#!/bin/sh
# Builds Sleepwalker.app into ./build and optionally installs it.
#   ./build.sh            -> build only
#   ./build.sh install    -> build, copy to /Applications, install `awake` CLI,
#                            add Claude Code hooks, launch (migrates AwakeKeeper)
set -e
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Sleepwalker
HOOK=$(swift build -c release --show-bin-path)/SleepwalkerHook

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

APP=build/Sleepwalker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sleepwalker"
cp "$HOOK" "$APP/Contents/MacOS/sleepwalker-hook"
cp Info.plist "$APP/Contents/Info.plist"
# Unique build number per build: macOS only refreshes its background-item record
# (which pins the launchd agent to one code signature) when the version changes.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/awake Resources/install-lid-helper.sh "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

[ "$1" = "install" ] || exit 0

# --- Stop running copies (gracefully, so frozen apps get thawed) --------
for name in Sleepwalker AwakeKeeper; do
    osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true
done
sleep 1; pkill -x Sleepwalker 2>/dev/null || true; pkill -x AwakeKeeper 2>/dev/null || true

# --- Migrate from AwakeKeeper -----------------------------------------
if [ -d /Applications/AwakeKeeper.app ]; then
    if ! defaults read com.maxbenschop.sleepwalker >/dev/null 2>&1; then
        defaults export com.maxbenschop.awakekeeper - | defaults import com.maxbenschop.sleepwalker -
        defaults delete com.maxbenschop.sleepwalker didOfferLogin 2>/dev/null || true
        echo "Migrated AwakeKeeper settings"
    fi
    OLD="$HOME/Library/Application Support/AwakeKeeper"
    NEW="$HOME/Library/Application Support/Sleepwalker"
    [ -d "$OLD" ] && [ ! -d "$NEW" ] && mv "$OLD" "$NEW"
    rm -rf /Applications/AwakeKeeper.app
    echo "Removed /Applications/AwakeKeeper.app"
fi

# --- App ---------------------------------------------------------------
rm -rf /Applications/Sleepwalker.app
cp -R "$APP" /Applications/
echo "Installed /Applications/Sleepwalker.app"

# --- CLI ---------------------------------------------------------------
CLI=/Applications/Sleepwalker.app/Contents/Resources/awake
for bindir in /opt/homebrew/bin /usr/local/bin; do
    if [ -w "$bindir" ]; then ln -sf "$CLI" "$bindir/awake"; echo "Linked $bindir/awake"; break; fi
done

# --- Claude Code hooks -------------------------------------------------
# Hold a lease on every prompt / tool call, release when Claude stops.
# Replaces hooks that point at the old AwakeKeeper.app.
python3 - /Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook <<'PY'
import json, os, sys
hook = sys.argv[1]
path = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(path)) if os.path.exists(path) else {}
hooks = s.setdefault("hooks", {})
cmd = {"type": "command", "command": f'"{hook}"'}
old_hooks = ("AwakeKeeper.app", "Sleepwalker.app/Contents/Resources/awake")
for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]:
    lst = hooks.setdefault(event, [])
    for g in lst:
        g["hooks"] = [h for h in g.get("hooks", []) if not any(o in h.get("command", "") for o in old_hooks)]
    lst[:] = [g for g in lst if g.get("hooks")]
    if not any(h.get("command") == cmd["command"] for g in lst for h in g.get("hooks", [])):
        lst.append({"matcher": "", "hooks": [cmd]} if event.endswith("ToolUse") else {"hooks": [cmd]})
json.dump(s, open(path, "w"), indent=2)
print("Claude Code hooks set in", path)
md = os.path.expanduser("~/.claude/CLAUDE.md")
if os.path.exists(md):
    t = open(md).read()
    if "AwakeKeeper" in t:
        open(md, "w").write(t.replace("AwakeKeeper", "Sleepwalker"))
        print("Updated name in", md)
PY

# Start the crash-safe launchd copy if the agent exists; otherwise the app
# installs the agent on first start.
if [ -f "$HOME/Library/LaunchAgents/com.maxbenschop.sleepwalker.agent.plist" ] && \
   launchctl print "gui/$(id -u)/com.maxbenschop.sleepwalker.agent" 2>/dev/null | grep -q "LaunchAgents/com.maxbenschop"; then
    launchctl kickstart -k "gui/$(id -u)/com.maxbenschop.sleepwalker.agent"
else
    open /Applications/Sleepwalker.app
fi
echo "Launched. Sleepwalker starts at login and restarts itself after a crash."
