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
# The version's section of the changelog leads its release notes.
changelog="${FLASH_CHANGELOG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CHANGELOG.md}"

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
    published_sha="$(gh api "repos/{owner}/{repo}/commits/$release_tag" --jq '.sha')"
    if [[ "$published_sha" != "$target_sha" ]]; then
      echo "Release $release_tag points to commit $published_sha, expected $target_sha" >&2
      exit 1
    fi
    # Immutable assets are canonical on a rerun. Rebuilding can change zip
    # metadata, signing timestamps and CFBundleVersion, so a fresh local
    # checksum must never reach the cask for an archive that was not uploaded.
    download_dir="$(mktemp -d "$(dirname "$zip_path")/.flash-release.XXXXXX")"
    trap 'rm -rf "$download_dir"' EXIT
    gh release download "$release_tag" --pattern "$asset_name" --dir "$download_dir"
    mv -f "$download_dir/$asset_name" "$zip_path"
    echo "Reusing published archive $asset_name from release $release_tag"
  else
    echo "Release $release_tag exists without $asset_name; immutable releases cannot accept new assets" >&2
    exit 1
  fi
else
  args=(release create "$release_tag" "$zip_path#$asset_name" --target "$target_sha" --title "$title")
  if [[ "$prerelease" == true ]]; then
    args+=(--prerelease --notes "Automated build from ${target_sha}.")
  else
    notes_file="$(mktemp)"
    trap 'rm -f "$notes_file"' EXIT
    if [[ -f "$changelog" ]]; then
      awk -v heading="## $release_tag" '
        $0 == heading || index($0, heading " ") == 1 { found = 1; next }
        found && /^## / { exit }
        found { print }
      ' "$changelog" > "$notes_file"
    fi
    if grep -q '[^[:space:]]' "$notes_file"; then
      args+=(--notes-file "$notes_file" --generate-notes)
    else
      args+=(--generate-notes)
    fi
  fi
  gh "${args[@]}"
fi

shasum -a 256 "$zip_path" | awk '{print $1}' > "$zip_path.sha256"
