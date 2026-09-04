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
xcrun simctl uninstall "$device_udid" com.local.draftingtable.ipad >/dev/null 2>&1 || true
xcrun simctl install "$device_udid" "$app_path"
runtime_log="$(mktemp)"
xcrun simctl spawn "$device_udid" log stream \
  --style compact \
  --level debug \
  --predicate 'process == "DraftingTable" OR eventMessage CONTAINS[c] "com.local.draftingtable.ipad"' \
  >"$runtime_log" 2>&1 &
log_stream_pid=$!
xcrun simctl launch --terminate-running-process "$device_udid" \
  com.local.draftingtable.ipad --renderer-self-test >/dev/null
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
  # The streaming capture misses instantly-aborting processes, so also read
  # the persisted log, which retains the dead process's messages including
  # Swift traps, NSExceptions, and Metal validation errors.
  echo "--- persisted log for DraftingTable (last 2m) ---" >&2
  xcrun simctl spawn "$device_udid" log show --last 2m --style compact \
    --predicate 'process == "DraftingTable"' 2>&1 | tail -n 200 >&2 || true
  # Launch breadcrumbs are written to the app's Caches directory at every
  # startup stage, so a fast abort still leaves the last completed stage.
  echo "--- app container breadcrumbs ---" >&2
  container="$(xcrun simctl get_app_container "$device_udid" com.local.draftingtable.ipad data 2>/dev/null || true)"
  if [[ -n "$container" ]]; then
    echo "data container: $container" >&2
    for crumb in "$container/Library/Caches/DraftingTable-launch-stages.log" \
                 "$container/Library/Caches/DraftingTable-last-launch.txt"; do
      if [[ -f "$crumb" ]]; then
        echo "--- $crumb ---" >&2
        cat "$crumb" >&2 || true
      else
        echo "--- missing: $crumb ---" >&2
      fi
    done
  else
    echo "no data container found" >&2
  fi
  latest_report="$(ls -1t "$HOME"/Library/Logs/DiagnosticReports/DraftingTable* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest_report" ]]; then
    echo "Latest host crash report: $latest_report" >&2
    tail -n 1200 "$latest_report" || true
  else
    echo "no host DiagnosticReports for DraftingTable" >&2
  fi
  simulator_report_dir="$HOME/Library/Developer/CoreSimulator/Devices/$device_udid/data/Library/Logs/CrashReporter"
  simulator_report="$(find "$simulator_report_dir" -type f -name 'DraftingTable*' -print 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "$simulator_report" ]]; then
    echo "Latest simulator crash report: $simulator_report" >&2
    cat "$simulator_report" || true
  else
    echo "no simulator CrashReporter file for DraftingTable" >&2
    ls -la "$simulator_report_dir" 2>/dev/null | tail -n 20 >&2 || true
  fi
  exit 1
fi

container="$(xcrun simctl get_app_container "$device_udid" com.local.draftingtable.ipad data)"
package="$container/Library/Application Support/DraftingTable/Preview.drafttable"
for _ in $(seq 1 40); do
  if [[ -s "$package/CURRENT" ]] && find "$package/tiles" -type f -name '*.dtile' -print -quit 2>/dev/null | grep -q .; then
    break
  fi
  sleep 0.5
done
test -s "$package/CURRENT" || {
  echo "Renderer self-test did not publish a package manifest" >&2
  tail -n 400 "$runtime_log" >&2 || true
  exit 1
}
tile_path="$(find "$package/tiles" -type f -name '*.dtile' -print -quit 2>/dev/null || true)"
test -n "$tile_path" || {
  echo "Renderer self-test produced no persisted tile" >&2
  tail -n 400 "$runtime_log" >&2 || true
  exit 1
}
python3 - "$tile_path" <<'PY'
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
header = 96
assert len(data) == header + 256 * 256 * 4, len(data)
alpha = data[header + 3::4]
assert any(alpha), "renderer checkpoint contains only transparent pixels"
print(f"Renderer self-test tile has {sum(value != 0 for value in alpha)} nonzero-alpha pixels")
PY

echo "Drafting Table simulator launch smoke test passed (pid $pid)"
