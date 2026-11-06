#!/bin/bash
# Installs the Bike Dash LaunchAgent. Run once in Terminal on the Mac, in the
# logged-in session (launchctl can't load it into that session from SSH).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

label="com.jlmoh.bikedash.agent"
src="$REPO/scripts/launchd/$label.plist"
dst="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "$src" > "$dst"
plutil -lint "$dst" > /dev/null
launchctl bootout "$domain/$label" 2>/dev/null || true
sleep 1
launchctl bootstrap "$domain" "$dst"
echo "Installed $label. It runs whenever a request lands in $QUEUE_DIR."
