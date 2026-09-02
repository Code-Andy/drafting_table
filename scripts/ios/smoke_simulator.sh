#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
derived_data="$repo_root/build/ios/SimulatorDerivedData"

xcodebuild \
  -project "$repo_root/DraftingTable.xcodeproj" \
  -scheme DraftingTable \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

app_path="$derived_data/Build/Products/Release-iphonesimulator/DraftingTable.app"
test -d "$app_path"

device_udid="$(python3 -c '
import json, subprocess
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for devices in data.get("devices", {}).values():
    for device in devices:
        if "iPad" in device.get("name", "") and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPad simulator")
')"

cleanup() {
  xcrun simctl terminate "$device_udid" com.local.draftingtable.ipad >/dev/null 2>&1 || true
  xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "$device_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_udid" -b
xcrun simctl install "$device_udid" "$app_path"
launch_output="$(xcrun simctl launch "$device_udid" com.local.draftingtable.ipad)"
pid="${launch_output##*: }"
test -n "$pid"
sleep 8
xcrun simctl spawn "$device_udid" /bin/kill -0 "$pid"

echo "Drafting Table simulator launch smoke test passed (pid $pid)"
