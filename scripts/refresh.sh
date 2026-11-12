#!/bin/bash
# Keeps Bike Dash signed. Free signing lasts 7 days, so once less than 3 days
# are left this gets a fresh signature and reinstalls the app over Wi-Fi.
#
# The LaunchAgent runs it at login and every 15 minutes with --scheduled.
# Until a re-sign is due, a scheduled run only checks every 3 hours and says
# nothing in between; once due, every run tries. Before building it checks
# what a re-sign needs (Xcode signed in, the iPhone home and unlocked), and
# the alert says which one is missing.
#
# Also run on request from the PC (mac.ps1 refresh [-Force], mac.ps1
# testalert). Signing needs the logged-in session, so real renewals must go
# through the agent; --dry-run works over plain SSH.
#   refresh.sh [--scheduled] [--force] [--dry-run] [--pretend-expiry <epoch>] [--device <id>] [--test-alert]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_env

RENEW_WITHIN=$((72 * 3600))
CHECK_EVERY=$((3 * 3600))
ALERTS_FILE="$CONFIG_DIR/alerts-sent"
LAST_CHECK_FILE="$CONFIG_DIR/last-check"

scheduled=false
force=false
dry=false
pretend=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scheduled) scheduled=true ;;
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

now="$(date +%s)"
expiry="${pretend:-$(state_expiry)}"
if [ -n "$expiry" ]; then left=$((expiry - now)); else left=0; fi
due=true
if ! $force && [ -n "$expiry" ] && [ "$left" -gt "$RENEW_WITHIN" ]; then due=false; fi

# Not due: a scheduled run checks in every 3 hours and is silent in between.
if ! $due && $scheduled; then
  last_check="$(cat "$LAST_CHECK_FILE" 2>/dev/null)"
  case "$last_check" in ''|*[!0-9]*) last_check=0 ;; esac
  [ $((now - last_check)) -lt "$CHECK_EVERY" ] && exit 0
fi
$dry || echo "$now" > "$LAST_CHECK_FILE"

if [ -n "$expiry" ]; then
  say "Signature expires $(when "$expiry") ($((left / 3600)) h left)"
else
  say "No record of the installed build's signature"
fi
if ! $due; then
  say "Not due yet"
  $dry || hc_ping
  exit 0
fi

if [ "$left" -gt 0 ]; then
  stops="It stops opening $(when "$expiry")."
else
  stops="It has expired and won't open until it's re-signed."
fi

# One kind of alert at most every 8 hours, and only 7 am to 10 pm unless it
# runs out within 6 hours, so a weekend away doesn't buzz all night.
alert() {  # kind title message
  local last hour priority=default
  last="$(grep "^$1 " "$ALERTS_FILE" 2>/dev/null | tail -n 1 | cut -d' ' -f2)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  hour=$((10#$(date +%H)))
  if [ $((now - last)) -lt $((8 * 3600)) ]; then
    say "Alert '$1' was sent under 8 hours ago"
    return 0
  fi
  if [ "$left" -gt $((6 * 3600)) ] && { [ "$hour" -lt 7 ] || [ "$hour" -ge 22 ]; }; then
    say "Alert '$1' held until 7 am"
    return 0
  fi
  [ "$left" -lt $((24 * 3600)) ] && priority=high
  if $dry; then
    say "Would alert ($priority): $2: $3"
    return 0
  fi
  notify "$2" "$3" "$priority"
  echo "$1 $now" >> "$ALERTS_FILE"
  tail -n 50 "$ALERTS_FILE" > "$ALERTS_FILE.tmp" && mv "$ALERTS_FILE.tmp" "$ALERTS_FILE"
}

# The alert for why a re-sign can't happen, then stop.
blocked() {  # cause [detail]
  case "$1" in
    signedout)
      say "Xcode is signed out of the Apple ID"
      alert signedout "Bike Dash can't re-sign" \
        "Xcode on the MacBook is signed out. Open Xcode > Settings > Accounts and sign in again. $stops" ;;
    unreachable)
      say "The phone isn't reachable"
      alert unreachable "Bike Dash needs re-signing" \
        "The MacBook can't see your iPhone. Be home on Wi-Fi with the MacBook open. $stops" ;;
    locked)
      say "The phone is locked"
      alert locked "Unlock your iPhone for Bike Dash" \
        "The MacBook is ready to re-sign Bike Dash, but your iPhone is locked. Unlock it at home; the MacBook tries again every 15 minutes. $stops" ;;
    failed)
      say "The build or install failed: $2"
      alert failed "Bike Dash re-sign failed" "$2 $stops" ;;
  esac
  $dry || hc_ping
}

# What a re-sign needs, cheapest check first.
if ! xcode_signed_in; then
  blocked signedout
  exit 0
fi
if [ -z "${DEVICE_ID:-}" ] ||
   ! with_timeout 60 xcrun devicectl device info details --device "$DEVICE_ID" > "$LOG_DIR/reach.log" 2>&1; then
  blocked unreachable
  exit 0
fi
if ! phone_ready_for_development; then
  blocked locked
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

build_log="$LOG_DIR/refresh-build.log"
if ! /bin/bash "$REPO/scripts/build-install.sh" > "$build_log" 2>&1; then
  if grep -q 'needs to be unlocked' "$build_log"; then
    blocked locked
  elif grep -qE 'No Accounts|session has expired|Unable to log in' "$build_log"; then
    blocked signedout
  elif grep -q 'Timed out waiting for all destinations' "$build_log"; then
    blocked unreachable
  else
    detail="$(grep -E 'error:' "$build_log" | sort -u | head -n 3)"
    blocked failed "${detail:-See ~/Library/Logs/bike-dash/refresh-build.log on the MacBook.}"
  fi
  exit 1
fi

new="$(state_expiry)"
if [ -n "$expiry" ] && [ "${new:-0}" -le "$expiry" ]; then
  say "Apple gave back the same signature: still $(when "$new")"
  alert same "Bike Dash re-sign didn't extend it" \
    "It still expires $(when "$new"). The MacBook will keep trying."
else
  say "Re-signed: good until $(when "$new")"
  notify "Bike Dash re-signed" "Good until $(when "$new")." low
fi
hc_ping
