#!/bin/bash
# Shared settings and helpers for the Mac-side scripts.
# macOS ships bash 3.2: no associative arrays, no ${var,,}, no mapfile.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.jlmoh.bikedash"

CONFIG_DIR="$HOME/.config/bike-dash"
QUEUE_DIR="$CONFIG_DIR/queue"        # the PC drops build requests here (LaunchAgent QueueDirectories)
STATUS_FILE="$CONFIG_DIR/status"     # "running|ok|failed <request id>", polled by the PC
STATE_FILE="$CONFIG_DIR/state.json"  # signing expiry of the build on the phone
ENV_FILE="$CONFIG_DIR/refresh.env"   # DEVICE_ID, later NTFY_TOPIC and HC_PING_URL
LOG_DIR="$HOME/Library/Logs/bike-dash"
DERIVED="$HOME/Library/Caches/bike-dash/DerivedData"
APP="$DERIVED/Build/Products/Release-iphoneos/BikeDash.app"

# launchd starts jobs with a bare PATH, so add Homebrew's.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Use the full Xcode even if xcode-select still points at the Command Line Tools.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$CONFIG_DIR" "$QUEUE_DIR" "$LOG_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_DIR/agent.log"
}

set_status() {
  printf '%s\n' "$*" > "$STATUS_FILE"
}

# Loads the Mac-only settings, if the file exists.
load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

# Prints when the app's signing profile expires, in seconds since 1970.
profile_expiry_epoch() {
  local plist iso
  plist="$(mktemp)"
  if ! security cms -D -i "$1/embedded.mobileprovision" > "$plist" 2>/dev/null; then
    rm -f "$plist"
    return 1
  fi
  iso="$(plutil -extract ExpirationDate raw -o - "$plist")"
  rm -f "$plist"
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s'
}

# Records what is on the phone now: profile expiry (epoch seconds) and commit.
write_state() {
  cat > "$STATE_FILE" <<EOF
{
  "expiresAt": $1,
  "expires": "$(date -r "$1" '+%Y-%m-%d %H:%M %Z')",
  "installedAt": "$(date '+%Y-%m-%d %H:%M %Z')",
  "commit": "$2"
}
EOF
}
