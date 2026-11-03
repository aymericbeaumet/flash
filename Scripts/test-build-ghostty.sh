#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Exercise the real bootstrap without a framework or slice cache. An archive
# nested in a tagged host repository must not use that repository's version.
mkdir -p "$test_dir/Scripts"
cp "$repo_root/Scripts/build-ghostty.sh" "$test_dir/Scripts/"
cp "$repo_root/Scripts/build-ghostty-notices.py" "$test_dir/Scripts/"
cp -R "$repo_root/Scripts/ghostty-notices" "$test_dir/Scripts/ghostty-notices"
git -C "$test_dir" init --quiet
git -C "$test_dir" -c user.name=Test -c user.email=test@example.com \
  -c commit.gpgsign=false commit --quiet --allow-empty -m 'Test host repository'
git -C "$test_dir" -c tag.gpgsign=false tag 1.1.0
mkdir -p "$test_dir/bin"
export GHOSTTY_TEST_REAL_ZIG="$(command -v zig)"
export GHOSTTY_TEST_ZIG_CALLS="$test_dir/zig-build-calls"
cat > "$test_dir/bin/zig" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == build ]]; then printf 'build\n' >> "$GHOSTTY_TEST_ZIG_CALLS"; fi
exec "$GHOSTTY_TEST_REAL_ZIG" "$@"
EOF
chmod +x "$test_dir/bin/zig"
export PATH="$test_dir/bin:$PATH"
export ZIG_GLOBAL_CACHE_DIR="$test_dir/zig-cache"
# A worktree tool copying dotfiles leaves the source directory holding only
# Ghostty's .envrc: an unfinished source tree must be extracted again.
revision="$(sed -n 's/^revision=//p' "$test_dir/Scripts/build-ghostty.sh")"
mkdir -p "$test_dir/build/ghostty/ghostty-$revision"
touch "$test_dir/build/ghostty/ghostty-$revision/.envrc"
bash "$test_dir/Scripts/build-ghostty.sh" --dev

test -s "$test_dir/build/ghostty/ghostty-vt.xcframework/Info.plist"
test -s "$test_dir/build/ghostty/ghostty-vt.xcframework/.flash-build"
notices="$test_dir/build/ghostty/ghostty-vt.xcframework/ThirdPartyNotices.txt"
for author in 'simdutf authors' 'Facebook' 'Highway Project Authors' 'Wuffs Authors' 'Jacob Sandlund' 'UNICODE LICENSE V3'; do
  grep -Fq "$author" "$notices"
done
# A cache missing its notices must repair itself, reusing completed slices.
build_calls="$(cat "$GHOSTTY_TEST_ZIG_CALLS")"
notice_hash="$(shasum -a 256 "$notices" | cut -d ' ' -f 1)"
rm "$notices"
bash "$test_dir/Scripts/build-ghostty.sh" --dev
[[ "$(cat "$GHOSTTY_TEST_ZIG_CALLS")" == "$build_calls" ]]
[[ "$(shasum -a 256 "$notices" | cut -d ' ' -f 1)" == "$notice_hash" ]]
echo 'Tagged-host Ghostty bootstrap test passed'
