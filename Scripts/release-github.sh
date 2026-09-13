#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
release_dist_dir="${RELEASE_DIST_DIR:-${repo_dir}/dist}"
release_id=""

required_env() {
  local variable_name="$1"
  if [[ -z "${(P)variable_name:-}" ]]; then
    print -u2 -- "${variable_name} is required"
    exit 1
  fi
}

asset_names() {
  local prefix="Hubris-Voice-${RELEASE_VERSION}-macOS-universal"
  print -r -l -- \
    "${prefix}.zip" \
    "${prefix}.dmg" \
    "${prefix}.spdx.json" \
    appcast.xml \
    SHA256SUMS
}

validate_inputs() {
  required_env GITHUB_REPOSITORY
  required_env RELEASE_SHA
  required_env RELEASE_TAG
  required_env RELEASE_VERSION
  if [[ ! "${GITHUB_REPOSITORY}" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] \
    || [[ ! "${RELEASE_SHA}" =~ '^[0-9a-f]{40}$' ]] \
    || [[ ! "${RELEASE_VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
    || [[ "${RELEASE_TAG}" != "v${RELEASE_VERSION}" ]]; then
    print -u2 -- "Release SHA, tag, or version is malformed or inconsistent"
    exit 1
  fi
}

validate_draft() {
  validate_inputs
  required_env GH_TOKEN
  local tag_sha
  local draft
  local release_tag
  tag_sha="$(git rev-list -n 1 "${RELEASE_TAG}")"
  if [[ "${tag_sha}" != "${RELEASE_SHA}" ]]; then
    print -u2 -- "Tag ${RELEASE_TAG} resolves to ${tag_sha}, expected ${RELEASE_SHA}"
    exit 1
  fi
  release_id="$(gh release view "${RELEASE_TAG}" \
    --repo "${GITHUB_REPOSITORY}" --json databaseId --jq .databaseId)"
  if [[ ! "${release_id}" =~ '^[0-9]+$' ]]; then
    print -u2 -- "Could not resolve release ${RELEASE_TAG} to an identifier"
    exit 1
  fi
  draft="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" --jq .draft)"
  release_tag="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" --jq .tag_name)"
  if [[ "${draft}" != true ]] || [[ "${release_tag}" != "${RELEASE_TAG}" ]]; then
    print -u2 -- "Release ${RELEASE_TAG} must be the exact draft target"
    exit 1
  fi
}

validate_asset_inventory() {
  local allow_missing="${1:-false}"
  local expected_names
  local actual_names
  expected_names="$(asset_names | sort)"
  actual_names="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" \
    --jq '.assets[].name' | sort)"
  if [[ "${allow_missing}" == true ]]; then
    while IFS= read -r actual_name; do
      [[ -z "${actual_name}" ]] && continue
      if ! print -r -- "${expected_names}" | rg -Fxq "${actual_name}"; then
        print -u2 -- "Draft release contains unexpected asset ${actual_name}"
        exit 1
      fi
    done <<<"${actual_names}"
  elif [[ "${actual_names}" != "${expected_names}" ]]; then
    print -u2 -- "Draft release asset inventory does not match the expected set"
    exit 1
  fi
}

upload_assets() {
  validate_draft
  validate_asset_inventory true
  local upload_files=()
  local asset_name
  while IFS= read -r asset_name; do
    if [[ ! -s "${release_dist_dir}/${asset_name}" ]]; then
      print -u2 -- "Missing or empty release asset ${asset_name}"
      exit 1
    fi
    upload_files+=("${release_dist_dir}/${asset_name}")
  done < <(asset_names)
  gh release upload "${RELEASE_TAG}" "${upload_files[@]}" --clobber \
    --repo "${GITHUB_REPOSITORY}"
  validate_asset_inventory false

  while IFS= read -r asset_name; do
    local expected_digest
    local remote_digest
    expected_digest="sha256:$(shasum -a 256 "${release_dist_dir}/${asset_name}" | awk '{print $1}')"
    remote_digest="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" \
      --jq ".assets[] | select(.name == \"${asset_name}\") | .digest")"
    if [[ "${remote_digest}" != "${expected_digest}" ]]; then
      print -u2 -- "Remote digest for ${asset_name} does not match the local asset"
      exit 1
    fi
  done < <(asset_names)
  print -- "Uploaded and verified release assets for ${RELEASE_TAG}"
}

publish_release() {
  validate_draft
  validate_asset_inventory false
  gh release edit "${RELEASE_TAG}" --draft=false --latest \
    --repo "${GITHUB_REPOSITORY}"
  if [[ "$(gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" --jq .draft)" != false ]]; then
    print -u2 -- "Release ${RELEASE_TAG} remained a draft"
    exit 1
  fi
  print -- "Published ${RELEASE_TAG}"
}

case "${1:-}" in
  validate-draft) validate_draft ;;
  upload-assets) upload_assets ;;
  publish) publish_release ;;
  *)
    print -u2 -- "Usage: ${0:t} {validate-draft|upload-assets|publish}"
    exit 2
    ;;
esac
