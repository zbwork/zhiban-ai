#!/bin/bash

set -euo pipefail

# CocoaPods already handles normal build signing. Sparkle's nested helpers need
# explicit distribution signing only while Xcode is producing an archive.
if [[ "${ACTION:-}" != "install" ]]; then
  exit 0
fi

readonly codesign_bin="/usr/bin/codesign"
readonly signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
readonly expected_team_id="${DEVELOPMENT_TEAM:-}"
readonly app_path="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${WRAPPER_NAME:?WRAPPER_NAME is required}"
readonly sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"

if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  echo "error: Sparkle distribution signing requires an explicit code-signing identity" >&2
  exit 1
fi
if [[ -z "$expected_team_id" ]]; then
  echo "error: Sparkle distribution signing requires DEVELOPMENT_TEAM" >&2
  exit 1
fi
if [[ ! -d "$sparkle_framework" || -L "$sparkle_framework" ]]; then
  echo "error: Sparkle framework is missing or is an unexpected symlink: $sparkle_framework" >&2
  exit 1
fi

readonly installer_xpc="$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
readonly downloader_xpc="$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
readonly autoupdate="$sparkle_framework/Versions/B/Autoupdate"
readonly updater_app="$sparkle_framework/Versions/B/Updater.app"

sign_target() {
  local target="$1"
  if [[ ! -e "$target" || -L "$target" ]]; then
    echo "error: Sparkle nested-code target is missing or is an unexpected symlink: $target" >&2
    exit 1
  fi

  "$codesign_bin" \
    --force \
    --sign "$signing_identity" \
    --options runtime \
    --timestamp \
    --preserve-metadata=identifier,entitlements \
    "$target"
}

verify_target() {
  local target="$1"
  local details

  "$codesign_bin" --verify --strict --verbose=2 "$target"
  details="$("$codesign_bin" -d --verbose=4 "$target" 2>&1)"

  if [[ "$details" != *"Authority=Developer ID Application:"* ]]; then
    echo "error: Sparkle target is not signed with Developer ID Application: $target" >&2
    exit 1
  fi
  if [[ "$details" != *"TeamIdentifier=$expected_team_id"* ]]; then
    echo "error: Sparkle target TeamIdentifier does not match $expected_team_id: $target" >&2
    exit 1
  fi
  if [[ "$details" != *"Runtime Version="* ]]; then
    echo "error: Sparkle target is missing Hardened Runtime: $target" >&2
    exit 1
  fi
  if [[ "$details" != *"Timestamp="* ]]; then
    echo "error: Sparkle target is missing a secure timestamp: $target" >&2
    exit 1
  fi
}

# Sparkle's documented order is inner services/helpers first, framework last.
sign_target "$installer_xpc"
sign_target "$downloader_xpc"
sign_target "$autoupdate"
sign_target "$updater_app"
sign_target "$sparkle_framework"

verify_target "$installer_xpc"
verify_target "$downloader_xpc"
verify_target "$autoupdate"
verify_target "$updater_app"
verify_target "$sparkle_framework"

echo "Sparkle nested code signed for Developer ID distribution"
