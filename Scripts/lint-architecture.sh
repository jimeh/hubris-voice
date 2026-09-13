#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
core_sources="${repository_root}/Sources/HubrisVoiceCore"
forbidden_imports='^[[:space:]]*(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+)*((private|fileprivate|internal|package|public|open)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?(AppKit|ApplicationServices|AVFoundation|Combine|CoreAudio|CoreGraphics|Network|OSLog|Security|ServiceManagement|SwiftUI)([[:space:].]|$)'

if ! command -v rg >/dev/null; then
  print -u2 -- "Architecture boundary checks require ripgrep"
  exit 127
fi

scan_output="$(mktemp /private/tmp/hubris-voice-architecture.XXXXXX)"
trap 'rm -f "${scan_output}"' EXIT

if rg -n "${forbidden_imports}" "${core_sources}" >"${scan_output}"; then
  :
else
  scan_status=$?
  if ((scan_status != 1)); then
    print -u2 -- "Failed to scan ${core_sources}"
    exit "${scan_status}"
  fi
fi
matches="$(<"${scan_output}")"
if [[ -n "${matches}" ]]; then
  print -u2 -- "HubrisVoiceCore must not import macOS application-boundary frameworks:"
  print -u2 -r -- "${matches}"
  exit 1
fi

print -- "Architecture boundary checks passed"
