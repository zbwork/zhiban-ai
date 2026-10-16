#!/bin/bash

set -euo pipefail

readonly helper_identifier="cn.qkfintech.zhiban.local-bridge"
readonly helper_bundle_name="ZhibanLocalBridge.app"
readonly helper_executable_name="zhiban-local-bridge"
readonly expected_team_id="NUHSLZ4RU4"

fail() {
  echo "error: local coding bridge: $1" >&2
  exit 1
}

require_absolute_path() {
  local value="$1"
  local label="$2"
  [[ "$value" == /* ]] || fail "$label must be an absolute path"
}

remove_helper_bundle() {
  local path="$1"
  case "$path" in
    "$canonical_target_build_dir"/*/Contents/Helpers/"$helper_bundle_name")
      /bin/rm -rf -- "$path"
      ;;
    *)
      fail "refusing to remove an unexpected output path"
      ;;
  esac
}

find_go() {
  if [[ -n "${GO_BIN:-}" && -x "$GO_BIN" ]]; then
    printf '%s\n' "$GO_BIN"
    return
  fi
  local candidate
  for candidate in /opt/homebrew/bin/go /usr/local/bin/go; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  candidate="$(command -v go || true)"
  [[ -n "$candidate" && -x "$candidate" ]] || fail "Go toolchain was not found"
  printf '%s\n' "$candidate"
}

[[ -n "${PROJECT_DIR:-}" ]] || fail "PROJECT_DIR is required"
[[ -n "${TARGET_BUILD_DIR:-}" ]] || fail "TARGET_BUILD_DIR is required"
[[ -n "${CONTENTS_FOLDER_PATH:-}" ]] || fail "CONTENTS_FOLDER_PATH is required"
require_absolute_path "$PROJECT_DIR" "PROJECT_DIR"
require_absolute_path "$TARGET_BUILD_DIR" "TARGET_BUILD_DIR"
[[ "$CONTENTS_FOLDER_PATH" =~ ^[^/]+[.]app/Contents$ ]] || fail "CONTENTS_FOLDER_PATH is invalid"
/bin/mkdir -p "$TARGET_BUILD_DIR"
readonly canonical_target_build_dir="$(cd "$TARGET_BUILD_DIR" && pwd -P)"
readonly product_bundle_name="${CONTENTS_FOLDER_PATH%/Contents}"

readonly product_bundle="$canonical_target_build_dir/$product_bundle_name"
readonly product_contents="$product_bundle/Contents"
readonly helpers_directory="$product_contents/Helpers"
readonly helper_bundle="$helpers_directory/$helper_bundle_name"
readonly helper_contents="$helper_bundle/Contents"
readonly helper_executable="$helper_contents/MacOS/$helper_executable_name"

validate_output_ancestry() {
  local component
  for component in "$product_bundle" "$product_contents" "$helpers_directory" "$helper_bundle"; do
    [[ ! -L "$component" ]] || fail "output path contains a symbolic link"
  done
}

validate_output_ancestry

if [[ "${LOCAL_CODING_BRIDGE_EMBED:-NO}" != "YES" ]]; then
  if [[ -e "$helper_bundle" || -L "$helper_bundle" ]]; then
    remove_helper_bundle "$helper_bundle"
  fi
  echo "local coding bridge: embedding disabled for ${CONFIGURATION:-unknown}"
  exit 0
fi

readonly signing_mode="${LOCAL_CODING_BRIDGE_SIGNING_MODE:-adhoc}"
case "${CONFIGURATION:-}" in
  Release|Profile)
    [[ "$signing_mode" == "distribution" ]] || fail "release-like builds require distribution signing"
    ;;
esac
case "$signing_mode" in
  adhoc)
    ;;
  distribution)
    effective_sign_identity="${LOCAL_CODING_BRIDGE_SIGN_IDENTITY:-}"
    [[ -n "$effective_sign_identity" ]] || fail "distribution signing identity is required"
    [[ -n "${LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE:-}" ]] || fail "distribution provisioning profile is required"
    [[ -f "$LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE" ]] || fail "distribution provisioning profile was not found"
    [[ -n "${LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX:-}" ]] || fail "App Identifier Prefix is required"
    [[ "$LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX" =~ ^[A-Z0-9]+\.$ ]] || fail "App Identifier Prefix is invalid"
    ;;
  *)
    fail "unsupported signing mode"
    ;;
esac

requested_archs="${ARCHS:-${CURRENT_ARCH:-}}"
[[ -n "$requested_archs" ]] || fail "ARCHS is required"

declare -a xcode_archs=()
for requested_arch in $requested_archs; do
  case "$requested_arch" in
    arm64|x86_64)
      ;;
    *)
      fail "unsupported architecture $requested_arch"
      ;;
  esac
  already_present="NO"
  for existing_arch in "${xcode_archs[@]:-}"; do
    if [[ "$existing_arch" == "$requested_arch" ]]; then
      already_present="YES"
      break
    fi
  done
  if [[ "$already_present" == "NO" ]]; then
    xcode_archs+=("$requested_arch")
  fi
done
[[ "${#xcode_archs[@]}" -gt 0 ]] || fail "no supported architecture was requested"

readonly deployment_target="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
readonly marketing_version="${MARKETING_VERSION:-${FLUTTER_BUILD_NAME:-0.0.0}}"
readonly build_version="${CURRENT_PROJECT_VERSION:-${FLUTTER_BUILD_NUMBER:-1}}"
[[ "$deployment_target" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || fail "deployment target is invalid"
[[ "$marketing_version" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]] || fail "marketing version is invalid"
[[ "$build_version" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]] || fail "build version is invalid"

readonly bridge_root="$PROJECT_DIR/../../zhiban-local-bridge"
readonly bridge_main="$bridge_root/cmd/zhiban-local-bridge"
readonly info_template="$PROJECT_DIR/LocalCodingBridge/Info.plist"
readonly entitlements_template="$PROJECT_DIR/LocalCodingBridge/Distribution.entitlements"
[[ -f "$bridge_root/go.mod" && -d "$bridge_main" ]] || fail "Bridge source tree was not found"
[[ -f "$info_template" ]] || fail "helper Info.plist template was not found"
[[ -f "$entitlements_template" ]] || fail "helper entitlements template was not found"

readonly go_bin="$(find_go)"
[[ -n "${HOME:-}" && "$HOME" == /* ]] || fail "HOME must be an absolute path for the Go build cache"
# Go invalidates cached compilation when source, flags, or the toolchain change.
# cgo does not notice external SDK changes, so use a new cache for each Xcode version.
readonly xcode_cache_key="$(/usr/bin/xcodebuild -version | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16)"
[[ "$xcode_cache_key" =~ ^[0-9a-f]{16}$ ]] || fail "could not identify the Xcode build cache version"
readonly go_build_cache="$HOME/Library/Caches/zhiban-local-bridge/go-build-$xcode_cache_key"
/bin/mkdir -p "$go_build_cache"
/bin/chmod 700 "$go_build_cache"
readonly work_parent="${DERIVED_FILE_DIR:-$TARGET_BUILD_DIR/.zhiban-local-bridge-derived}"
require_absolute_path "$work_parent" "Bridge derived directory"
/bin/mkdir -p "$work_parent"
readonly work_dir="$(mktemp -d "$work_parent/build.XXXXXX")"
/bin/mkdir -p "$work_dir/home" "$work_dir/tmp" "$work_dir/go-mod-cache"

go_environment=(
  /usr/bin/env -i
  "PATH=$(/usr/bin/dirname "$go_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
  "HOME=$work_dir/home"
  "TMPDIR=$work_dir/tmp"
  "GOCACHE=$go_build_cache"
  "GOMODCACHE=$work_dir/go-mod-cache"
  "GOENV=off"
  "GOFLAGS="
  "GOPROXY=off"
  "GOSUMDB=off"
  "GOTOOLCHAIN=local"
  "GOVCS=*:off"
  "GOWORK=off"
  "CC=/usr/bin/clang"
)
if [[ -n "${SDKROOT:-}" ]]; then
  require_absolute_path "$SDKROOT" "SDKROOT"
  go_environment+=("SDKROOT=$SDKROOT")
fi

cleanup_work_dir() {
  case "$work_dir" in
    "$work_parent"/build.*)
      /bin/rm -rf -- "$work_dir"
      ;;
    *)
      fail "refusing to clean an unexpected work path"
      ;;
  esac
}
trap cleanup_work_dir EXIT

declare -a slices=()
for xcode_arch in "${xcode_archs[@]}"; do
  case "$xcode_arch" in
    arm64)
      go_arch="arm64"
      ;;
    x86_64)
      go_arch="amd64"
      ;;
  esac
  slice="$work_dir/$helper_executable_name-$xcode_arch"
  echo "local coding bridge: building $xcode_arch"
  (
    cd "$bridge_root"
    "${go_environment[@]}" \
      GOOS=darwin \
      GOARCH="$go_arch" \
      CGO_ENABLED=1 \
      MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
      CGO_CFLAGS="-mmacosx-version-min=$deployment_target" \
      CGO_LDFLAGS="-mmacosx-version-min=$deployment_target" \
      "$go_bin" build \
        -trimpath \
        -buildvcs=false \
        -mod=vendor \
        -ldflags "-X main.bridgeVersion=$marketing_version" \
        -o "$slice" \
        ./cmd/zhiban-local-bridge
  )
  built_archs="$(/usr/bin/lipo -archs "$slice")"
  [[ " $built_archs " == *" $xcode_arch "* ]] || fail "built slice does not match $xcode_arch"
  slices+=("$slice")
done

unsigned_executable="$work_dir/$helper_executable_name"
if [[ "${#slices[@]}" -eq 1 ]]; then
  /usr/bin/ditto "${slices[0]}" "$unsigned_executable"
else
  /usr/bin/lipo -create "${slices[@]}" -output "$unsigned_executable"
fi

validate_output_ancestry
if [[ -e "$helper_bundle" || -L "$helper_bundle" ]]; then
  remove_helper_bundle "$helper_bundle"
fi
/bin/mkdir -p "$helper_contents/MacOS"
/usr/bin/ditto "$info_template" "$helper_contents/Info.plist"
/usr/bin/ditto "$unsigned_executable" "$helper_executable"
/bin/chmod 0755 "$helper_executable"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$helper_contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$helper_contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $deployment_target" "$helper_contents/Info.plist"
/usr/bin/plutil -lint "$helper_contents/Info.plist" >/dev/null

if [[ "$signing_mode" == "adhoc" ]]; then
  /usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --identifier "$helper_identifier" \
    "$helper_bundle"
else
  readonly profile_plist="$work_dir/profile.plist"
  readonly derived_entitlements="$work_dir/Distribution.entitlements"
  /usr/bin/security cms -D -i "$LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE" >"$profile_plist"

  readonly expected_application_identifier="${LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX}${helper_identifier}"
  profile_expiration="$(/usr/bin/plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null || true)"
  profile_expiration_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" '+%s' 2>/dev/null || true)"
  [[ "$profile_expiration_epoch" =~ ^[0-9]+$ ]] || fail "provisioning profile expiration is invalid"
  [[ "$profile_expiration_epoch" -gt "$(/bin/date -u '+%s')" ]] || fail "provisioning profile is expired"

  profile_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_application_identifier" == "$expected_application_identifier" ]] || fail "provisioning profile does not authorize the helper App ID"

  profile_team_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_team_id" == "$expected_team_id" ]] || fail "provisioning profile Team ID does not match"

  readonly expected_keychain_group_wildcard="${LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX}*"
  profile_keychain_group_count="$(/usr/bin/plutil -extract Entitlements.keychain-access-groups raw -o - "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_keychain_group_count" =~ ^[0-9]+$ ]] || fail "provisioning profile has no Keychain groups"
  profile_has_expected_keychain_group="NO"
  for ((group_index = 0; group_index < profile_keychain_group_count; group_index++)); do
    profile_keychain_group="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups:$group_index" "$profile_plist" 2>/dev/null || true)"
    if [[ "$profile_keychain_group" == "$expected_application_identifier" || "$profile_keychain_group" == "$expected_keychain_group_wildcard" ]]; then
      profile_has_expected_keychain_group="YES"
      break
    fi
  done
  [[ "$profile_has_expected_keychain_group" == "YES" ]] || fail "provisioning profile does not authorize the helper Keychain group"

  /usr/bin/profiles validate \
    -type provisioning \
    -path "$LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE" \
    >/dev/null 2>&1 || fail "provisioning profile is not Apple-authorized"

  /usr/bin/ditto "$LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE" "$helper_contents/embedded.provisionprofile"
  /usr/bin/ditto "$entitlements_template" "$derived_entitlements"
  /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier $expected_application_identifier" "$derived_entitlements"
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $expected_team_id" "$derived_entitlements"
  /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $expected_application_identifier" "$derived_entitlements"
  /usr/bin/plutil -lint "$derived_entitlements" >/dev/null

  /usr/bin/codesign \
    --force \
    --sign "$effective_sign_identity" \
    --timestamp \
    --options runtime \
    --entitlements "$derived_entitlements" \
    "$helper_bundle"

  readonly release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team_id\" and identifier \"$helper_identifier\""
  /usr/bin/codesign --verify --strict --test-requirement "=$release_requirement" "$helper_executable"

  readonly signer_certificate_prefix="$work_dir/signer-certificate-"
  /usr/bin/codesign -d --extract-certificates="$signer_certificate_prefix" "$helper_bundle"
  readonly signer_leaf_certificate="${signer_certificate_prefix}0"
  [[ -f "$signer_leaf_certificate" ]] || fail "signed helper leaf certificate was not found"
  profile_certificate_count="$(/usr/bin/plutil -extract DeveloperCertificates raw -o - "$profile_plist" 2>/dev/null || true)"
  [[ "$profile_certificate_count" =~ ^[0-9]+$ && "$profile_certificate_count" -gt 0 ]] || fail "provisioning profile has no signing certificates"
  signer_is_authorized="NO"
  for ((certificate_index = 0; certificate_index < profile_certificate_count; certificate_index++)); do
    profile_certificate="$work_dir/profile-certificate-$certificate_index.der"
    /usr/bin/plutil -extract "DeveloperCertificates.$certificate_index" raw -o - "$profile_plist" | /usr/bin/base64 -D >"$profile_certificate"
    if /usr/bin/cmp -s "$profile_certificate" "$signer_leaf_certificate"; then
      signer_is_authorized="YES"
      break
    fi
  done
  [[ "$signer_is_authorized" == "YES" ]] || fail "signing certificate is not authorized by the provisioning profile"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$helper_bundle"
echo "local coding bridge: embedded $helper_bundle"
