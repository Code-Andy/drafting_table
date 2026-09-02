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
  -enableAddressSanitizer YES \
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
  if [[ -n "${log_stream_pid:-}" ]]; then
    kill "$log_stream_pid" >/dev/null 2>&1 || true
    wait "$log_stream_pid" >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "$device_udid" com.local.draftingtable.ipad >/dev/null 2>&1 || true
  xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
  [[ -z "${runtime_log:-}" ]] || rm -f "$runtime_log"
}
trap cleanup EXIT

xcrun simctl boot "$device_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_udid" -b
xcrun simctl install "$device_udid" "$app_path"
runtime_log="$(mktemp)"
xcrun simctl spawn "$device_udid" log stream \
  --style compact \
  --level debug \
  --predicate 'process == "DraftingTable" OR eventMessage CONTAINS[c] "com.local.draftingtable.ipad"' \
  >"$runtime_log" 2>&1 &
log_stream_pid=$!
launch_output="$(SIMCTL_CHILD_ASAN_OPTIONS='log_path=/tmp/draftingtable-asan:abort_on_error=1:halt_on_error=1' \
  xcrun simctl launch "$device_udid" com.local.draftingtable.ipad)"
pid="${launch_output##*: }"
test -n "$pid"
sleep 8
if ! xcrun simctl spawn "$device_udid" /bin/kill -0 "$pid"; then
  echo "Drafting Table exited during launch smoke test; recent simulator log follows" >&2
  kill "$log_stream_pid" >/dev/null 2>&1 || true
  wait "$log_stream_pid" >/dev/null 2>&1 || true
  log_stream_pid=""
  echo "AddressSanitizer report:" >&2
  xcrun simctl spawn "$device_udid" /bin/sh -c \
    'cat /tmp/draftingtable-asan.* 2>/dev/null || true' || true
  tail -n 800 "$runtime_log" || true
  latest_report="$(ls -1t "$HOME"/Library/Logs/DiagnosticReports/DraftingTable* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest_report" ]]; then
    echo "Latest host crash report: $latest_report" >&2
    tail -n 1200 "$latest_report" || true
  fi
  exit 1
fi

echo "Drafting Table simulator launch smoke test passed (pid $pid)"
