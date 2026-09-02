#!/usr/bin/env bash
set -euo pipefail

# Build every executable bundled plugin as a hermetic Rust crate and drop
# each binary next to its manifest.json as `flash-plugin-<id>`. Plugins with
# no Cargo.toml are manifest-only and have no process to build.
#
# All build artifacts land under build/plugin-target (never inside the
# watched plugin trees, so the dev file-watcher never sees intermediate
# files). Rust is rustup-managed for its multi-target universal builds.
#
# Usage: build-plugins.sh [dev|release] [id…]
#   dev       — native-arch `plugin-dev` build, signed with the stable dev
#               identity so TCC grants persist across rebuilds.
#   release   — optimized universal binaries (x86_64 + arm64) via lipo.
#   id…       — optional plugin ids; `build-plugins.sh dev tmux` is the
#               single-plugin hot loop.

MODE="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
ONLY=("$@")

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"
mkdir -p "$TARGET_DIR"

if [[ "$MODE" == "release" ]]; then
  # Make sure both Apple targets are available; harmless if already added.
  rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
fi

# A real plugin is defined by its manifest.json; support crates such as the
# shared SDK at Plugins/_flash_plugin_rust have none and are built only as
# dependencies.
plugin_dirs=()
for manifest in Plugins/*/manifest.json; do
  [[ -e "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  if ((${#ONLY[@]})); then
    keep=0
    for want in "${ONLY[@]}"; do
      [[ "$want" == "$(basename "$dir")" ]] && keep=1
    done
    ((keep)) || continue
  fi
  plugin_dirs+=("$dir")
done

# Reject typo'd ids loudly instead of silently building nothing. (The
# ${arr[@]+…} idiom keeps empty-array expansion safe under macOS bash 3.2's
# set -u.)
if ((${#ONLY[@]})); then
  fail=0
  for want in "${ONLY[@]}"; do
    found=0
    for dir in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do
      [[ "$(basename "$dir")" == "$want" ]] && found=1
    done
    if ((!found)); then
      echo "unknown plugin id: $want" >&2
      fail=1
    fi
  done
  ((fail)) && exit 1
fi

if ((${#plugin_dirs[@]} == 0)); then
  echo "no plugins found under Plugins/*/manifest.json" >&2
  exit 1
fi

build_dirs=()
for dir in "${plugin_dirs[@]}"; do
  [[ -f "$dir/Cargo.toml" ]] && build_dirs+=("$dir")
done

echo "==> Building ${#build_dirs[@]} compiled plugin(s) of ${#plugin_dirs[@]} selected ($MODE)"

# Rust plugins are hermetic standalone crates — one cargo invocation per dir.
# The shared CARGO_TARGET_DIR still dedupes SDK/dep artifacts across crates
# (cargo keys compiled artifacts by package-id + metadata hash). Release
# builds run --locked so a stale or missing committed Cargo.lock fails
# loudly; dev builds may refresh a lock during the hot loop (commit it).
for dir in "${build_dirs[@]}"; do
  if [[ "$MODE" == "release" ]]; then
    cargo build --manifest-path "$dir/Cargo.toml" --release --locked \
      --target x86_64-apple-darwin \
      --target aarch64-apple-darwin
  else
    cargo build --manifest-path "$dir/Cargo.toml" --profile plugin-dev
  fi
done

# Stage every binary at a temp path, sign the staged files, then swap each
# in with an atomic `mv`. Overwriting the destination *in place* modifies an
# already-signed Mach-O's bytes, which invalidates the kernel's cached
# code-signature and makes the next exec die with "Killed: 9". A rename
# installs a fresh inode whose signature the kernel re-evaluates cleanly.
# Signing BEFORE the rename matters too: the dev file-watcher's restart
# debounce starts at the rename, so the binary must already carry its final
# signature when it lands — TCC-gated plugins get re-prompted on every
# cdhash change unless their designated-requirement clause matches the same
# stable cert the host bundle uses.
staged_paths=()
for dir in "${build_dirs[@]}"; do
  id="$(basename "$dir")"
  bin="flash-plugin-$id"
  staged="$dir/$bin.staged"
  if [[ "$MODE" == "release" ]]; then
    lipo -create \
      "$TARGET_DIR/x86_64-apple-darwin/release/$bin" \
      "$TARGET_DIR/aarch64-apple-darwin/release/$bin" \
      -output "$staged"
  else
    cp "$TARGET_DIR/plugin-dev/$bin" "$staged"
  fi
  chmod +x "$staged"
  staged_paths+=("$staged")
done

if [[ "$MODE" != "release" && -n "${DEV_PLUGIN_SIGN_IDENTITY:-}" ]] &&
  ((${#staged_paths[@]} > 0)); then
  codesign --force \
    --sign "$DEV_PLUGIN_SIGN_IDENTITY" \
    ${staged_paths[@]+"${staged_paths[@]}"} >/dev/null
fi

for staged in ${staged_paths[@]+"${staged_paths[@]}"}; do
  mv -f "$staged" "${staged%.staged}"
done
