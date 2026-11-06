#!/bin/bash
# Builds Bike Dash, signs it with the free personal team and installs it on
# the iPhone over Wi-Fi. Usage: build-install.sh [--launch]
#
# Run it through the LaunchAgent (scripts/agent.sh), not straight from SSH:
# signing needs the login keychain, which is only unlocked in the logged-in
# session. That way no password is ever stored.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
load_env

launch=false
if [ "${1:-}" = "--launch" ]; then launch=true; fi

if [ -z "${DEVICE_ID:-}" ]; then
  echo "DEVICE_ID is not set in $ENV_FILE (find it with: xcrun devicectl list devices)"
  exit 1
fi

cd "$REPO"
commit="$(git rev-parse --short HEAD)"
build="$(git rev-list --count HEAD)"
buildlog="$LOG_DIR/xcodebuild.log"

echo "== Generating the Xcode project"
xcodegen generate --quiet

echo "== Building $commit (build $build)"
if ! xcodebuild \
    -project BikeDash.xcodeproj -scheme BikeDash -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION="$build" BIKEDASH_COMMIT="$commit" \
    build > "$buildlog" 2>&1; then
  echo "Build failed. Errors from $buildlog:"
  grep -E 'error:' "$buildlog" | sort -u | head -n 40 || true
  echo "-- last lines --"
  tail -n 15 "$buildlog"
  exit 1
fi
# Our own warnings only (not the Swift packages').
grep -E ' warning: ' "$buildlog" | grep -v '/SourcePackages/' | sort -u | head -n 20 || true

expiry="$(profile_expiry_epoch "$APP")"
echo "== Signed; the profile expires $(date -r "$expiry" '+%a %d %b %H:%M')"

echo "== Installing on the iPhone"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$LOG_DIR/install.log" 2>&1; then
  echo "Install failed:"
  tail -n 20 "$LOG_DIR/install.log"
  exit 1
fi
write_state "$expiry" "$commit"

if $launch; then
  if xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" > "$LOG_DIR/launch.log" 2>&1; then
    echo "== Opened on the phone"
  else
    echo "== Installed, but it couldn't be opened (is the phone locked?)"
  fi
fi
echo "== Done: $commit, build $build"
