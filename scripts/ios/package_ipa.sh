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
if [[ -z "$BUNDLE_ID" ]]; then
  echo "error: Info.plist has no CFBundleIdentifier" >&2
  exit 1
fi
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(basename "$APP_PATH" .app)"
fi

# A simulator bundle cannot be installed on an iPad. Check the executable's
# architectures when lipo is available; an absent executable is a hard error.
EXECUTABLE="$APP_PATH/$APP_NAME"
if [[ ! -f "$EXECUTABLE" ]]; then
  # CFBundleExecutable may differ from CFBundleName.
  EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
  [[ -n "$EXECUTABLE_NAME" ]] && EXECUTABLE="$APP_PATH/$EXECUTABLE_NAME"
fi
if [[ ! -f "$EXECUTABLE" ]]; then
  echo "error: app executable not found in bundle ($APP_NAME)" >&2
  exit 1
fi
if command -v lipo >/dev/null 2>&1; then
  ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
  if [[ -z "$ARCHS" ]]; then
    echo "error: unable to inspect app executable architectures (is this an iOS device build?)" >&2
    exit 1
  fi
  case " $ARCHS " in
    *" arm64 "*) : ;;
    *) echo "error: app executable is not arm64-capable: $ARCHS" >&2; exit 1 ;;
  esac
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

echo "Packaged unsigned $BUNDLE_ID ($APP_NAME) -> $IPA_DIR/$IPA_FILE"
