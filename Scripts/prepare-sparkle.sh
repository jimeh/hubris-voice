#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
manifest_file="${script_dir}/sparkle-source.json"
sparkle_root="${repo_dir}/.native/sparkle"
distribution_dir="${sparkle_root}/distribution"
check_only=false
manifest_only=false

usage() {
  print -u2 -- "Usage: ${0:t} [--check|--manifest-only]"
}

case "${1:-}" in
  "") ;;
  "--check") check_only=true ;;
  "--manifest-only") manifest_only=true ;;
  *)
    usage
    exit 2
    ;;
esac

manifest_value() {
  plutil -extract "$1" raw -o - "${manifest_file}"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

version="$(manifest_value version)"
published_at="$(manifest_value published_at)"
minimum_macos="$(manifest_value minimum_macos)"
archive_name="$(manifest_value source.name)"
archive_url="$(manifest_value source.url)"
archive_sha256="$(manifest_value source.sha256)"
framework_identifier="$(manifest_value framework.identifier)"
license_sha256="$(manifest_value framework.license_sha256)"
framework_sha256="$(manifest_value framework.binary_sha256)"
autoupdate_sha256="$(manifest_value framework.autoupdate_sha256)"
updater_sha256="$(manifest_value framework.updater_sha256)"
generate_appcast_sha256="$(manifest_value tools.generate_appcast_sha256)"
generate_keys_sha256="$(manifest_value tools.generate_keys_sha256)"
sign_update_sha256="$(manifest_value tools.sign_update_sha256)"
license_url="$(manifest_value license_url)"

if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || [[ ! "${published_at}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' ]] \
  || [[ ! "${minimum_macos}" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] \
  || [[ ! "${archive_name}" =~ '^Sparkle-[A-Za-z0-9._-]+\.tar\.xz$' ]] \
  || [[ ! "${archive_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${license_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${framework_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${autoupdate_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${updater_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${generate_appcast_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${generate_keys_sha256}" =~ '^[0-9a-f]{64}$' ]] \
  || [[ ! "${sign_update_sha256}" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 -- "Sparkle source manifest contains malformed values"
  exit 1
fi

expected_url="https://github.com/sparkle-project/Sparkle/releases/download/${version}/${archive_name}"
expected_license_url="https://github.com/sparkle-project/Sparkle/blob/${version}/LICENSE"
if [[ "${archive_url}" != "${expected_url}" ]] \
  || [[ "${license_url}" != "${expected_license_url}" ]] \
  || [[ "${framework_identifier}" != "org.sparkle-project.Sparkle" ]]; then
  print -u2 -- "Sparkle source manifest provenance is inconsistent"
  exit 1
fi

committed_license="${repo_dir}/third-party/sparkle/LICENSE"
if [[ "$(sha256_file "${committed_license}")" != "${license_sha256}" ]]; then
  print -u2 -- "Committed Sparkle license does not match the pinned digest"
  exit 1
fi

verify_distribution() {
  local framework_dir="${distribution_dir}/Sparkle.framework"
  local info_plist="${framework_dir}/Versions/B/Resources/Info.plist"
  local actual_identifier
  local actual_version
  local actual_minimum

  for required_file in \
    "${framework_dir}/Versions/B/Sparkle" \
    "${distribution_dir}/bin/generate_appcast" \
    "${distribution_dir}/bin/generate_keys" \
    "${distribution_dir}/bin/sign_update" \
    "${distribution_dir}/LICENSE"; do
    if [[ ! -f "${required_file}" ]]; then
      print -u2 -- "Prepared Sparkle distribution is missing ${required_file}"
      return 1
    fi
  done

  actual_identifier="$(plutil -extract CFBundleIdentifier raw -o - "${info_plist}")"
  actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "${info_plist}")"
  actual_minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "${info_plist}")"
  if [[ "${actual_identifier}" != "${framework_identifier}" ]] \
    || [[ "${actual_version}" != "${version}" ]] \
    || [[ "${actual_minimum}" != "${minimum_macos}" ]] \
    || [[ "$(sha256_file "${distribution_dir}/LICENSE")" != "${license_sha256}" ]] \
    || [[ "$(sha256_file "${framework_dir}/Versions/B/Sparkle")" != "${framework_sha256}" ]] \
    || [[ "$(sha256_file "${framework_dir}/Versions/B/Autoupdate")" != "${autoupdate_sha256}" ]] \
    || [[ "$(sha256_file "${framework_dir}/Versions/B/Updater.app/Contents/MacOS/Updater")" != "${updater_sha256}" ]] \
    || [[ "$(sha256_file "${distribution_dir}/bin/generate_appcast")" != "${generate_appcast_sha256}" ]] \
    || [[ "$(sha256_file "${distribution_dir}/bin/generate_keys")" != "${generate_keys_sha256}" ]] \
    || [[ "$(sha256_file "${distribution_dir}/bin/sign_update")" != "${sign_update_sha256}" ]]; then
    print -u2 -- "Prepared Sparkle distribution does not match the pin"
    return 1
  fi
}

if [[ "${manifest_only}" == true ]]; then
  print -- "Verified Sparkle ${version} manifest and license"
  exit 0
fi

if [[ "${check_only}" == true ]] && [[ -d "${distribution_dir}" ]]; then
  verify_distribution
  print -- "Verified Sparkle ${version} at ${distribution_dir}"
  exit 0
fi

if [[ "${check_only}" == true ]]; then
  print -u2 -- "Sparkle ${version} is not prepared. Run 'mise run sparkle:prepare'."
  exit 1
fi

archives_dir="${sparkle_root}/archives"
archive_file="${archives_dir}/${archive_name}"
mkdir -p "${archives_dir}"

if [[ -f "${archive_file}" ]] \
  && [[ "$(sha256_file "${archive_file}")" != "${archive_sha256}" ]]; then
  print -u2 -- "Cached Sparkle archive checksum does not match the pin"
  exit 1
fi

if [[ ! -f "${archive_file}" ]]; then
  download_dir="$(mktemp -d "${sparkle_root}/.download.XXXXXX")"
  trap 'rm -rf "${download_dir}"' EXIT
  curl --fail --location --silent --show-error \
    --output "${download_dir}/${archive_name}" \
    "${archive_url}"
  if [[ "$(sha256_file "${download_dir}/${archive_name}")" != "${archive_sha256}" ]]; then
    print -u2 -- "Downloaded Sparkle archive checksum does not match the pin"
    exit 1
  fi
  mv "${download_dir}/${archive_name}" "${archive_file}"
  rm -rf "${download_dir}"
  trap - EXIT
fi

while IFS= read -r archive_entry; do
  if [[ "${archive_entry}" == /* ]] || [[ "/${archive_entry}/" == */../* ]]; then
    print -u2 -- "Sparkle archive contains an unsafe path: ${archive_entry}"
    exit 1
  fi
done < <(tar -tf "${archive_file}")

extract_dir="$(mktemp -d "${sparkle_root}/.extract.XXXXXX")"
trap 'rm -rf "${extract_dir}"' EXIT
tar -xf "${archive_file}" -C "${extract_dir}"
rm -rf "${distribution_dir}"
mv "${extract_dir}" "${distribution_dir}"
trap - EXIT

verify_distribution
print -- "Prepared and verified Sparkle ${version} at ${distribution_dir}"
