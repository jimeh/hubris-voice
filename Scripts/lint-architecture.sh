#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
core_sources="${repository_root}/Sources/HubrisVoiceCore"
forbidden_imports='^[[:space:]]*import[[:space:]]+(AppKit|ApplicationServices|AVFoundation|Combine|CoreAudio|CoreGraphics|Network|OSLog|Security|ServiceManagement|SwiftUI)([[:space:]]|$)'

if ! command -v rg >/dev/null; then
  print -u2 -- "Architecture boundary checks require ripgrep"
  exit 127
fi

matches="$(rg -n "${forbidden_imports}" "${core_sources}" || true)"
if [[ -n "${matches}" ]]; then
  print -u2 -- "HubrisVoiceCore must not import macOS application-boundary frameworks:"
  print -u2 -r -- "${matches}"
  exit 1
fi

print -- "Architecture boundary checks passed"
