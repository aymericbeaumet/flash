#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo 'Usage: publish-github-release.sh TAG ZIP_PATH ASSET_NAME TITLE PRERELEASE TARGET_SHA' >&2
  exit 2
fi

release_tag="$1"
zip_path="$2"
asset_name="$3"
title="$4"
prerelease="$5"
target_sha="$6"

if [[ ! -f "$zip_path" ]]; then
  echo "Release archive is missing: $zip_path" >&2
  exit 1
fi
if [[ "$prerelease" != true && "$prerelease" != false ]]; then
  echo "Invalid prerelease value: $prerelease" >&2
  exit 2
fi

if gh release view "$release_tag" >/dev/null 2>&1; then
  assets="$(gh release view "$release_tag" --json assets --jq '.assets[].name')"
  if grep -Fqx -- "$asset_name" <<< "$assets"; then
    echo "Release $release_tag already contains $asset_name"
    exit 0
  fi
  echo "Release $release_tag exists without $asset_name; immutable releases cannot accept new assets" >&2
  exit 1
fi

args=(release create "$release_tag" "$zip_path#$asset_name" --target "$target_sha" --title "$title")
if [[ "$prerelease" == true ]]; then
  args+=(--prerelease --notes "Automated build from ${target_sha}.")
else
  args+=(--generate-notes)
fi
gh "${args[@]}"
