#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
resolver="${repo_dir}/Scripts/resolve-signing-identity.sh"
test_count=0

assert_resolves() {
  local label="$1"
  local configured="$2"
  local input="$3"
  local expected="$4"
  local actual

  if [[ -n "${configured}" ]]; then
    actual="$(
      HUBRIS_VOICE_SIGNING_IDENTITY="${configured}" \
        "${resolver}" --stdin <<<"${input}"
    )"
  else
    actual="$(
      env -u HUBRIS_VOICE_SIGNING_IDENTITY \
        "${resolver}" --stdin <<<"${input}"
    )"
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    print -u2 -- "${label}: expected ${expected}, got ${actual}"
    return 1
  fi
  ((test_count += 1))
}

assert_fails() {
  local label="$1"
  local input="$2"

  if env -u HUBRIS_VOICE_SIGNING_IDENTITY \
    "${resolver}" --stdin <<<"${input}" >/dev/null 2>&1; then
    print -u2 -- "${label}: expected resolver to fail"
    return 1
  fi
  ((test_count += 1))
}

apple_development_one='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Developer One (TEAMONE123)"'
apple_development_two='  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Developer Two (TEAMTWO456)"'
developer_id='  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Developer One (TEAMONE123)"'

assert_resolves \
  "one identity is detected automatically" \
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" \
  "${apple_development_one}
${developer_id}" \
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

assert_resolves \
  "multiple identities use the configured fingerprint" \
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" \
  "${apple_development_one}
${apple_development_two}" \
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

assert_resolves \
  "missing identities use the configured fingerprint" \
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" \
  "${developer_id}" \
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

assert_fails \
  "multiple identities without configuration" \
  "${apple_development_one}
${apple_development_two}"

assert_fails \
  "missing identities without configuration" \
  "${developer_id}"

print -- "Signing identity resolver: ${test_count} tests passed"
