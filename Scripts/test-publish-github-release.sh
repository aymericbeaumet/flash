#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_GH_CALLS"
if [[ "$1 $2" == "release view" ]]; then
  [[ "$MOCK_RELEASE_EXISTS" == "true" ]] || exit 1
  if [[ " $* " == *" --json assets "* ]]; then
    printf '%s\n' "$MOCK_ASSETS"
  fi
fi
EOF
chmod +x "$test_dir/gh"

export PATH="$test_dir:$PATH"
export MOCK_GH_CALLS="$test_dir/calls"
asset_path="$test_dir/Flash-1.1.0.zip"
touch "$asset_path"

export MOCK_RELEASE_EXISTS=false MOCK_ASSETS=''
bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123
grep -Fqx "release create 1.1.0 $asset_path#Flash-1.1.0.zip --target abc123 --title Flash 1.1.0 --generate-notes" "$MOCK_GH_CALLS"

: > "$MOCK_GH_CALLS"
export MOCK_RELEASE_EXISTS=true MOCK_ASSETS=Flash-1.1.0.zip
bash "$repo_root/Scripts/publish-github-release.sh" \
  1.1.0 "$asset_path" Flash-1.1.0.zip 'Flash 1.1.0' false abc123
! grep -Fq 'release create' "$MOCK_GH_CALLS"

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
