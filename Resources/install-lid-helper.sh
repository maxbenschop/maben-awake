#!/bin/sh
# Run as root (Maben Awake asks for your password once).
# Lets <user> toggle closed-lid sleep without a password. Nothing else.
#   install-lid-helper.sh <user>            install
#   install-lid-helper.sh --uninstall       remove
set -e
FILE=/etc/sudoers.d/maben-awake
# Rules installed under the app's old names.
OLD="/etc/sudoers.d/sleepwalker /etc/sudoers.d/awakekeeper"
if [ "$1" = "--uninstall" ]; then rm -f "$FILE" $OLD; /usr/bin/pmset -a disablesleep 0; exit 0; fi
USER_NAME="$1"
[ -n "$USER_NAME" ] || { echo "usage: $0 <user>" >&2; exit 1; }
TMP=$(mktemp)
cat > "$TMP" <<RULE
# Installed by Maben Awake: allow toggling closed-lid sleep only.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
RULE
/usr/sbin/visudo -cf "$TMP" >/dev/null
install -m 0440 -o root -g wheel "$TMP" "$FILE"
rm -f "$TMP" $OLD
