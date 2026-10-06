#!/usr/bin/env bash
set -euo pipefail

# Deterministic simulator selection for CI. This script intentionally owns only
# simulator boot/install/launch. The MockDeviceTestClient remains the behavioral
# driver and communicates through MWDAT_TEST_SERVER_PORT_FILE.
DEVICE_NAME="${AWL_IOS_SIMULATOR_NAME:-iPhone 16}"
PORT_FILE="${RUNNER_TEMP:-/tmp}/awl-mwdat-port"
DERIVED_DATA="${RUNNER_TEMP:-/tmp}/awl-meta-derived"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable", False):
            print(d["udid"])
            raise SystemExit(0)
raise SystemExit(f"no available simulator named {name}")
' "$DEVICE_NAME")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

rm -f "$PORT_FILE"
rm -rf "$DERIVED_DATA"

xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration-Package \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  build

HOST="$(find "$DERIVED_DATA/Build/Products" -type d -name 'AgentWearLinkMetaDATTestHost.app' -print -quit)"
if [[ -z "$HOST" ]]; then
  echo "Meta DAT test host app product was not found" >&2
  exit 1
fi

xcrun simctl install "$UDID" "$HOST"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOST/Info.plist")"
SIMCTL_CHILD_MWDAT_TEST_SERVER_PORT_FILE="$PORT_FILE" \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" --awl-meta-ui-testing

echo "AWL_META_SIMULATOR_UDID=$UDID"
echo "AWL_META_PORT_FILE=$PORT_FILE"
