#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
app_name="Hubris Voice"
bundle_id="com.jimeh.HubrisVoice"
source_plist="${repo_dir}/Support/Info.plist"
entitlements_file="${repo_dir}/Support/HubrisVoice.entitlements"
sparkle_distribution="${repo_dir}/.native/sparkle/distribution"
sparkle_public_key_file="${SPARKLE_PUBLIC_KEY_FILE:-${repo_dir}/Support/SparklePublicKey}"
release_dist_dir="${RELEASE_DIST_DIR:-${repo_dir}/dist}"
release_temp_dir="${RELEASE_TEMP_DIR:-${RUNNER_TEMP:-/private/tmp}/hubris-voice-release}"
app_dir="${repo_dir}/.build/artifacts/${app_name}.app"

required_env() {
  local variable_name="$1"
  if [[ -z "${(P)variable_name:-}" ]]; then
    print -u2 -- "${variable_name} is required"
    exit 1
  fi
}

validate_version() {
  if [[ ! "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 -- "Release version must contain three numeric components"
    exit 1
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

reset_directory() {
  local target_dir="${1:A}"
  case "${target_dir}" in
    / | /Users | /private | /private/tmp | /tmp | "${repo_dir}" | "${repo_dir:h}")
      print -u2 -- "Refusing to reset unsafe directory: ${target_dir}"
      exit 1
      ;;
  esac
  if ((${#target_dir} < 12)); then
    print -u2 -- "Refusing to reset suspiciously broad directory: ${target_dir}"
    exit 1
  fi
  rm -rf "${target_dir}"
  mkdir -p "${target_dir}"
}

asset_prefix() {
  print -r -- "Hubris-Voice-${RELEASE_VERSION}-macOS-universal"
}

validate_source() {
  required_env RELEASE_SHA
  required_env RELEASE_VERSION
  validate_version "${RELEASE_VERSION}"

  local actual_sha
  local short_version
  local bundle_version
  actual_sha="$(git rev-parse HEAD)"
  short_version="$(plutil -extract CFBundleShortVersionString raw -o - "${source_plist}")"
  bundle_version="$(plutil -extract CFBundleVersion raw -o - "${source_plist}")"

  if [[ "${actual_sha}" != "${RELEASE_SHA}" ]]; then
    print -u2 -- "Checked-out SHA ${actual_sha} does not match ${RELEASE_SHA}"
    exit 1
  fi
  if [[ "${short_version}" != "${RELEASE_VERSION}" ]] \
    || [[ "${bundle_version}" != "${RELEASE_VERSION}" ]]; then
    print -u2 -- "Info.plist versions must both equal ${RELEASE_VERSION}"
    exit 1
  fi
}

read_public_key() {
  if [[ ! -f "${sparkle_public_key_file}" ]]; then
    print -u2 -- "The production Sparkle public key is missing: ${sparkle_public_key_file}"
    exit 1
  fi
  local public_key
  public_key="$(tr -d '[:space:]' <"${sparkle_public_key_file}")"
  if [[ ! "${public_key}" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
    print -u2 -- "The Sparkle public key must be a canonical 32-byte base64 key"
    exit 1
  fi
  print -r -- "${public_key}"
}

swift_arguments() {
  local scratch_dir="$1"
  local target_triple="$2"
  print -r -l -- \
    --configuration release \
    --product HubrisVoice \
    --scratch-path "${scratch_dir}" \
    --triple "${target_triple}" \
    -Xswiftc -DHUBRIS_VOICE_SPARKLE \
    -Xswiftc "-F${sparkle_distribution}" \
    -Xlinker "-F${sparkle_distribution}" \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    -Xlinker -framework \
    -Xlinker Sparkle
}

build_slice() {
  local architecture="$1"
  local target_triple="$2"
  local scratch_dir="${release_temp_dir}/build-${architecture}"
  local swift_args
  local bin_dir
  swift_args=("${(@f)$(swift_arguments "${scratch_dir}" "${target_triple}")}")
  swift build "${swift_args[@]}" >&2
  bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
  if [[ ! -x "${bin_dir}/HubrisVoice" ]]; then
    print -u2 -- "SwiftPM did not produce the ${architecture} executable"
    exit 1
  fi
  print -r -- "${bin_dir}/HubrisVoice"
}

prepare_app() {
  local public_key="$1"
  local stage_app="${release_temp_dir}/${app_name}.app"
  local arm64_binary
  local x86_64_binary
  local framework_dir

  arm64_binary="$(build_slice arm64 arm64-apple-macosx15.0)"
  x86_64_binary="$(build_slice x86_64 x86_64-apple-macosx15.0)"

  mkdir -p "${stage_app}/Contents/MacOS"
  mkdir -p "${stage_app}/Contents/Frameworks"
  mkdir -p "${stage_app}/Contents/Resources"
  lipo -create \
    "${arm64_binary}" \
    "${x86_64_binary}" \
    -output "${stage_app}/Contents/MacOS/HubrisVoice"
  cp "${source_plist}" "${stage_app}/Contents/Info.plist"

  /usr/libexec/PlistBuddy -c \
    "Add :SUFeedURL string https://github.com/jimeh/hubris-voice/releases/latest/download/appcast.xml" \
    "${stage_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${public_key}" \
    "${stage_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" \
    "${stage_app}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" \
    "${stage_app}/Contents/Info.plist"

  framework_dir="${stage_app}/Contents/Frameworks/Sparkle.framework"
  ditto "${sparkle_distribution}/Sparkle.framework" "${framework_dir}"
  rm -f "${framework_dir}/XPCServices"
  rm -rf "${framework_dir}/Versions/B/XPCServices"
  cp "${repo_dir}/third-party/sparkle/LICENSE" \
    "${stage_app}/Contents/Resources/Sparkle-LICENSE"

  lipo "${stage_app}/Contents/MacOS/HubrisVoice" -verify_arch arm64
  lipo "${stage_app}/Contents/MacOS/HubrisVoice" -verify_arch x86_64
  if ! otool -L "${stage_app}/Contents/MacOS/HubrisVoice" \
    | rg -q '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    print -u2 -- "Release executable does not link the packaged Sparkle framework"
    exit 1
  fi

  mkdir -p "${app_dir:h}"
  rm -rf "${app_dir}"
  mv "${stage_app}" "${app_dir}"
}

original_default_keychain=""
original_keychains=()
keychain_file="${release_temp_dir}/release.keychain-db"
keychain_password=""
developer_id_identity=""

cleanup_keychain() {
  local cleanup_failed=false
  if [[ -n "${original_default_keychain}" ]]; then
    security default-keychain -d user -s "${original_default_keychain}" || cleanup_failed=true
  fi
  if ((${#original_keychains} > 0)); then
    security list-keychains -d user -s "${original_keychains[@]}" || cleanup_failed=true
  fi
  if [[ -f "${keychain_file}" ]]; then
    security delete-keychain "${keychain_file}" || cleanup_failed=true
  fi
  if [[ "${cleanup_failed}" == false ]]; then
    rm -rf "${release_temp_dir}/credentials"
  fi
}

prepare_keychain() {
  required_env MACOS_TEAM_ID
  required_env MACOS_SIGN_P12
  required_env MACOS_SIGN_PASSWORD
  required_env MACOS_NOTARY_KEY
  required_env MACOS_NOTARY_KEY_ID
  required_env MACOS_NOTARY_ISSUER_ID

  if [[ ! "${MACOS_TEAM_ID}" =~ '^[A-Z0-9]{10}$' ]] \
    || [[ ! "${MACOS_NOTARY_KEY_ID}" =~ '^[A-Z0-9]{10}$' ]] \
    || [[ ! "${MACOS_NOTARY_ISSUER_ID}" =~ '^[0-9A-Fa-f-]{36}$' ]]; then
    print -u2 -- "Apple signing or notarization identifiers are malformed"
    exit 1
  fi

  local credentials_dir="${release_temp_dir}/credentials"
  local p12_file="${credentials_dir}/developer-id.p12"
  local notary_key_file="${credentials_dir}/notary-key.p8"
  local identity_lines

  mkdir -p "${credentials_dir}"
  print -rn -- "${MACOS_SIGN_P12}" | /usr/bin/base64 -D >"${p12_file}"
  print -rn -- "${MACOS_NOTARY_KEY}" | /usr/bin/base64 -D >"${notary_key_file}"
  chmod 600 "${p12_file}" "${notary_key_file}"

  original_default_keychain="$(security default-keychain -d user | tr -d '"')"
  while IFS= read -r keychain_entry; do
    original_keychains+=("${keychain_entry//\"/}")
  done < <(security list-keychains -d user | sed -E 's/^[[:space:]]+//')

  keychain_password="hubris-voice-${RANDOM}-${RANDOM}"
  security create-keychain -p "${keychain_password}" "${keychain_file}"
  security set-keychain-settings -lut 21600 "${keychain_file}"
  security unlock-keychain -p "${keychain_password}" "${keychain_file}"
  security default-keychain -d user -s "${keychain_file}"
  security list-keychains -d user -s "${keychain_file}"
  security import "${p12_file}" -k "${keychain_file}" \
    -P "${MACOS_SIGN_PASSWORD}" -T /usr/bin/codesign
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "${keychain_password}" "${keychain_file}"

  identity_lines="$(security find-identity -v -p codesigning "${keychain_file}" \
    | rg "Developer ID Application:.*\(${MACOS_TEAM_ID}\)")"
  if [[ "$(print -r -- "${identity_lines}" | wc -l | tr -d ' ')" != 1 ]]; then
    print -u2 -- "Expected exactly one Developer ID Application identity for ${MACOS_TEAM_ID}"
    exit 1
  fi
  developer_id_identity="$(print -r -- "${identity_lines}" \
    | sed -E 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}).*/\1/')"
}

sign_target() {
  local signing_identity="$1"
  local target_file="$2"
  local include_entitlements="${3:-false}"
  local sign_args=(
    --force
    --sign "${signing_identity}"
    --keychain "${keychain_file}"
    --options runtime
    --timestamp
  )
  if [[ "${include_entitlements}" == true ]]; then
    sign_args+=(--entitlements "${entitlements_file}")
  fi
  codesign "${sign_args[@]}" "${target_file}"
}

verify_signature() {
  local target_file="$1"
  local require_runtime="${2:-true}"
  local details
  codesign --verify --strict --verbose=2 "${target_file}"
  details="$(codesign -dvvv "${target_file}" 2>&1)"
  if [[ "${details}" == *"Signature=adhoc"* ]] \
    || [[ "${details}" != *"Authority=Developer ID Application:"* ]] \
    || [[ "${details}" != *"TeamIdentifier=${MACOS_TEAM_ID}"* ]] \
    || [[ "${details}" != *"Timestamp="* ]] \
    || [[ "${details}" == *"Timestamp=none"* ]]; then
    print -u2 -- "Developer ID signature verification failed for ${target_file}"
    exit 1
  fi
  if [[ "${require_runtime}" == true ]] && [[ "${details}" != *"runtime"* ]]; then
    print -u2 -- "Hardened runtime is missing from ${target_file}"
    exit 1
  fi
}

sign_app() {
  local signing_identity="$1"
  local sparkle_version="${app_dir}/Contents/Frameworks/Sparkle.framework/Versions/B"
  local target_file

  sign_target "${signing_identity}" "${sparkle_version}/Autoupdate"
  sign_target "${signing_identity}" "${sparkle_version}/Updater.app/Contents/MacOS/Updater"
  sign_target "${signing_identity}" "${sparkle_version}/Updater.app"
  sign_target "${signing_identity}" "${sparkle_version}/Sparkle"
  sign_target "${signing_identity}" "${app_dir}/Contents/Frameworks/Sparkle.framework"
  sign_target "${signing_identity}" "${app_dir}/Contents/MacOS/HubrisVoice" true
  sign_target "${signing_identity}" "${app_dir}" true

  codesign --verify --deep --strict --verbose=4 "${app_dir}"
  for target_file in \
    "${sparkle_version}/Autoupdate" \
    "${sparkle_version}/Updater.app/Contents/MacOS/Updater" \
    "${sparkle_version}/Updater.app" \
    "${sparkle_version}/Sparkle" \
    "${app_dir}/Contents/Frameworks/Sparkle.framework" \
    "${app_dir}/Contents/MacOS/HubrisVoice" \
    "${app_dir}"; do
    verify_signature "${target_file}"
  done
}

submit_notarization() {
  local submission_file="$1"
  local result
  local notary_status
  result="$(xcrun notarytool submit "${submission_file}" \
    --wait \
    --output-format json \
    --key "${release_temp_dir}/credentials/notary-key.p8" \
    --key-id "${MACOS_NOTARY_KEY_ID}" \
    --issuer "${MACOS_NOTARY_ISSUER_ID}")"
  notary_status="$(print -r -- "${result}" | plutil -extract status raw -o - -)"
  if [[ "${notary_status}" != "Accepted" ]]; then
    print -u2 -- "Apple notarization finished with status ${notary_status}"
    exit 1
  fi
}

create_dmg() {
  local signing_identity="$1"
  local dmg_file="$2"
  local dmg_stage="${release_temp_dir}/dmg"
  rm -rf "${dmg_stage}"
  mkdir -p "${dmg_stage}"
  ditto "${app_dir}" "${dmg_stage}/${app_name}.app"
  ln -s /Applications "${dmg_stage}/Applications"
  hdiutil create \
    -fs HFS+ \
    -format UDZO \
    -volname "${app_name}" \
    -srcfolder "${dmg_stage}" \
    "${dmg_file}"
  sign_target "${signing_identity}" "${dmg_file}"
  verify_signature "${dmg_file}" false
  submit_notarization "${dmg_file}"
  xcrun stapler staple "${dmg_file}"
  xcrun stapler validate "${dmg_file}"
  spctl --assess --type open --context context:primary-signature --verbose=4 "${dmg_file}"
}

write_checksums() {
  local names=()
  local file_name
  names=("$@")
  : >"${release_dist_dir}/SHA256SUMS"
  for file_name in "${names[@]}"; do
    print -r -- "$(sha256_file "${release_dist_dir}/${file_name}")  ${file_name}" \
      >>"${release_dist_dir}/SHA256SUMS"
  done
}

adhoc_sign_app() {
  local sparkle_version="${app_dir}/Contents/Frameworks/Sparkle.framework/Versions/B"
  local target_file
  for target_file in \
    "${sparkle_version}/Autoupdate" \
    "${sparkle_version}/Updater.app/Contents/MacOS/Updater" \
    "${sparkle_version}/Updater.app" \
    "${sparkle_version}/Sparkle" \
    "${app_dir}/Contents/Frameworks/Sparkle.framework" \
    "${app_dir}/Contents/MacOS/HubrisVoice" \
    "${app_dir}"; do
    codesign --force --sign - "${target_file}"
  done
  codesign --verify --deep --strict --verbose=4 "${app_dir}"
}

build_adhoc() {
  validate_source
  "${script_dir}/prepare-sparkle.sh"
  local public_key
  public_key="$(read_public_key)"
  reset_directory "${release_temp_dir}"
  prepare_app "${public_key}"
  adhoc_sign_app
  print -- "Built and verified universal ad-hoc Sparkle bundle at ${app_dir}"
}

build_release() {
  validate_source
  "${script_dir}/prepare-sparkle.sh"
  local public_key
  local signing_identity
  local prefix
  local notarization_zip
  local final_zip
  local final_dmg
  local sbom_file
  public_key="$(read_public_key)"
  prefix="$(asset_prefix)"
  notarization_zip="${release_temp_dir}/notarization.zip"
  final_zip="${release_dist_dir}/${prefix}.zip"
  final_dmg="${release_dist_dir}/${prefix}.dmg"
  sbom_file="${release_dist_dir}/${prefix}.spdx.json"

  reset_directory "${release_temp_dir}"
  reset_directory "${release_dist_dir}"
  prepare_app "${public_key}"
  trap cleanup_keychain EXIT
  prepare_keychain
  signing_identity="${developer_id_identity}"
  sign_app "${signing_identity}"

  ditto -c -k --sequesterRsrc --keepParent "${app_dir}" "${notarization_zip}"
  submit_notarization "${notarization_zip}"
  xcrun stapler staple "${app_dir}"
  xcrun stapler validate "${app_dir}"
  codesign --verify --deep --strict --verbose=4 "${app_dir}"
  spctl --assess --type execute --verbose=4 "${app_dir}"

  ditto -c -k --sequesterRsrc --keepParent "${app_dir}" "${final_zip}"
  create_dmg "${signing_identity}" "${final_dmg}"
  syft scan "dir:${app_dir}" \
    --source-name "${app_name}" \
    --source-version "${RELEASE_VERSION}" \
    -o "spdx-json=${sbom_file}"
  if [[ "$(plutil -extract spdxVersion raw -o - "${sbom_file}")" != "SPDX-2.3" ]] \
    || (($(plutil -extract packages raw -o - "${sbom_file}") < 1)); then
    print -u2 -- "Generated SPDX SBOM is empty or has the wrong schema version"
    exit 1
  fi
  pyspdxtools -i "${sbom_file}"

  write_checksums "${prefix}.zip" "${prefix}.dmg" "${prefix}.spdx.json"
  cleanup_keychain
  trap - EXIT
  print -- "Prepared signed, notarized release assets in ${release_dist_dir}"
}

generate_appcast() {
  validate_source
  required_env RELEASE_TAG
  required_env SPARKLE_EDDSA_PRIVATE_KEY
  if [[ "${RELEASE_TAG}" != "v${RELEASE_VERSION}" ]]; then
    print -u2 -- "Release tag must equal v${RELEASE_VERSION}"
    exit 1
  fi
  local prefix
  local appcast_dir
  local derived_public_key
  local enclosure_signature
  local expected_public_key
  local zip_name
  prefix="$(asset_prefix)"
  zip_name="${prefix}.zip"
  expected_public_key="$(read_public_key)"
  derived_public_key="$(print -rn -- "${SPARKLE_EDDSA_PRIVATE_KEY}" \
    | swift "${script_dir}/sparkle-public-key.swift")"
  if [[ "${derived_public_key}" != "${expected_public_key}" ]]; then
    print -u2 -- "Sparkle private key does not match the committed public key"
    exit 1
  fi
  appcast_dir="$(mktemp -d "${release_temp_dir}/appcast.XXXXXX")"
  trap 'rm -rf "${appcast_dir}"' EXIT
  cp "${release_dist_dir}/${zip_name}" "${appcast_dir}/${zip_name}"
  print -rn -- "${SPARKLE_EDDSA_PRIVATE_KEY}" \
    | "${sparkle_distribution}/bin/generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "https://github.com/jimeh/hubris-voice/releases/download/${RELEASE_TAG}/" \
      --link "https://github.com/jimeh/hubris-voice/releases/tag/${RELEASE_TAG}" \
      --versions "${RELEASE_VERSION}" \
      --maximum-versions 1 \
      --maximum-deltas 0 \
      --disable-signing-warning \
      -o "${appcast_dir}/appcast.xml" \
      "${appcast_dir}"
  print -rn -- "${SPARKLE_EDDSA_PRIVATE_KEY}" \
    | "${sparkle_distribution}/bin/sign_update" \
      --verify \
      --ed-key-file - \
      "${appcast_dir}/appcast.xml"
  enclosure_signature="$(xmllint \
    --xpath "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])" \
    "${appcast_dir}/appcast.xml")"
  if [[ ! "${enclosure_signature}" =~ '^[A-Za-z0-9+/]{86}==$' ]]; then
    print -u2 -- "Generated appcast does not contain a signed ZIP enclosure"
    exit 1
  fi
  print -rn -- "${SPARKLE_EDDSA_PRIVATE_KEY}" \
    | "${sparkle_distribution}/bin/sign_update" \
      --verify \
      --ed-key-file - \
      "${appcast_dir}/${zip_name}" \
      "${enclosure_signature}"
  cp "${appcast_dir}/appcast.xml" "${release_dist_dir}/appcast.xml"
  rm -rf "${appcast_dir}"
  trap - EXIT

  if ! rg -Fq \
    "https://github.com/jimeh/hubris-voice/releases/download/${RELEASE_TAG}/${zip_name}" \
    "${release_dist_dir}/appcast.xml"; then
    print -u2 -- "Generated appcast does not reference the exact release ZIP"
    exit 1
  fi
  if ! rg -Fq '<!-- sparkle-signatures:' "${release_dist_dir}/appcast.xml"; then
    print -u2 -- "Generated appcast feed does not contain a Sparkle signature"
    exit 1
  fi
  write_checksums \
    "${prefix}.zip" \
    "${prefix}.dmg" \
    "${prefix}.spdx.json" \
    appcast.xml
  print -- "Generated signed appcast and final checksums"
}

case "${1:-}" in
  build) build_release ;;
  build-adhoc) build_adhoc ;;
  generate-appcast) generate_appcast ;;
  validate-source) validate_source ;;
  *)
    print -u2 -- "Usage: ${0:t} {build|build-adhoc|generate-appcast|validate-source}"
    exit 2
    ;;
esac
