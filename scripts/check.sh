#!/bin/bash
# Diagnostics from inside the LaunchAgent (request "check"): is this the
# logged-in Aqua session that signing needs, which signing identities exist,
# and can the Mac see the phone?
source "$(dirname "$0")/lib.sh"
load_env

echo "user: $(whoami), launchd session: $(launchctl managername) (signing needs Aqua)"
echo "$(xcodebuild -version | head -n 1), XcodeGen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"
echo "signing identities:"
security find-identity -v -p codesigning | sed 's/^/  /'
if [ -n "${DEVICE_ID:-}" ]; then
  echo "phone $DEVICE_ID:"
  xcrun devicectl device info details --device "$DEVICE_ID" 2>&1 \
    | grep -i -E 'name:|marketingName|osVersionNumber|tunnelState|developerModeStatus' \
    | head -n 8 | sed 's/^/  /'
else
  echo "phone: DEVICE_ID not set yet in $ENV_FILE"
fi
