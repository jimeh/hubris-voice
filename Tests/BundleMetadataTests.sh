#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
info_plist="$repository_root/Support/Info.plist"
app_identity="$repository_root/Sources/HubrisVoiceApp/AppIdentity.swift"

bundle_identifier="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleIdentifier" \
    "$info_plist" 2>/dev/null || true
)"

if [[ -z "$bundle_identifier" ]]; then
  print -u2 \
    "Expected CFBundleIdentifier in Support/Info.plist"
  exit 1
fi

swift_bundle_identifier="$(
  sed -n \
    's/^[[:space:]]*static let bundleIdentifier = "\([^"]*\)"$/\1/p' \
    "$app_identity"
)"

if [[ "$swift_bundle_identifier" != "$bundle_identifier" ]]; then
  print -u2 \
    "Expected AppIdentity.bundleIdentifier to match CFBundleIdentifier ($bundle_identifier)"
  exit 1
fi

multiple_instances="$(
  /usr/libexec/PlistBuddy \
    -c "Print :LSMultipleInstancesProhibited" \
    "$info_plist" 2>/dev/null || true
)"

if [[ "$multiple_instances" != "true" ]]; then
  print -u2 \
    "Expected LSMultipleInstancesProhibited to be true in Support/Info.plist"
  exit 1
fi

print "Bundle metadata tests passed"
