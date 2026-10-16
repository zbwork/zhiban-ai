#!/bin/bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly signing_script="$script_dir/sign_nested_code.sh"
readonly project_file="$script_dir/../Runner.xcodeproj/project.pbxproj"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$signing_script" ]] || fail "Sparkle nested-code signing script is missing or not executable"
/bin/bash -n "$signing_script"

ACTION=build "$signing_script" >/dev/null || fail "non-archive build must remain a no-op"

if /usr/bin/grep -q -- '--deep' "$signing_script"; then
  fail "Sparkle signing must not use codesign --deep"
fi

readonly installer_pattern='Versions/B/XPCServices/Installer.xpc'
readonly downloader_pattern='Versions/B/XPCServices/Downloader.xpc'
readonly autoupdate_pattern='Versions/B/Autoupdate'
readonly updater_pattern='Versions/B/Updater.app'

for pattern in \
  "$installer_pattern" \
  "$downloader_pattern" \
  "$autoupdate_pattern" \
  "$updater_pattern" \
  '--options runtime' \
  '--timestamp' \
  '--preserve-metadata=identifier,entitlements'; do
  /usr/bin/grep -qF -- "$pattern" "$signing_script" || fail "missing signing contract: $pattern"
done

line_of() {
  /usr/bin/grep -nF -- "$1" "$signing_script" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

readonly installer_line="$(line_of "$installer_pattern")"
readonly downloader_line="$(line_of "$downloader_pattern")"
readonly autoupdate_line="$(line_of "$autoupdate_pattern")"
readonly updater_line="$(line_of "$updater_pattern")"
readonly framework_line="$(line_of 'sign_target "$sparkle_framework"')"

(( installer_line < downloader_line )) || fail "Installer.xpc must be signed before Downloader.xpc"
(( downloader_line < autoupdate_line )) || fail "Downloader.xpc must be signed before Autoupdate"
(( autoupdate_line < updater_line )) || fail "Autoupdate must be signed before Updater.app"
(( updater_line < framework_line )) || fail "Updater.app must be signed before Sparkle.framework"

readonly runner_phase="$({
  /usr/bin/sed -n '/33CC10EC2044A3C60003C045 \/\* Runner \*\//,/);/p' "$project_file"
} | /usr/bin/sed -n '/buildPhases = (/,/);/p')"

readonly pods_line="$(printf '%s\n' "$runner_phase" | /usr/bin/grep -nF '[CP] Embed Pods Frameworks' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
readonly sparkle_line="$(printf '%s\n' "$runner_phase" | /usr/bin/grep -nF 'Sign Sparkle Nested Code' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
readonly bridge_line="$(printf '%s\n' "$runner_phase" | /usr/bin/grep -nF 'Build & Embed Local Coding Bridge' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"

[[ -n "$pods_line" && -n "$sparkle_line" && -n "$bridge_line" ]] || fail "Runner build phases are incomplete"
(( pods_line < sparkle_line )) || fail "Sparkle signing must run after CocoaPods embeds frameworks"
(( sparkle_line < bridge_line )) || fail "Sparkle signing must run before the final helper/embed phase"

echo "PASS: Sparkle nested-code signing contract and Xcode phase ordering are correct"
