#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=3.8
checksum=e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e
unicode_version=2.12.0
unicode_checksum=f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111
event_version=2.1.13-stable
event_checksum=f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c
cache="$PWD/build/tmux-oracle"
binary="$cache/bin/tmux"
stamp="$version-$unicode_version-$event_version-$(uname -m)"
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

# libevent is pinned and static too, so the build needs nothing beyond the
# Xcode command-line tools: no Homebrew packages and no pkg-config.
event_archive="$cache/libevent-$event_version.tar.gz"
if [[ ! -f "$event_archive" ]]; then
  curl -fLsS --retry 3 "https://github.com/libevent/libevent/releases/download/release-$event_version/libevent-$event_version.tar.gz" -o "$event_archive.part"
  mv "$event_archive.part" "$event_archive"
fi
actual=$(shasum -a 256 "$event_archive" | cut -d ' ' -f 1)
[[ "$actual" == "$event_checksum" ]] || { echo 'libevent oracle source checksum mismatch' >&2; exit 1; }
tar -xzf "$event_archive" -C "$cache"
event_prefix="$cache/libevent"
rm -rf "$event_prefix"
(
  cd "$cache/libevent-$event_version"
  ./configure --prefix="$event_prefix" --disable-shared --disable-openssl --disable-samples \
    --disable-libevent-regress > "$cache/event-configure.log" 2>&1 &&
  make -j "$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" > "$cache/event-build.log" 2>&1 &&
  make install > "$cache/event-install.log" 2>&1
) || { echo "libevent oracle build failed; inspect $cache/event-{configure,build,install}.log" >&2; exit 1; }
export LIBEVENT_CORE_CFLAGS="-I$event_prefix/include"
export LIBEVENT_CORE_LIBS="$event_prefix/lib/libevent_core.a"

source_dir="$cache/tmux-$version"
tar -xzf "$archive" -C "$cache"
# Never install through a stale symlink to a system executable.
[[ ! -L "$binary" ]] || rm "$binary"
# tmux >= 3.7c links jemalloc on darwin whenever pkg-config finds it; keep
# the oracle independent of what the host has installed. Without pkg-config,
# configure takes the libraries above from their variables and falls back to
# the SDK's ncurses for terminfo.
(
  cd "$source_dir"
  PKG_CONFIG=false ./configure --prefix="$cache" --enable-utf8proc --disable-jemalloc > "$cache/configure.log" 2>&1 &&
  make clean > "$cache/clean.log" 2>&1 &&
  make -j "$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" > "$cache/build.log" 2>&1 &&
  make install > "$cache/install.log" 2>&1
) || { echo "tmux oracle build failed; inspect $cache/{configure,build,install}.log" >&2; exit 1; }
exact_version "$binary" || { echo 'tmux oracle binary version mismatch' >&2; exit 1; }
echo "$stamp" > "$cache/.flash-build"
echo "$binary"
