#!/bin/zsh

set -euo pipefail

repo_dir="${0:A:h:h}"
info_plist="${repo_dir}/Support/Info.plist"
entitlements="${repo_dir}/Support/HubrisVoice.entitlements"
release_config="${repo_dir}/.github/release-please-config.json"
test_count=0

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    print -u2 -- "${label}: expected ${expected}, got ${actual}"
    exit 1
  fi
  ((test_count += 1))
}

assert_absent() {
  local label="$1"
  local pattern="$2"
  local target_file="$3"
  if rg -q "${pattern}" "${target_file}"; then
    print -u2 -- "${label}: unexpected ${pattern} in ${target_file}"
    exit 1
  fi
  ((test_count += 1))
}

short_version="$(plutil -extract CFBundleShortVersionString raw -o - "${info_plist}")"
bundle_version="$(plutil -extract CFBundleVersion raw -o - "${info_plist}")"
assert_equal "bundle versions stay synchronized" "${short_version}" "${bundle_version}"
assert_equal \
  "Release Please owns both bundle version fields" \
  2 \
  "$(rg -c 'x-release-please-version' "${info_plist}")"

for sparkle_key in \
  SUFeedURL \
  SUPublicEDKey \
  SURequireSignedFeed \
  SUVerifyUpdateBeforeExtraction; do
  assert_absent "development bundle stays Sparkle-free" "${sparkle_key}" "${info_plist}"
done

assert_equal \
  "release strategy" \
  simple \
  "$(plutil -extract release-type raw -o - "${release_config}")"
assert_equal \
  "release is created as a draft" \
  true \
  "$(plutil -extract draft raw -o - "${release_config}")"
assert_equal \
  "release entitlement count" \
  1 \
  "$(plutil -p "${entitlements}" | rg -c '=>')"
assert_equal \
  "release audio input entitlement" \
  true \
  "$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "${entitlements}")"

"${repo_dir}/Scripts/prepare-sparkle.sh" --manifest-only >/dev/null
((test_count += 1))

print -- "Release configuration: ${test_count} tests passed"
