#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
experiment_build="${repo_dir}/Experiments/LocalSTT/.build"
audio_file="${experiment_build}/audio/Daniel-long.wav"
owned_root_pointer="${experiment_build}/cache-isolation/owned-root.txt"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v sandbox-exec >/dev/null; then
  print -u2 -- "The local runtime smoke requires macOS and sandbox-exec."
  exit 1
fi

if [[ ! -f "${audio_file}" ]]; then
  print -u2 -- "Missing synthetic runtime fixture: ${audio_file}"
  print -u2 -- "Prepare it with: mise run experiment:stt:audio"
  exit 1
fi

if [[ ! -s "${owned_root_pointer}" ]]; then
  print -u2 -- "Missing the Hubris-owned model-root pointer: ${owned_root_pointer}"
  print -u2 -- "Prepare it with: mise run experiment:stt:cache:prepare"
  exit 1
fi

owned_root="$(<"${owned_root_pointer}")"
owned_root="${owned_root##[[:space:]]#}"
owned_root="${owned_root%%[[:space:]]#}"
if [[ "${owned_root}" != /* ]] || [[ ! -d "${owned_root}/primary" ]] || [[ ! -d "${owned_root}/ctc" ]]; then
  print -u2 -- "The owned model root is incomplete: ${owned_root:-<empty>}"
  print -u2 -- "Prepare it with: mise run experiment:stt:cache:prepare"
  exit 1
fi

if [[ -z "${HOME:-}" ]] || [[ ! -d "${HOME}" ]]; then
  print -u2 -- "HOME must identify the current user's home directory."
  exit 1
fi
shared_cache_dir="${HOME:A}/Library/Application Support/FluidAudio"
escaped_cache_dir="${shared_cache_dir//\\/\\\\}"
escaped_cache_dir="${escaped_cache_dir//\"/\\\"}"
sandbox_profile="$(mktemp /private/tmp/hubris-voice-local-runtime.XXXXXX)"

cleanup() {
  rm -f "${sandbox_profile}"
}
trap cleanup EXIT

cat >"${sandbox_profile}" <<EOF
(version 1)
(allow default)
(deny network*)
(deny file-read* file-write* (subpath "${escaped_cache_dir}"))
EOF

cd "${repo_dir}"

print -- "Building the release local-runtime test bundle"
HUBRIS_LOCAL_RUNTIME_SMOKE=0 \
  swift test -c release --filter FluidAudioRuntimeSmokeTests

print -- "Running with network and shared FluidAudio cache access denied"
HUBRIS_LOCAL_RUNTIME_SMOKE=1 \
  sandbox-exec -f "${sandbox_profile}" \
  swift test \
  -c release \
  --skip-build \
  --disable-sandbox \
  --filter FluidAudioRuntimeSmokeTests
