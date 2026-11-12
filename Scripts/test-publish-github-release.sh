#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_GH_CALLS"
previous=''
for argument in "$@"; do
  if [[ "$previous" == --notes-file ]]; then cp "$argument" "$MOCK_NOTES"; fi
  previous="$argument"
done
if [[ "$1 $2" == "release view" ]]; then
  [[ "$MOCK_RELEASE_EXISTS" == "true" ]] || exit 1
  if [[ " $* " == *" --json assets "* ]]; then
    printf '%s\n' "$MOCK_ASSETS"
  fi
fi
if [[ "$1" == api ]]; then
  printf '%s\n' "$MOCK_RELEASE_SHA"
fi
if [[ "$1 $2" == "release download" ]]; then
  [[ "${MOCK_DOWNLOAD_FAIL:-false}" != true ]] || exit 1
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --dir ]]; then
      printf '%s' "$MOCK_ASSET_CONTENTS" > "$2/$MOCK_ASSET_NAME"
      break
    fi
    shift
  done
fi
EOF
chmod +x "$test_dir/gh"

export PATH="$test_dir:$PATH"
export MOCK_GH_CALLS="$test_dir/calls"
export MOCK_NOTES="$test_dir/notes"
# A changelog with no section for the version: GitHub's generated notes only.
export FLASH_CHANGELOG="$test_dir/CHANGELOG.md"
printf '%s\n' '# Changelog' '' '## Unreleased' '' '- pending' > "$FLASH_CHANGELOG"
asset_path="$test_dir/Flash-1.1.0.zip"
printf '%s' 'rebuilt archive' > "$asset_path"
export MOCK_RELEASE_SHA=abc123 MOCK_ASSET_NAME=Flash-1.1.0.zip
export MOCK_ASSET_CONTENTS='immutable published archive'

export MOCK_RELEASE_EXISTS=false MOCK_ASSETS=''
bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123
grep -Fqx "release create 1.1.0 $asset_path#Flash-1.1.0.zip --target abc123 --title Flash 1.1.0 --generate-notes" "$MOCK_GH_CALLS"
[[ ! -e "$MOCK_NOTES" ]]

# The version's own section leads the notes, up to the next section.
: > "$MOCK_GH_CALLS"
printf '%s\n' '# Changelog' '' '## Unreleased' '' '- pending' '' '## 1.1.0' '' \
  '### Upgrading from 1.0' '' '- renamed things' '' '## 1.0.0' '' '- first' > "$FLASH_CHANGELOG"
bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123
grep -Fq -- '--notes-file' "$MOCK_GH_CALLS"
grep -Fq -- '--generate-notes' "$MOCK_GH_CALLS"
grep -Fqx -- '- renamed things' "$MOCK_NOTES"
grep -Fqx -- '### Upgrading from 1.0' "$MOCK_NOTES"
! grep -Fq -- '- first' "$MOCK_NOTES"
! grep -Fq -- '- pending' "$MOCK_NOTES"
rm -f "$MOCK_NOTES"
printf '%s\n' '# Changelog' > "$FLASH_CHANGELOG"
[[ "$(cat "$asset_path.sha256")" == "$(shasum -a 256 "$asset_path" | awk '{print $1}')" ]]

: > "$MOCK_GH_CALLS"
export MOCK_RELEASE_EXISTS=true MOCK_ASSETS=Flash-1.1.0.zip
bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123
! grep -Fq 'release create' "$MOCK_GH_CALLS"
[[ "$(cat "$asset_path")" == "$MOCK_ASSET_CONTENTS" ]] || {
  echo 'An existing immutable archive must replace the fresh local build used by the cask' >&2
  exit 1
}
[[ "$(cat "$asset_path.sha256")" == "$(shasum -a 256 "$asset_path" | awk '{print $1}')" ]]

: > "$MOCK_GH_CALLS"
export MOCK_RELEASE_SHA=othercommit
if bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123 \
  > "$test_dir/output" 2>&1; then
  echo 'An existing release for a different commit must fail' >&2
  exit 1
fi
grep -Fq 'commit' "$test_dir/output"
! grep -Fq 'release download' "$MOCK_GH_CALLS"
export MOCK_RELEASE_SHA=abc123

: > "$MOCK_GH_CALLS"
printf '%s' 'local archive before failed download' > "$asset_path"
export MOCK_DOWNLOAD_FAIL=true
if bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123 \
  > "$test_dir/output" 2>&1; then
  echo 'A failed canonical archive download must fail publication' >&2
  exit 1
fi
[[ "$(cat "$asset_path")" == 'local archive before failed download' ]]
export MOCK_DOWNLOAD_FAIL=false

: > "$MOCK_GH_CALLS"
export MOCK_ASSETS=''
if bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123 \
  > "$test_dir/output" 2>&1; then
  echo 'An immutable release missing its asset must fail' >&2
  exit 1
fi
grep -Fq 'immutable' "$test_dir/output"
! grep -Fq 'release create' "$MOCK_GH_CALLS"

: > "$MOCK_GH_CALLS"
export MOCK_RELEASE_EXISTS=false
bash "$repo_root/Scripts/publish-github-release.sh" \
  nightly-20261018-abc123 "$asset_path" Flash-1.1.0.zip 'Flash nightly' true abc123
grep -Fq -- '--prerelease --notes Automated build from abc123.' "$MOCK_GH_CALLS"

echo 'release publication tests ok'
