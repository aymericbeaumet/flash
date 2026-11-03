#!/usr/bin/env bash
set -euo pipefail

# The cask CI writes for each release: valid Ruby, the release's version, URL
# and checksum, and `auto_updates true` so `brew upgrade` does not fight the
# in-app updater (docs/updates.md).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() {
  echo "test-update-homebrew-cask: $*" >&2
  exit 1
}

# The generator's heredoc is unquoted: a backtick in it, even in a comment,
# would run a command (once, `brew upgrade`) while writing the cask.
if grep -n '`' "$repo_root/Scripts/update-homebrew-cask.sh"; then
  fail "no backticks in update-homebrew-cask.sh: its heredoc would run them"
fi

sha="$(printf 'release' | shasum -a 256 | awk '{print $1}')"
cask="$("$repo_root/Scripts/update-homebrew-cask.sh" \
  --tap-dir "$test_dir/tap" --token flash --version 1.2.0 \
  --url "https://github.com/aymericbeaumet/flash/releases/download/1.2.0/Flash-1.2.0.zip" \
  --sha256 "$sha")"

[[ "$cask" == "$test_dir/tap/Casks/flash.rb" ]] || fail "unexpected cask path $cask"
grep -qx '  auto_updates true' "$cask" || fail "the cask must declare auto_updates true"
for stanza in \
  '  manpage "#{appdir}/Flash.app/Contents/Resources/flash.1"' \
  '  bash_completion "#{appdir}/Flash.app/Contents/Resources/completions/flash.bash"' \
  '  zsh_completion "#{appdir}/Flash.app/Contents/Resources/completions/_flash"' \
  '  fish_completion "#{appdir}/Flash.app/Contents/Resources/completions/flash.fish"'; do
  grep -qxF "$stanza" "$cask" || fail "the cask must link: $stanza"
done
grep -qx '  version "1.2.0"' "$cask" || fail "missing version"
# Homebrew refuses the install below the app's own LSMinimumSystemVersion.
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/Resources/Info.plist")"
case "${minimum%%.*}" in
  13) codename=ventura ;;
  14) codename=sonoma ;;
  15) codename=sequoia ;;
  26) codename=tahoe ;;
  *) fail "no Homebrew codename for macOS $minimum" ;;
esac
grep -qxF "  depends_on macos: \">= :$codename\"" "$cask" ||
  fail "the cask must require macOS $minimum (:$codename)"
grep -qx "  sha256 \"$sha\"" "$cask" || fail "missing sha256"
grep -q 'releases/download/1.2.0/Flash-1.2.0.zip' "$cask" || fail "missing url"
if grep -n '^==>' "$cask"; then fail "command output leaked into the cask"; fi
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$cask" >/dev/null || fail "the cask is not valid Ruby"
fi
echo "test-update-homebrew-cask: ok"
