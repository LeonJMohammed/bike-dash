#!/bin/bash
# LaunchAgent entry point (com.jlmoh.bikedash.agent). Runs each request the PC
# dropped into the queue folder, inside the logged-in session where the
# keychain is unlocked. launchd never runs two copies of this job, so
# requests are handled one at a time; any that arrive meanwhile start it again.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

shopt -s nullglob
for req in "$QUEUE_DIR"/*.req; do
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
    *) echo "Unknown request: $action" > "$out"; false ;;
  esac
  rc=$?
  if [ "$rc" -eq 0 ]; then set_status "ok $id"; else set_status "failed $id"; fi
  log "end $id (exit $rc)"
done

# Keep a month of per-request logs.
find "$LOG_DIR" -name '20*.log' -mtime +30 -delete 2>/dev/null || true
