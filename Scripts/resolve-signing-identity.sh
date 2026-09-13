#!/bin/zsh

set -euo pipefail

configured_identity="${HUBRIS_VOICE_SIGNING_IDENTITY:-}"

case "${1:-}" in
  "")
    identity_output="$(
      security find-identity -v -p codesigning 2>/dev/null || true
    )"
    ;;
  "--stdin")
    identity_output="$(<&0)"
    ;;
  *)
    print -u2 -- "Usage: ${0:t} [--stdin]"
    exit 2
    ;;
esac

apple_development_identities=()
while IFS= read -r line; do
  if [[ "${line}" =~ '^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"Apple Development:' ]]; then
    apple_development_identities+=("${match[1]}")
  fi
done <<<"${identity_output}"

if ((${#apple_development_identities} == 1)); then
  print -r -- "${apple_development_identities[1]}"
  exit 0
fi

if [[ -n "${configured_identity}" ]]; then
  print -r -- "${configured_identity}"
  exit 0
fi

if ((${#apple_development_identities} == 0)); then
  print -u2 -- \
    "No Apple Development signing identity was found. Set " \
    "HUBRIS_VOICE_SIGNING_IDENTITY to its SHA-1 fingerprint."
else
  print -u2 -- \
    "Found ${#apple_development_identities} Apple Development signing " \
    "identities. Set HUBRIS_VOICE_SIGNING_IDENTITY to the SHA-1 " \
    "fingerprint to use."
fi
exit 1
