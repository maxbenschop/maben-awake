#!/bin/sh
# Run as root (Sleepwalker asks for your password once).
# Installs the lid-open failsafe: a small root launch daemon that turns the
# screen back on and unfreezes apps when the lid opens, if Sleepwalker itself
# is stuck. Being root, it can't be frozen by anything in your login session.
#   install-failsafe.sh <path to sleepwalker-failsafe>   install or update
#   install-failsafe.sh --uninstall                       remove
set -e
LABEL=com.maxbenschop.sleepwalker.failsafe
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
if [ "$1" = "--uninstall" ]; then rm -f "$BIN" "$PLIST"; exit 0; fi

SRC="$1"
[ -x "$SRC" ] || { echo "usage: $0 <sleepwalker-failsafe binary> | --uninstall" >&2; exit 1; }

# Root runs this binary, so it must live somewhere only root can write.
mkdir -p /Library/PrivilegedHelperTools
install -m 0755 -o root -g wheel "$SRC" "$BIN"

TMP=$(mktemp)
cat > "$TMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string><string>daemon</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardErrorPath</key><string>/Library/Logs/Sleepwalker-failsafe.log</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$TMP" >/dev/null
install -m 0644 -o root -g wheel "$TMP" "$PLIST"
rm -f "$TMP"

# bootout can take a moment to finish; retry the load briefly.
for _ in 1 2 3 4 5; do
    /bin/launchctl bootstrap system "$PLIST" 2>/dev/null && break
    sleep 1
done
/bin/launchctl print "system/$LABEL" >/dev/null
