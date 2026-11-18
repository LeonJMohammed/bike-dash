#!/bin/bash
# LaunchAgent entry point (com.jlmoh.bikedash.agent), inside the logged-in
# session where the keychain is unlocked.
#
# - A request in the queue folder (from the PC over SSH) runs that request.
# - Started by the schedule (every 15 minutes) or at login, with nothing
#   queued, it runs the re-sign check, which decides for itself whether it's
#   time (evenings, or the night before it expires; see refresh.sh).
# - Every run first makes sure Tailscale is on, and turns it on if not.
# launchd never runs two copies of this job, so builds never overlap; requests
# that arrive meanwhile start it again.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ts="$(ensure_tailscale 2>&1)"
if [ -n "$ts" ]; then
  printf '== %s\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ts" >> "$LOG_DIR/refresh.log"
fi

shopt -s nullglob
found=false
for req in "$QUEUE_DIR"/*.req; do
  found=true
  id="$(basename "$req" .req)"
  action="$(cat "$req")"
  rm -f "$req"
  out="$LOG_DIR/$id.log"
  set_status "running $id"
  log "start $id ($action)"
  case "$action" in
    "build") /bin/bash "$REPO/scripts/build-install.sh" > "$out" 2>&1 ;;
    "build launch") /bin/bash "$REPO/scripts/build-install.sh" --launch > "$out" 2>&1 ;;
    "check") /bin/bash "$REPO/scripts/check.sh" > "$out" 2>&1 ;;
    "refresh") /bin/bash "$REPO/scripts/refresh.sh" > "$out" 2>&1 ;;
    "refresh force") /bin/bash "$REPO/scripts/refresh.sh" --force > "$out" 2>&1 ;;
    "test-alert") /bin/bash "$REPO/scripts/refresh.sh" --test-alert > "$out" 2>&1 ;;
    *) echo "Unknown request: $action" > "$out"; false ;;
  esac
  rc=$?
  if [ "$rc" -eq 0 ]; then set_status "ok $id"; else set_status "failed $id"; fi
  log "end $id (exit $rc)"
done

if ! $found; then
  # Only says something when it checked or tried.
  out="$(/bin/bash "$REPO/scripts/refresh.sh" --scheduled 2>&1)"
  if [ -n "$out" ]; then
    printf '== %s\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$out" >> "$LOG_DIR/refresh.log"
  fi
fi

# Keep a month of per-request logs.
find "$LOG_DIR" -name '20*.log' -mtime +30 -delete 2>/dev/null || true
