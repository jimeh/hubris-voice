#!/bin/zsh

set -euo pipefail

configuration="${1:-release}"
script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
artifact_root="${repo_dir}/.build/artifacts"
app_dir="${artifact_root}/Hubris Voice.app"
stage_root="$(mktemp -d /private/tmp/hubris-voice-bundle.XXXXXX)"
stage_app="${stage_root}/Hubris Voice.app"

cleanup() {
  rm -rf "${stage_root}"
}
trap cleanup EXIT

cd "${repo_dir}"

swift_flags=()
if [[ -n "${SWIFT_FLAGS:-}" ]]; then
  swift_flags=(${=SWIFT_FLAGS})
fi

swift build \
  --configuration "${configuration}" \
  --product HubrisVoice \
  "${swift_flags[@]}"
bin_path="$(
  swift build \
    --configuration "${configuration}" \
    --show-bin-path \
    "${swift_flags[@]}"
)"

mkdir -p "${stage_app}/Contents/MacOS"
mkdir -p "${stage_app}/Contents/Resources"
cp "${bin_path}/HubrisVoice" "${stage_app}/Contents/MacOS/HubrisVoice"
cp "${repo_dir}/Support/Info.plist" "${stage_app}/Contents/Info.plist"

plutil -lint "${stage_app}/Contents/Info.plist"
signing_identity="$("${repo_dir}/Scripts/resolve-signing-identity.sh")"
codesign \
  --force \
  --sign "${signing_identity}" \
  --identifier com.jimeh.HubrisVoice \
  "${stage_app}"

mkdir -p "${artifact_root}"
rm -rf "${app_dir}"
mv "${stage_app}" "${app_dir}"

print -r -- "${app_dir}"
