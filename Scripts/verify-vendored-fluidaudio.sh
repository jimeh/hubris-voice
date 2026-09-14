#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
vendor_dir="${repo_dir}/Vendor/FluidAudio"
integrity_file="${vendor_dir}/UPSTREAM.sha256"
patch_file="${vendor_dir}/Patches/hubris.patch"
stage_root="$(mktemp -d /private/tmp/hubris-fluidaudio-verify.XXXXXX)"
snapshot_dir="${stage_root}/FluidAudio"

cleanup() {
  rm -rf "${stage_root}"
}
trap cleanup EXIT

mkdir -p "${snapshot_dir}"
cp "${vendor_dir}/Package.swift" "${snapshot_dir}/Package.swift"
cp "${vendor_dir}/Package@swift-6.2.swift" \
  "${snapshot_dir}/Package@swift-6.2.swift"
cp "${vendor_dir}/LICENSE" "${snapshot_dir}/LICENSE"
cp -R "${vendor_dir}/Sources" "${snapshot_dir}/Sources"
cp -R "${vendor_dir}/ThirdPartyLicenses" \
  "${snapshot_dir}/ThirdPartyLicenses"

expected_files="${stage_root}/expected-files"
actual_files="${stage_root}/actual-files"
awk '{print $2}' "${integrity_file}" | sort >"${expected_files}"
(
  cd "${snapshot_dir}"
  find Package.swift Package@swift-6.2.swift LICENSE Sources \
    ThirdPartyLicenses -type f -print | sort
) >"${actual_files}"
if ! diff -u "${expected_files}" "${actual_files}"; then
  print -u2 -- "Vendored FluidAudio file set differs from the pinned snapshot"
  exit 1
fi

patch --silent --reverse --strip=1 --directory="${snapshot_dir}" \
  <"${patch_file}"
(
  cd "${snapshot_dir}"
  shasum -a 256 --check --quiet "${integrity_file}"
)

patch --silent --strip=1 --directory="${snapshot_dir}" <"${patch_file}"
while read -r _ file_name; do
  if ! cmp -s "${snapshot_dir}/${file_name}" "${vendor_dir}/${file_name}"; then
    print -u2 -- "Patched FluidAudio file differs: ${file_name}"
    exit 1
  fi
done <"${integrity_file}"

print -- "Vendored FluidAudio 0.15.7 source and Hubris patch verified"
