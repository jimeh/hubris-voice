#!/bin/zsh

set -euo pipefail

repo_dir="${0:A:h:h}"
info_plist="${repo_dir}/Support/Info.plist"
entitlements="${repo_dir}/Support/HubrisVoice.entitlements"
release_config="${repo_dir}/.github/release-please-config.json"
release_github_script="${repo_dir}/Scripts/release-github.sh"
release_macos_script="${repo_dir}/Scripts/release-macos.sh"
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
  "draft release is resolved to its database identifier" \
  1 \
  "$(rg -c -- '--json databaseId' "${release_github_script}")"
assert_absent \
  "draft operations avoid the published-release tag endpoint" \
  '/releases/tags/' \
  "${release_github_script}"
assert_absent \
  "notarization avoids the read-only zsh status parameter" \
  '^[[:space:]]*local status([[:space:]]|$)' \
  "${release_macos_script}"
assert_equal \
  "release entitlement count" \
  1 \
  "$(plutil -p "${entitlements}" | rg -c '=>')"
assert_equal \
  "release audio input entitlement" \
  true \
  "$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "${entitlements}")"

private_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
assert_equal \
  "Sparkle public key derivation" \
  "O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik=" \
  "$(print -rn -- "${private_key}" | swift "${repo_dir}/Scripts/sparkle-public-key.swift")"

"${repo_dir}/Scripts/prepare-sparkle.sh" --manifest-only >/dev/null
((test_count += 1))

current_sha="$(git rev-parse HEAD)"
RELEASE_SHA="${current_sha}" \
  RELEASE_VERSION="${short_version}" \
  "${repo_dir}/Scripts/release-macos.sh" validate-source >/dev/null
((test_count += 1))

if RELEASE_SHA="${current_sha}" RELEASE_VERSION=invalid \
  "${repo_dir}/Scripts/release-macos.sh" validate-source >/dev/null 2>&1; then
  print -u2 -- "release source validation accepted a malformed version"
  exit 1
fi
((test_count += 1))

print -- "Release configuration: ${test_count} tests passed"
