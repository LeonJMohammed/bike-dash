#!/bin/bash
# Keeps Bike Dash signed. Free signing lasts 7 days, so once less than 2 days
# are left this gets a fresh signature and reinstalls the app over Wi-Fi.
#
# Runs from the LaunchAgent every 3 hours and at login, or on request from
# the PC (mac.ps1 refresh [-Force], mac.ps1 testalert). Signing needs the
# logged-in session, so real renewals must go through the agent; --dry-run
# works over plain SSH.
#   refresh.sh [--force] [--dry-run] [--pretend-expiry <epoch>] [--device <id>] [--test-alert]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_env

RENEW_WITHIN=$((48 * 3600))
ALERTS_FILE="$CONFIG_DIR/alerts-sent"

force=false
dry=false
pretend=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=true ;;
    --dry-run) dry=true ;;
    --pretend-expiry) pretend="$2"; shift ;;
    --device) DEVICE_ID="$2"; shift ;;
    --test-alert)
      notify "TEST: Bike Dash" "A test from the MacBook's re-sign job. Nothing is wrong." low
      echo "Sent a test alert."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

say() {
  echo "$*"
  log "refresh: $*"
}

# At most one alert a day of each kind, so a phone that's away for a weekend
# doesn't buzz every 3 hours.
alert_daily() {  # kind title message [priority]
  local stamp
  stamp="$1 $(date '+%Y-%m-%d')"
  if grep -qxF "$stamp" "$ALERTS_FILE" 2>/dev/null; then
    say "Alert '$1' already sent today"
    return 0
  fi
  if $dry; then
    say "Would alert: $2: $3"
    return 0
  fi
  notify "$2" "$3" "${4:-default}"
  echo "$stamp" >> "$ALERTS_FILE"
}

now="$(date +%s)"
expiry="${pretend:-$(state_expiry)}"
if [ -n "$expiry" ]; then
  left=$((expiry - now))
  say "Signature expires $(when "$expiry") ($((left / 3600)) h left)"
else
  left=0
  say "No record of the installed build's signature"
fi

if ! $force && [ -n "$expiry" ] && [ "$left" -gt "$RENEW_WITHIN" ]; then
  say "Not due yet"
  $dry || hc_ping
  exit 0
fi

if [ -z "${DEVICE_ID:-}" ] ||
   ! with_timeout 60 xcrun devicectl device info details --device "$DEVICE_ID" > "$LOG_DIR/reach.log" 2>&1; then
  say "The phone isn't reachable"
  if [ -n "$expiry" ] && [ "$left" -gt 0 ]; then
    alert_daily unreachable "Bike Dash needs re-signing" \
      "It stops opening $(when "$expiry"). The MacBook can't see your iPhone: be home on Wi-Fi with the MacBook open." high
  else
    alert_daily expired "Bike Dash has expired" \
      "It won't open until the MacBook re-signs it. Be home on Wi-Fi with the MacBook open." high
  fi
  $dry || hc_ping
  exit 0
fi

if $dry; then
  say "Would renew now: set the cached profile aside, build and install"
  exit 0
fi

# A plain rebuild reuses Xcode's cached profile and keeps the old expiry, so
# set it aside and let Xcode ask Apple for a fresh 7-day one.
backup="$CONFIG_DIR/profile-backup/$(date '+%Y%m%d-%H%M%S')"
cached_profiles | while IFS= read -r file; do
  mkdir -p "$backup"
  mv "$file" "$backup/" && say "Set aside $(basename "$file")"
done

if ! /bin/bash "$REPO/scripts/build-install.sh" > "$LOG_DIR/refresh-build.log" 2>&1; then
  say "The build or install failed:"
  tail -n 15 "$LOG_DIR/refresh-build.log"
  detail="$(grep -iE 'error|failed' "$LOG_DIR/refresh-build.log" | tail -n 3)"
  [ -n "$detail" ] || detail="See ~/Library/Logs/bike-dash/refresh-build.log on the MacBook."
  alert_daily failed "Bike Dash re-sign failed" "$detail" high
  hc_ping
  exit 1
fi

new="$(state_expiry)"
if [ -n "$expiry" ] && [ "${new:-0}" -le "$expiry" ]; then
  say "Apple gave back the same signature: still $(when "$new")"
  alert_daily same "Bike Dash re-sign didn't extend it" \
    "It still expires $(when "$new"). The MacBook will keep trying."
else
  say "Re-signed: good until $(when "$new")"
  notify "Bike Dash re-signed" "Good until $(when "$new")." low
fi
hc_ping
