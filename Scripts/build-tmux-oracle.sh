#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=3.7b
checksum=87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96
unicode_version=2.11.3
unicode_checksum=abfed50b6d4da51345713661370290f4f4747263ee73dc90356299dfc7990c78
cache="$PWD/build/tmux-oracle"
binary="$cache/bin/tmux"
stamp="$version-$unicode_version-$(uname -m)"
mkdir -p "$cache/bin"

exact_version() {
  [[ -x "$1" && "$("$1" -V)" == "tmux $version" ]]
}

if [[ -f "$cache/.flash-build" && "$(cat "$cache/.flash-build")" == "$stamp" ]] && exact_version "$binary"; then
  echo "$binary"
  exit 0
fi
# A system tmux version string cannot identify its Unicode width library.
# Keep the oracle's utf8proc static and pinned as well as the tmux release.

archive="$cache/tmux-$version.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl -fLsS --retry 3 "https://github.com/tmux/tmux/releases/download/$version/tmux-$version.tar.gz" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
[[ "$actual" == "$checksum" ]] || { echo 'tmux oracle source checksum mismatch' >&2; exit 1; }

if command -v brew >/dev/null 2>&1; then
  event_prefix=$(brew --prefix libevent)
  curses_prefix=$(brew --prefix ncurses)
  export PKG_CONFIG_PATH="$event_prefix/lib/pkgconfig:$curses_prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi
command -v pkg-config >/dev/null 2>&1 || { echo 'Install pkg-config, libevent, and ncurses to build the tmux oracle.' >&2; exit 1; }
pkg-config --exists libevent ncurses || { echo 'Install libevent and ncurses development dependencies.' >&2; exit 1; }

unicode_archive="$cache/utf8proc-$unicode_version.tar.gz"
if [[ ! -f "$unicode_archive" ]]; then
  curl -fLsS --retry 3 "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$unicode_version.tar.gz" -o "$unicode_archive.part"
  mv "$unicode_archive.part" "$unicode_archive"
fi
actual=$(shasum -a 256 "$unicode_archive" | cut -d ' ' -f 1)
[[ "$actual" == "$unicode_checksum" ]] || { echo 'utf8proc oracle source checksum mismatch' >&2; exit 1; }
tar -xzf "$unicode_archive" -C "$cache"
unicode_source="$cache/utf8proc-$unicode_version"
make -C "$unicode_source" libutf8proc.a > "$cache/unicode-build.log" 2>&1 || {
  echo "utf8proc oracle build failed; inspect $cache/unicode-build.log" >&2; exit 1;
}
export LIBUTF8PROC_CFLAGS="-I$unicode_source"
export LIBUTF8PROC_LIBS="$unicode_source/libutf8proc.a"

source_dir="$cache/tmux-$version"
tar -xzf "$archive" -C "$cache"
# Never install through a stale symlink to a system executable.
[[ ! -L "$binary" ]] || rm "$binary"
(
  cd "$source_dir"
  ./configure --prefix="$cache" --enable-utf8proc > "$cache/configure.log" 2>&1 &&
  make clean > "$cache/clean.log" 2>&1 &&
  make -j "$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" > "$cache/build.log" 2>&1 &&
  make install > "$cache/install.log" 2>&1
) || { echo "tmux oracle build failed; inspect $cache/{configure,build,install}.log" >&2; exit 1; }
exact_version "$binary" || { echo 'tmux oracle binary version mismatch' >&2; exit 1; }
echo "$stamp" > "$cache/.flash-build"
echo "$binary"
