#!/bin/zsh

set -euo pipefail

required_commands=(
  codesign
  lefthook
  plutil
  security
  shellcheck
  shfmt
  swift
  swiftformat
  swiftlint
  taplo
  xcodebuild
)

for command_name in "${required_commands[@]}"; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    print -u2 -- "Missing ${command_name}. Run 'mise run setup'."
    exit 1
  fi
done

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
if ((macos_major < 15)); then
  print -u2 -- "Hubris Voice requires macOS 15 or newer; found ${macos_version}."
  exit 1
fi

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
if ((xcode_major < 16)); then
  print -u2 -- "Hubris Voice requires Xcode 16 or newer; found ${xcode_version}."
  exit 1
fi

if ! ./Scripts/resolve-signing-identity.sh >/dev/null; then
  print -u2 -- "Development signing is not configured. See README.md."
  exit 1
fi

if ! lefthook check-install >/dev/null 2>&1; then
  print -u2 -- "Repository Git hooks are not installed. Run 'mise run hooks:install'."
  exit 1
fi

swift_version="$(swift --version 2>&1 | awk '/Apple Swift version/ { print; exit }')"

print -- "Hubris Voice development environment is ready"
print -- "  macOS: ${macos_version}"
print -- "  Xcode: ${xcode_version}"
print -- "  Swift: ${swift_version}"
