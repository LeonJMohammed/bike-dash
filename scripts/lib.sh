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

# Expiry (epoch seconds) of the build on the phone, from state.json; empty if unknown.
state_expiry() {
  plutil -extract expiresAt raw -o - "$STATE_FILE" 2>/dev/null
}

# "Thu 12 Nov 20:41" from epoch seconds.
when() {
  date -r "$1" '+%a %d %b %H:%M'
}

# Runs a command, killing it after the given number of seconds.
with_timeout() {
  perl -e 'alarm shift; exec @ARGV' "$@"
}

# ntfy alert to the phone (the same topic as the PC's system monitor).
notify() {  # title message [priority]
  if [ -z "${NTFY_TOPIC:-}" ]; then
    log "ntfy: NTFY_TOPIC not set; would have sent: $1"
    return 0
  fi
  curl -fsS -m 20 --retry 2 \
    -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: bike" \
    -d "$2" "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC" > /dev/null \
    || log "ntfy: send failed ($1)"
}

# Healthchecks.io heartbeat, so days without a run (MacBook off) alert too.
hc_ping() {  # [/fail]
  [ -n "${HC_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 "$HC_PING_URL${1:-}" > /dev/null || log "healthchecks: ping failed"
}

# Whether Xcode is signed in to an Apple ID: without one it can't fetch a
# signing profile ("No Accounts").
xcode_signed_in() {
  defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q '@'
}

# Whether the phone's development services are up. They only start while
# it's unlocked; until then a build fails with "needs to be unlocked".
phone_ready_for_development() {
  local json rc
  json="$(mktemp)"
  with_timeout 60 xcrun devicectl device info ddiServices --device "$DEVICE_ID" -j "$json" -q > /dev/null 2>&1 &&
    grep -Eq '"isUsable"[[:space:]]*:[[:space:]]*true' "$json"
  rc=$?
  rm -f "$json"
  return $rc
}

# Paths of Xcode's cached signing profiles for Bike Dash, one per line.
cached_profiles() {
  local dir file
  printf '%s\n' "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
                "$HOME/Library/MobileDevice/Provisioning Profiles" |
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.mobileprovision; do
      [ -e "$file" ] || continue
      if security cms -D -i "$file" 2>/dev/null | grep -qF ".$BUNDLE_ID</string>"; then
        printf '%s\n' "$file"
      fi
    done
  done
}

# One line about a profile: created, expires, team, UUID.
describe_profile() {
  local plist
  plist="$(mktemp)"
  if ! security cms -D -i "$1" > "$plist" 2>/dev/null; then
    rm -f "$plist"
    return 1
  fi
  printf 'created %s, expires %s, team %s, uuid %s\n' \
    "$(plutil -extract CreationDate raw -o - "$plist")" \
    "$(plutil -extract ExpirationDate raw -o - "$plist")" \
    "$(plutil -extract TeamIdentifier.0 raw -o - "$plist")" \
    "$(plutil -extract UUID raw -o - "$plist")"
  rm -f "$plist"
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
