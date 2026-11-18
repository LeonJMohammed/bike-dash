#!/bin/bash
# Keeps Bike Dash signed. Free signing lasts 7 days, so from the evening of
# day 5 (under 3.5 days left) this gets a fresh signature and reinstalls the
# app over Wi-Fi.
#
# The LaunchAgent starts it every 15 minutes with --scheduled (after checking
# that Tailscale is on; see agent.sh), and this decides whether to do anything:
#
# - Evenings (Leon, 18 Nov 2026): at most once in each hour from 20:00 to
#   23:59, so 20:00 with 21:00, 22:00 and 23:00 as retries. A slot missed while
#   the Mac slept is taken when it wakes, if that's still the evening (a wake at
#   21:30 tries at 21:30, then 22:00); a morning wake does nothing and waits for
#   the evening. Once due, every evening tries until one works, and the
#   evenings of days 5, 6 and 7 come before it expires. Until due, the first
#   run of each evening only checks.
# - The night before it runs out (Leon, 18 Nov 2026): from 8 pm to 8 am with
#   under 28 hours left, every run tries, every 15 minutes, and every one that
#   can't re-sign sends its reminder (high priority), until it's re-signed or
#   has run out. 28 hours covers the whole night before an evening expiry.
# - Any other time a scheduled run does nothing.
#
# Before building it checks what a re-sign needs (Xcode signed in, the iPhone
# home and unlocked), and the alert says which one is missing. The evening
# check also looks at Xcode's sign-in on its own, so a signed-out Xcode is
# reported days before the re-sign needs it (twice in a week in November
# 2026), with a quiet note once it's signed in again.
#
# ntfy goes out only from 8 pm to midnight, once an evening per kind, or every
# 15 minutes through the night before it runs out; otherwise it's held for the
# next evening (test alerts on request excepted).
#
# Also run on request from the PC (mac.ps1 refresh [-Force], mac.ps1
# testalert), at any hour. Signing needs the logged-in session, so real
# renewals must go through the agent; --dry-run works over plain SSH.
#   refresh.sh [--scheduled] [--force] [--dry-run] [--pretend-expiry <epoch>] [--pretend-signed-out]
#              [--pretend-hour <0-23>] [--device <id>] [--test-alert]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_env

RENEW_WITHIN=$((84 * 3600))  # 3.5 days: due from the evening of day 5
CHECK_EVERY=$((12 * 3600))   # until due, one check per evening
EVENING_FROM=20              # evening runs and alerts: 20:00 to midnight
NIGHT_UNTIL=8                # the night before it runs out lasts until 8 am
LAST_NIGHT=$((28 * 3600))    # "the night before": under this much left
ALERTS_FILE="$CONFIG_DIR/alerts-sent"
LAST_CHECK_FILE="$CONFIG_DIR/last-check"
LAST_SLOT_FILE="$CONFIG_DIR/last-slot"  # the evening hour last tried (YYYYmmddHH)
# Present while Xcode is known to be signed out (so "signed in again" is said once).
SIGNED_OUT_FILE="$CONFIG_DIR/xcode-signed-out"

scheduled=false
force=false
dry=false
pretend=""
pretend_signed_out=false
pretend_hour=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scheduled) scheduled=true ;;
    --force) force=true ;;
    --dry-run) dry=true ;;
    --pretend-expiry) pretend="$2"; shift ;;
    --pretend-signed-out) pretend_signed_out=true ;;
    --pretend-hour) pretend_hour="$2"; shift ;;
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

# Checked when it matters, so a build that runs past midnight sends nothing
# (unless it's the night before it runs out).
hour_now() {
  echo "${pretend_hour:-$((10#$(date +%H)))}"
}
in_evening() {
  [ "$(hour_now)" -ge "$EVENING_FROM" ]
}
last_night() {
  local hour
  hour="$(hour_now)"
  [ -n "$expiry" ] && [ "$left" -gt 0 ] && [ "$left" -le "$LAST_NIGHT" ] &&
    { [ "$hour" -ge "$EVENING_FROM" ] || [ "$hour" -lt "$NIGHT_UNTIL" ]; }
}

# Whether a scheduled run does anything (see the top).
if $scheduled; then
  if last_night; then
    $dry && echo "The night before it runs out: trying every 15 minutes"
  elif in_evening; then
    slot="$(date +%Y%m%d)$(printf %02d "$(hour_now)")"
    if [ "$(cat "$LAST_SLOT_FILE" 2>/dev/null)" = "$slot" ]; then
      $dry && echo "Already ran in this hour: next at the top of the hour"
      exit 0
    fi
    $dry || echo "$slot" > "$LAST_SLOT_FILE"
  else
    $dry && echo "Outside 8 pm to midnight and not the night before it runs out: nothing to do"
    exit 0
  fi
fi

due=true
if ! $force && [ -n "$expiry" ] && [ "$left" -gt "$RENEW_WITHIN" ]; then due=false; fi

# Not due: a scheduled run checks once an evening and is silent otherwise.
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
if [ "$left" -gt 0 ]; then
  stops="It stops opening $(when "$expiry")."
else
  stops="It has expired and won't open until it's re-signed."
fi

signed_in() {
  ! $pretend_signed_out && xcode_signed_in
}

# When the re-sign starts: the evening slot on or after it's due.
if [ -n "$expiry" ]; then
  due_from=$((expiry - RENEW_WITHIN))
  if [ $((10#$(date -r "$due_from" +%H))) -lt "$EVENING_FROM" ]; then
    starts="$(date -r "$due_from" '+%a %d %b') at 8 pm"
  else
    starts="$(when "$due_from")"
  fi
fi

# A quiet note (low priority), only 8 pm to midnight or the night before it
# runs out. Returns 1 if held.
note() {  # title message
  if ! in_evening && ! last_night; then
    say "Held '$1': ntfy only goes out 8 pm to midnight"
    return 1
  fi
  if $dry; then
    say "Would send (low): $1: $2"
    return 0
  fi
  notify "$1" "$2" low
}

# One kind of alert at most every 8 hours (so once an evening), and only
# 8 pm to midnight; one held outside that comes at the next evening run. The
# night before it runs out, every run's alert goes out (every 15 minutes).
alert() {  # kind title message
  local last priority=default
  if last_night; then
    priority=high
  else
    last="$(grep "^$1 " "$ALERTS_FILE" 2>/dev/null | tail -n 1 | cut -d' ' -f2)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt $((8 * 3600)) ]; then
      say "Alert '$1' was sent under 8 hours ago"
      return 0
    fi
    if ! in_evening; then
      say "Alert '$1' held: ntfy only goes out 8 pm to midnight"
      return 0
    fi
    [ "$left" -lt $((24 * 3600)) ] && priority=high
  fi
  if $dry; then
    say "Would alert ($priority): $2: $3"
    return 0
  fi
  notify "$2" "$3" "$priority"
  echo "$1 $now" >> "$ALERTS_FILE"
  tail -n 50 "$ALERTS_FILE" > "$ALERTS_FILE.tmp" && mv "$ALERTS_FILE.tmp" "$ALERTS_FILE"
}

# When the next try is, for the alerts.
if last_night; then
  retry="every 15 minutes until it runs out"
else
  retry="on the hour until 11 pm, then tomorrow evening"
fi

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
        "The MacBook is ready to re-sign Bike Dash, but your iPhone is locked. Unlock it at home; the MacBook tries again $retry. $stops" ;;
    failed)
      say "The build or install failed: $2"
      alert failed "Bike Dash re-sign failed" "$2 $stops" ;;
  esac
  $dry || hc_ping
}

# Not due: still make sure Xcode is signed in, so there's time to fix it.
if ! $due; then
  say "Not due yet"
  if signed_in; then
    if [ -f "$SIGNED_OUT_FILE" ]; then
      say "Xcode is signed in again"
      # Kept until the note goes out, so a daytime run leaves it for the evening.
      if note "Xcode is signed in again" "Bike Dash can re-sign as usual."; then
        $dry || rm -f "$SIGNED_OUT_FILE"
      fi
    fi
  else
    say "Xcode is signed out of the Apple ID (re-sign starts $starts)"
    alert signedout "Xcode signed out: Bike Dash can't re-sign" \
      "Xcode on the MacBook is signed out of the Apple ID. Sign in again under Xcode > Settings > Accounts before $starts, when the re-sign starts. $stops"
    $dry || touch "$SIGNED_OUT_FILE"
  fi
  $dry || hc_ping
  exit 0
fi

# What a re-sign needs, cheapest check first.
if ! signed_in; then
  $dry || touch "$SIGNED_OUT_FILE"
  blocked signedout
  exit 0
fi
$dry || rm -f "$SIGNED_OUT_FILE"
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
  note "Bike Dash re-signed" "Good until $(when "$new")."
fi
hc_ping
