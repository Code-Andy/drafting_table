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
SOURCE_SHA="${SOURCE_SHA:-${GITHUB_SHA:-local}}"

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

# Resolve the values Xcode actually used from the generated project. This
# keeps the package checks tied to project.yml without duplicating YAML
# parsing in this shell script.
BUILD_SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/drafting-table-build-settings.XXXXXX")"
cleanup_build_settings() { rm -f "$BUILD_SETTINGS_FILE"; }
trap cleanup_build_settings EXIT
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -showBuildSettings > "$BUILD_SETTINGS_FILE"

build_setting() {
  local key="$1"
  sed -n "s/^[[:space:]]*${key} = //p" "$BUILD_SETTINGS_FILE" | head -n 1
}

EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-$(build_setting PRODUCT_BUNDLE_IDENTIFIER)}"
EXPECTED_MARKETING_VERSION="${EXPECTED_MARKETING_VERSION:-$(build_setting MARKETING_VERSION)}"
EXPECTED_BUILD_VERSION="${EXPECTED_BUILD_VERSION:-$(build_setting CURRENT_PROJECT_VERSION)}"
EXPECTED_MIN_OS="${EXPECTED_MIN_OS:-$(build_setting IPHONEOS_DEPLOYMENT_TARGET)}"

for required_setting in EXPECTED_BUNDLE_ID EXPECTED_MARKETING_VERSION EXPECTED_BUILD_VERSION EXPECTED_MIN_OS; do
  if [[ -z "${!required_setting}" ]]; then
    echo "error: unable to resolve ${required_setting} from Xcode build settings" >&2
    exit 1
  fi
done

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
EXPECTED_BUNDLE_ID="$EXPECTED_BUNDLE_ID" \
EXPECTED_MARKETING_VERSION="$EXPECTED_MARKETING_VERSION" \
EXPECTED_BUILD_VERSION="$EXPECTED_BUILD_VERSION" \
EXPECTED_MIN_OS="$EXPECTED_MIN_OS" \
"$SCRIPT_DIR/package_ipa.sh" "$APP_PATH" "$IPA_PATH"

IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
cat > "$OUTPUT_DIR/build-metadata.txt" <<EOF
source_sha=$SOURCE_SHA
bundle_id=$EXPECTED_BUNDLE_ID
marketing_version=$EXPECTED_MARKETING_VERSION
build_version=$EXPECTED_BUILD_VERSION
minimum_os_version=$EXPECTED_MIN_OS
ipa_sha256=$IPA_SHA256
app_bundle=$(basename "$APP_PATH")
EOF

echo "IPA ready: $IPA_PATH"
echo "Build metadata: $OUTPUT_DIR/build-metadata.txt"
