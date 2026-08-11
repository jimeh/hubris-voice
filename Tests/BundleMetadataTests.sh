#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
info_plist="$repository_root/Support/Info.plist"

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
