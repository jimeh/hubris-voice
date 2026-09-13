#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
core_sources="${repository_root}/Sources/HubrisVoiceCore"
forbidden_imports='^[[:space:]]*import[[:space:]]+(AppKit|ApplicationServices|AVFoundation|Combine|CoreAudio|CoreGraphics|Network|OSLog|Security|ServiceManagement|SwiftUI)([[:space:]]|$)'

matches="$(rg -n "${forbidden_imports}" "${core_sources}" || true)"
if [[ -n "${matches}" ]]; then
  print -u2 -- "HubrisVoiceCore must not import macOS application-boundary frameworks:"
  print -u2 -r -- "${matches}"
  exit 1
fi

print -- "Architecture boundary checks passed"
