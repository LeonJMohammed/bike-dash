#!/bin/bash
# Builds Bike Dash for the iPhone simulator and screenshots it in demo mode.
#   sim-shot.sh <name> [app launch arguments...]
#   sim-shot.sh ride -demo ride            sim-shot.sh settings -demo idle -sheet settings
#   sim-shot.sh history -demo history -sheet history
# Prints the PNG's path. Works over plain SSH: simulator builds need no keychain.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

name="$1"
shift
sim="${SIM_DEVICE:-iPhone 17 Pro}"
derived="$HOME/Library/Caches/bike-dash/DerivedData-sim"

cd "$REPO"
xcodegen generate --quiet
if ! xcodebuild -project BikeDash.xcodeproj -scheme BikeDash -configuration Debug \
    -destination "platform=iOS Simulator,name=$sim" -derivedDataPath "$derived" \
    build > "$LOG_DIR/sim-build.log" 2>&1; then
  echo "Simulator build failed:"
  grep -E 'error:' "$LOG_DIR/sim-build.log" | sort -u | head -n 40 || true
  tail -n 5 "$LOG_DIR/sim-build.log"
  exit 1
fi

udid="$(xcrun simctl list devices available | grep -F "    $sim (" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl status_bar "$udid" override --time "8:50" --batteryLevel 70 --wifiBars 3 --cellularBars 4 > /dev/null 2>&1 || true
xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/BikeDash.app"
xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" > /dev/null
sleep 4
out="/tmp/bike-dash-$name.png"
xcrun simctl io "$udid" screenshot "$out" > /dev/null 2>&1
echo "$out"
