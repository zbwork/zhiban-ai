#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_script="$script_dir/build_and_embed.sh"
runtime_verifier_source="$script_dir/../../lib/pages/local_coding_tools/services/local_coding_bridge_client.dart"
test_root="$(mktemp -d /tmp/zhiban-local-bridge-packaging-test.XXXXXX)"
cache_home="$test_root/home"
/bin/mkdir -p "$cache_home"

cleanup() {
  case "$test_root" in
    /tmp/zhiban-local-bridge-packaging-test.*)
      /bin/rm -rf -- "$test_root"
      ;;
    *)
      echo "refusing to clean unexpected test path" >&2
      exit 1
      ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_build() {
  env \
    HOME="$cache_home" \
    PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
    TARGET_BUILD_DIR="$test_root/Products" \
    CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
    ARCHS="arm64 x86_64" \
    CONFIGURATION="Debug" \
    MACOSX_DEPLOYMENT_TARGET="11.0" \
    CURRENT_PROJECT_VERSION="10001" \
    MARKETING_VERSION="1.2.3" \
    LOCAL_CODING_BRIDGE_EMBED="YES" \
    LOCAL_CODING_BRIDGE_SIGNING_MODE="adhoc" \
    "$build_script"
}

[[ -x "$build_script" ]] || fail "build_and_embed.sh is missing or not executable"
[[ -f "$runtime_verifier_source" ]] || fail "runtime signature verifier source is missing"

run_build

cache_key="$(/usr/bin/xcodebuild -version | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16)"
cache_dir="$cache_home/Library/Caches/zhiban-local-bridge/go-build-$cache_key"
[[ -d "$cache_dir" ]] || fail "persistent Go build cache was not created"
/usr/bin/touch "$cache_dir/cache-survives-build"
run_build
[[ -f "$cache_dir/cache-survives-build" ]] || fail "Go build cache was removed between builds"

helper_bundle="$test_root/Products/ZhibanTest.app/Contents/Helpers/ZhibanLocalBridge.app"
helper_executable="$helper_bundle/Contents/MacOS/zhiban-local-bridge"

[[ -d "$helper_bundle" ]] || fail "helper app wrapper was not created"
[[ -x "$helper_executable" ]] || fail "helper main executable is missing"
[[ ! -e "$helper_bundle/Contents/embedded.provisionprofile" ]] || fail "ad-hoc build must not embed a provisioning profile"

identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper_bundle/Contents/Info.plist")"
[[ "$identifier" == "cn.qkfintech.zhiban.local-bridge" ]] || fail "unexpected bundle identifier"

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper_bundle/Contents/Info.plist")"
[[ "$executable_name" == "zhiban-local-bridge" ]] || fail "unexpected bundle executable"

architectures="$(/usr/bin/lipo -archs "$helper_executable")"
[[ " $architectures " == *" arm64 "* ]] || fail "arm64 slice is missing"
[[ " $architectures " == *" x86_64 "* ]] || fail "x86_64 slice is missing"
minimum_version_count="$(/usr/bin/vtool -show-build "$helper_executable" | /usr/bin/grep -c 'minos 11.0')"
[[ "$minimum_version_count" -eq 2 ]] || fail "one or more slices have the wrong deployment target"

/usr/bin/codesign --verify --strict --verbose=2 "$helper_bundle"
signature_details="$(/usr/bin/codesign -d --verbose=4 "$helper_bundle" 2>&1)"
[[ "$signature_details" == *"Identifier=cn.qkfintech.zhiban.local-bridge"* ]] || fail "signature identifier is missing"
[[ "$signature_details" == *"runtime"* ]] || fail "Hardened Runtime flag is missing"
[[ "$signature_details" == *"TeamIdentifier=not set"* ]] || fail "ad-hoc build must not claim a Team ID"

if /usr/bin/grep -q '=designated =>' "$build_script" "$runtime_verifier_source"; then
  fail "external test requirement uses internal requirement-set syntax in packaging or runtime verification"
fi
if /usr/bin/grep -q -- '--extract-certificates "$signer_certificate_prefix"' "$build_script"; then
  fail "certificate extraction prefix is passed as a code path"
fi
release_requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "NUHSLZ4RU4" and identifier "cn.qkfintech.zhiban.local-bridge"'
release_requirement_output="$test_root/release-requirement-output.txt"
if /usr/bin/codesign --verify --strict --test-requirement "=$release_requirement" "$helper_executable" >"$release_requirement_output" 2>&1; then
  fail "ad-hoc helper unexpectedly satisfied the Developer ID requirement"
fi
if /usr/bin/grep -Eq 'Requirement syntax error|invalid requirement specification|No such file or directory' "$release_requirement_output"; then
  fail "Developer ID test requirement has invalid syntax"
fi
system_certificate_prefix="$test_root/system-certificate-"
/usr/bin/codesign -d --extract-certificates="$system_certificate_prefix" /bin/ls >/dev/null 2>&1
[[ -f "${system_certificate_prefix}0" ]] || fail "certificate extraction did not produce a leaf certificate"

initialize_response="$({
  printf '%s\n' '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocol_version":"1.0","app_version":"1.0.0","platform":"macos","arch":"arm64","locale":"zh-CN"}}'
} | "$helper_executable" | /usr/bin/head -n 1)"
[[ "$initialize_response" == *'"protocol_version":"1.0"'* ]] || fail "stdio initialize smoke failed"

env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/Products" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  CONFIGURATION="Release" \
  LOCAL_CODING_BRIDGE_EMBED="NO" \
  "$build_script"
[[ ! -e "$helper_bundle" ]] || fail "disabled embedding left a stale helper bundle"

if env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/Unsupported" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  ARCHS="i386" \
  CONFIGURATION="Debug" \
  MACOSX_DEPLOYMENT_TARGET="11.0" \
  CURRENT_PROJECT_VERSION="10001" \
  MARKETING_VERSION="1.2.3" \
  LOCAL_CODING_BRIDGE_EMBED="YES" \
  LOCAL_CODING_BRIDGE_SIGNING_MODE="adhoc" \
  "$build_script"; then
  fail "unsupported architecture unexpectedly succeeded"
fi

if env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/Distribution" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  ARCHS="arm64" \
  CONFIGURATION="Release" \
  MACOSX_DEPLOYMENT_TARGET="11.0" \
  CURRENT_PROJECT_VERSION="10001" \
  MARKETING_VERSION="1.2.3" \
  LOCAL_CODING_BRIDGE_EMBED="YES" \
  LOCAL_CODING_BRIDGE_SIGNING_MODE="distribution" \
  "$build_script"; then
  fail "distribution build without signing inputs unexpectedly succeeded"
fi

if env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/ReleaseAdHoc" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  ARCHS="arm64" \
  CONFIGURATION="Release" \
  MACOSX_DEPLOYMENT_TARGET="11.0" \
  CURRENT_PROJECT_VERSION="10001" \
  MARKETING_VERSION="1.2.3" \
  LOCAL_CODING_BRIDGE_EMBED="YES" \
  LOCAL_CODING_BRIDGE_SIGNING_MODE="adhoc" \
  "$build_script"; then
  fail "release build unexpectedly allowed ad-hoc signing"
fi

inherited_env_target="$test_root/InheritedEnvironment"
env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$inherited_env_target" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  ARCHS="arm64" \
  CONFIGURATION="Debug" \
  MACOSX_DEPLOYMENT_TARGET="11.0" \
  CURRENT_PROJECT_VERSION="10001" \
  MARKETING_VERSION="1.2.3" \
  LOCAL_CODING_BRIDGE_EMBED="YES" \
  LOCAL_CODING_BRIDGE_SIGNING_MODE="adhoc" \
  GOTOOLCHAIN="invalid-auto-toolchain" \
  GOPROXY="https://invalid.example" \
  GOWORK="$test_root/hostile.work" \
  GOFLAGS="-definitely-invalid-go-flag" \
  "$build_script"
[[ -x "$inherited_env_target/ZhibanTest.app/Contents/Helpers/ZhibanLocalBridge.app/Contents/MacOS/zhiban-local-bridge" ]] || fail "sanitized Go build did not produce a helper"

escaped_helpers="$test_root/EscapedHelpers"
escaped_product="$test_root/SymlinkProducts/ZhibanTest.app/Contents"
/bin/mkdir -p "$escaped_helpers/ZhibanLocalBridge.app" "$escaped_product"
/usr/bin/touch "$escaped_helpers/ZhibanLocalBridge.app/must-survive"
/bin/ln -s "$escaped_helpers" "$escaped_product/Helpers"
if env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/SymlinkProducts" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  CONFIGURATION="Release" \
  LOCAL_CODING_BRIDGE_EMBED="NO" \
  "$build_script"; then
  fail "symlinked output ancestry unexpectedly succeeded"
fi
[[ -e "$escaped_helpers/ZhibanLocalBridge.app/must-survive" ]] || fail "symlinked output ancestry deleted an external helper"

fake_profile="$test_root/fake.provisionprofile"
/usr/bin/touch "$fake_profile"
missing_identity_output="$test_root/missing-identity-output.txt"
if env \
  PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
  TARGET_BUILD_DIR="$test_root/InheritedIdentity" \
  CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
  ARCHS="arm64" \
  CONFIGURATION="Release" \
  LOCAL_CODING_BRIDGE_EMBED="YES" \
  LOCAL_CODING_BRIDGE_SIGNING_MODE="distribution" \
  EXPANDED_CODE_SIGN_IDENTITY="-" \
  LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE="$fake_profile" \
  LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX="NUHSLZ4RU4." \
  "$build_script" >"$missing_identity_output" 2>&1; then
  fail "distribution build inherited the outer signing identity"
fi
/usr/bin/grep -q 'distribution signing identity is required' "$missing_identity_output" || fail "missing explicit helper identity failed for the wrong reason"

profile_signing_key="$test_root/profile-signing-key.pem"
profile_signing_certificate="$test_root/profile-signing-certificate.pem"
/usr/bin/openssl req \
  -new \
  -x509 \
  -nodes \
  -newkey rsa:2048 \
  -subj '/CN=Zhiban Packaging Test/' \
  -keyout "$profile_signing_key" \
  -out "$profile_signing_certificate" \
  -days 1 \
  >/dev/null 2>&1

make_cms_profile() {
  local payload="$1"
  local output="$2"
  /usr/bin/openssl smime \
    -sign \
    -binary \
    -nodetach \
    -in "$payload" \
    -signer "$profile_signing_certificate" \
    -inkey "$profile_signing_key" \
    -outform der \
    -out "$output"
}

run_distribution_failure() {
  local profile="$1"
  local output="$2"
  env \
    PROJECT_DIR="$(cd "$script_dir/.." && pwd)" \
    TARGET_BUILD_DIR="$test_root/ProfileValidation" \
    CONTENTS_FOLDER_PATH="ZhibanTest.app/Contents" \
    ARCHS="arm64" \
    CONFIGURATION="Release" \
    MACOSX_DEPLOYMENT_TARGET="11.0" \
    CURRENT_PROJECT_VERSION="10001" \
    MARKETING_VERSION="1.2.3" \
    LOCAL_CODING_BRIDGE_EMBED="YES" \
    LOCAL_CODING_BRIDGE_SIGNING_MODE="distribution" \
    LOCAL_CODING_BRIDGE_SIGN_IDENTITY="nonexistent-test-identity" \
    LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE="$profile" \
    LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX="NUHSLZ4RU4." \
    "$build_script" >"$output" 2>&1
}

expired_profile_payload="$test_root/expired-profile.plist"
expired_profile="$test_root/expired.provisionprofile"
/usr/bin/ditto "$script_dir/testdata/Profile.plist" "$expired_profile_payload"
/usr/bin/plutil -replace ExpirationDate -date '2020-01-01T00:00:00Z' "$expired_profile_payload"
make_cms_profile "$expired_profile_payload" "$expired_profile"
expired_profile_output="$test_root/expired-profile-output.txt"
if run_distribution_failure "$expired_profile" "$expired_profile_output"; then
  fail "expired provisioning profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'provisioning profile is expired' "$expired_profile_output" || fail "expired profile failed for the wrong reason"

wrong_group_profile_payload="$test_root/wrong-group-profile.plist"
wrong_group_profile="$test_root/wrong-group.provisionprofile"
/usr/bin/ditto "$script_dir/testdata/Profile.plist" "$wrong_group_profile_payload"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:keychain-access-groups:0 NUHSLZ4RU4.wrong-group' "$wrong_group_profile_payload"
make_cms_profile "$wrong_group_profile_payload" "$wrong_group_profile"
wrong_group_profile_output="$test_root/wrong-group-profile-output.txt"
if run_distribution_failure "$wrong_group_profile" "$wrong_group_profile_output"; then
  fail "wrong Keychain group profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'does not authorize the helper Keychain group' "$wrong_group_profile_output" || fail "wrong Keychain group failed for the wrong reason"

prefix_wildcard_profile_payload="$test_root/prefix-wildcard-profile.plist"
prefix_wildcard_profile="$test_root/prefix-wildcard.provisionprofile"
/usr/bin/ditto "$script_dir/testdata/Profile.plist" "$prefix_wildcard_profile_payload"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:keychain-access-groups:0 NUHSLZ4RU4.*' "$prefix_wildcard_profile_payload"
make_cms_profile "$prefix_wildcard_profile_payload" "$prefix_wildcard_profile"
prefix_wildcard_profile_output="$test_root/prefix-wildcard-profile-output.txt"
if run_distribution_failure "$prefix_wildcard_profile" "$prefix_wildcard_profile_output"; then
  fail "self-signed prefix wildcard profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'provisioning profile is not Apple-authorized' "$prefix_wildcard_profile_output" || fail "App Identifier Prefix wildcard was not accepted as a Keychain allowlist"

wrong_prefix_wildcard_profile_payload="$test_root/wrong-prefix-wildcard-profile.plist"
wrong_prefix_wildcard_profile="$test_root/wrong-prefix-wildcard.provisionprofile"
/usr/bin/ditto "$script_dir/testdata/Profile.plist" "$wrong_prefix_wildcard_profile_payload"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:keychain-access-groups:0 OTHERTEAM.*' "$wrong_prefix_wildcard_profile_payload"
make_cms_profile "$wrong_prefix_wildcard_profile_payload" "$wrong_prefix_wildcard_profile"
wrong_prefix_wildcard_profile_output="$test_root/wrong-prefix-wildcard-profile-output.txt"
if run_distribution_failure "$wrong_prefix_wildcard_profile" "$wrong_prefix_wildcard_profile_output"; then
  fail "wrong prefix wildcard profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'does not authorize the helper Keychain group' "$wrong_prefix_wildcard_profile_output" || fail "wrong prefix wildcard failed for the wrong reason"

bare_wildcard_profile_payload="$test_root/bare-wildcard-profile.plist"
bare_wildcard_profile="$test_root/bare-wildcard.provisionprofile"
/usr/bin/ditto "$script_dir/testdata/Profile.plist" "$bare_wildcard_profile_payload"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:keychain-access-groups:0 *' "$bare_wildcard_profile_payload"
make_cms_profile "$bare_wildcard_profile_payload" "$bare_wildcard_profile"
bare_wildcard_profile_output="$test_root/bare-wildcard-profile-output.txt"
if run_distribution_failure "$bare_wildcard_profile" "$bare_wildcard_profile_output"; then
  fail "bare wildcard profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'does not authorize the helper Keychain group' "$bare_wildcard_profile_output" || fail "bare wildcard failed for the wrong reason"

self_signed_profile="$test_root/self-signed.provisionprofile"
make_cms_profile "$script_dir/testdata/Profile.plist" "$self_signed_profile"
self_signed_profile_output="$test_root/self-signed-profile-output.txt"
if run_distribution_failure "$self_signed_profile" "$self_signed_profile_output"; then
  fail "self-signed provisioning profile unexpectedly succeeded"
fi
/usr/bin/grep -q 'provisioning profile is not Apple-authorized' "$self_signed_profile_output" || fail "self-signed profile failed for the wrong reason"

echo "PASS: local coding bridge packaging"
