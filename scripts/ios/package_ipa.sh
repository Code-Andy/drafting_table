#!/usr/bin/env bash
# Validate an unsigned iOS .app and package it as a conventional IPA.
#
# Usage:
#   package_ipa.sh <app-path> <ipa-path>
#
# The resulting archive intentionally has no signing data. SideStore/AltStore
# (or another signer) can sign the IPA on the target device later.
set -euo pipefail

usage() {
  echo "Usage: $0 <DraftingTable.app> <DraftingTable.ipa>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
APP_PATH="$1"
IPA_PATH="$2"

# These are supplied by build_ipa.sh from the generated Xcode build settings.
# Direct callers can leave them unset to validate presence/type only.
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-}"
EXPECTED_MARKETING_VERSION="${EXPECTED_MARKETING_VERSION:-}"
EXPECTED_BUILD_VERSION="${EXPECTED_BUILD_VERSION:-}"
EXPECTED_MIN_OS="${EXPECTED_MIN_OS:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle does not exist: $APP_PATH" >&2
  exit 1
fi

PLIST="$APP_PATH/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "error: app bundle has no Info.plist: $PLIST" >&2
  exit 1
fi

if ! command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  echo "error: /usr/libexec/PlistBuddy is required on macOS" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST" 2>/dev/null || true)"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
MIN_OS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST" 2>/dev/null || true)"
if [[ -z "$BUNDLE_ID" ]]; then
  echo "error: Info.plist has no CFBundleIdentifier" >&2
  exit 1
fi
if [[ -z "$SHORT_VERSION" ]]; then
  echo "error: Info.plist has no CFBundleShortVersionString" >&2
  exit 1
fi
if [[ -z "$BUILD_VERSION" ]]; then
  echo "error: Info.plist has no CFBundleVersion" >&2
  exit 1
fi
if [[ -z "$MIN_OS_VERSION" ]]; then
  echo "error: Info.plist has no MinimumOSVersion (device deployment target)" >&2
  exit 1
fi
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(basename "$APP_PATH" .app)"
fi

assert_matches() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "error: $label mismatch (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

assert_matches "CFBundleIdentifier" "$BUNDLE_ID" "$EXPECTED_BUNDLE_ID"
assert_matches "CFBundleShortVersionString" "$SHORT_VERSION" "$EXPECTED_MARKETING_VERSION"
assert_matches "CFBundleVersion" "$BUILD_VERSION" "$EXPECTED_BUILD_VERSION"
assert_matches "MinimumOSVersion" "$MIN_OS_VERSION" "$EXPECTED_MIN_OS"

# A simulator bundle cannot be installed on an iPad. The architecture check is
# mandatory on the macOS build host; an absent executable is a hard error.
EXECUTABLE="$APP_PATH/$APP_NAME"
if [[ -n "$EXECUTABLE_NAME" ]]; then
  EXECUTABLE="$APP_PATH/$EXECUTABLE_NAME"
fi
if [[ ! -f "$EXECUTABLE" ]]; then
  echo "error: app executable not found in bundle ($EXECUTABLE_NAME)" >&2
  exit 1
fi
if [[ -z "$EXECUTABLE_NAME" ]]; then
  echo "error: Info.plist has no CFBundleExecutable" >&2
  exit 1
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "error: lipo is required to validate an arm64 device executable" >&2
  exit 1
fi
ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
if [[ -z "$ARCHS" ]]; then
  echo "error: unable to inspect app executable architectures (is this an iOS device build?)" >&2
  exit 1
fi
case " $ARCHS " in
  *" arm64 "*) : ;;
  *) echo "error: app executable is not arm64-capable: $ARCHS" >&2; exit 1 ;;
esac

# The renderer loads the default Metal library at runtime. A device app with
# no compiled .metallib is incomplete even if the executable itself is valid.
METALLIB_PATH="$APP_PATH/default.metallib"
if [[ ! -s "$METALLIB_PATH" ]]; then
  echo "error: compiled Metal library missing or empty: $METALLIB_PATH" >&2
  exit 1
fi

# CODE_SIGNING_ALLOWED=NO must produce a genuinely unsigned bundle so that
# SideStore/AltStore can apply the user's signature later. Check both marker
# files and codesign's own inspection (nested signed payloads are rejected).
if find "$APP_PATH" -type d -name '_CodeSignature' -print -quit | grep -q .; then
  echo "error: signed bundle contains _CodeSignature" >&2
  exit 1
fi
if find "$APP_PATH" -type f \( -name 'embedded.mobileprovision' -o -name 'CodeResources' \) -print -quit | grep -q .; then
  echo "error: signed bundle contains provisioning/signature resources" >&2
  exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required to validate unsigned output" >&2
  exit 1
fi
set +e
CODESIGN_OUTPUT="$(codesign -dvv "$APP_PATH" 2>&1)"
CODESIGN_STATUS=$?
set -e
if [[ "$CODESIGN_STATUS" -eq 0 ]]; then
  echo "error: app bundle is code signed; expected unsigned output" >&2
  echo "$CODESIGN_OUTPUT" >&2
  exit 1
fi
if ! grep -Eqi 'code object is not signed at all|code object is not signed' <<< "$CODESIGN_OUTPUT"; then
  echo "error: codesign could not establish that the app is unsigned" >&2
  echo "$CODESIGN_OUTPUT" >&2
  exit 1
fi

IPA_DIR="$(cd "$(dirname "$IPA_PATH")" && pwd)"
IPA_FILE="$(basename "$IPA_PATH")"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drafting-table-ipa.XXXXXX")"
cleanup() { rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

mkdir -p "$STAGE_DIR/Payload"
# ditto preserves symlinks and bundle metadata better than a plain cp.
ditto "$APP_PATH" "$STAGE_DIR/Payload/$(basename "$APP_PATH")"

mkdir -p "$IPA_DIR"
rm -f "$IPA_DIR/$IPA_FILE"
(cd "$STAGE_DIR" && /usr/bin/zip -qry "$IPA_DIR/$IPA_FILE" Payload)

if [[ ! -s "$IPA_DIR/$IPA_FILE" ]]; then
  echo "error: failed to create IPA: $IPA_DIR/$IPA_FILE" >&2
  exit 1
fi

# Validate the archive itself, not only the pre-zip source bundle. This keeps
# future packaging changes from silently omitting the executable or library.
if ! command -v unzip >/dev/null 2>&1; then
  echo "error: unzip is required to inspect the generated IPA" >&2
  exit 1
fi
APP_ARCHIVE_PREFIX="Payload/$(basename "$APP_PATH")/"
ARCHIVE_LIST="$(unzip -Z1 "$IPA_DIR/$IPA_FILE")"
grep -Fxq "${APP_ARCHIVE_PREFIX}Info.plist" <<< "$ARCHIVE_LIST" || {
  echo "error: IPA is missing ${APP_ARCHIVE_PREFIX}Info.plist" >&2
  exit 1
}
grep -Fxq "${APP_ARCHIVE_PREFIX}${EXECUTABLE_NAME}" <<< "$ARCHIVE_LIST" || {
  echo "error: IPA is missing ${APP_ARCHIVE_PREFIX}${EXECUTABLE_NAME}" >&2
  exit 1
}
grep -Fxq "${APP_ARCHIVE_PREFIX}default.metallib" <<< "$ARCHIVE_LIST" || {
  echo "error: IPA is missing ${APP_ARCHIVE_PREFIX}default.metallib" >&2
  exit 1
}
if grep -Eq '^Payload/[^/]+\.app/(_CodeSignature/|embedded\.mobileprovision$)' <<< "$ARCHIVE_LIST"; then
  echo "error: IPA contains code-signing payload data" >&2
  exit 1
fi
unzip -tq "$IPA_DIR/$IPA_FILE" >/dev/null

echo "Packaged unsigned $BUNDLE_ID $SHORT_VERSION ($APP_NAME) -> $IPA_DIR/$IPA_FILE"
