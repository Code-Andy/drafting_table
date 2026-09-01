#!/usr/bin/env bash
# Build the XcodeGen project for a generic iOS device without code signing,
# then validate and package the resulting app as an IPA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT/DraftingTable.xcodeproj}"
SCHEME="${SCHEME:-DraftingTable}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist/ios}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build/ios/DerivedData}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: Xcode project not found: $PROJECT_PATH" >&2
  echo "Run xcodegen generate from the repository root first." >&2
  exit 1
fi
command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: xcodebuild is required (run this script on macOS with Xcode installed)" >&2
  exit 1
}

PRODUCT_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA"

# Explicitly disable signing. DEVELOPMENT_TEAM is deliberately not supplied:
# no Apple account, certificate, or provisioning profile is needed in CI.
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$REPO_ROOT/build/ios/SourcePackages" \
  "CONFIGURATION_BUILD_DIR=$PRODUCT_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_PATH=""
APP_COUNT=0
while IFS= read -r candidate; do
  APP_PATH="$candidate"
  APP_COUNT=$((APP_COUNT + 1))
done < <(find "$PRODUCT_DIR" -maxdepth 1 -type d -name '*.app' -print)
if [[ "$APP_COUNT" -ne 1 ]]; then
  echo "error: expected exactly one .app in $PRODUCT_DIR, found $APP_COUNT" >&2
  [[ -n "$APP_PATH" ]] && printf '  %s\n' "$APP_PATH" >&2 || printf '  <none>\n' >&2
  exit 1
fi

IPA_PATH="$OUTPUT_DIR/DraftingTable.ipa"
"$SCRIPT_DIR/package_ipa.sh" "$APP_PATH" "$IPA_PATH"

echo "IPA ready: $IPA_PATH"
