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
xcrun simctl launch --terminate-running-process "$device_udid" \
  com.local.draftingtable.ipad >/dev/null
sleep 8
process_table="$(xcrun simctl spawn "$device_udid" /bin/ps -A -o pid=,comm= 2>&1 || true)"
echo "$process_table"
pid="$(printf '%s\n' "$process_table" | awk '$2 ~ /DraftingTable$/ { print $1; exit }')"
if [[ -z "$pid" ]]; then
  echo "Drafting Table exited during launch smoke test; recent simulator log follows" >&2
  kill "$log_stream_pid" >/dev/null 2>&1 || true
  wait "$log_stream_pid" >/dev/null 2>&1 || true
  log_stream_pid=""
  tail -n 800 "$runtime_log" || true
  latest_report="$(ls -1t "$HOME"/Library/Logs/DiagnosticReports/DraftingTable* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest_report" ]]; then
    echo "Latest host crash report: $latest_report" >&2
    tail -n 1200 "$latest_report" || true
  fi
  simulator_report_dir="$HOME/Library/Developer/CoreSimulator/Devices/$device_udid/data/Library/Logs/CrashReporter"
  simulator_report="$(find "$simulator_report_dir" -type f -name 'DraftingTable*' -print 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "$simulator_report" ]]; then
    echo "Latest simulator crash report: $simulator_report" >&2
    cat "$simulator_report" || true
  fi
  exit 1
fi

echo "Drafting Table simulator launch smoke test passed (pid $pid)"
