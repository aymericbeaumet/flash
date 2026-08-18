#!/usr/bin/env bash
set -euo pipefail

# Compile the bundled Rust plugins and drop each binary next to its
# manifest.json as `flash-plugin-<id>`. The manifest's `start` execs that
# binary directly — there is no cargo at runtime.
#
# All requested plugins build through ONE workspace-aware cargo invocation
# (single dependency-graph resolution, maximal parallelism across crates).
# A single shared CARGO_TARGET_DIR keeps build artifacts out of the
# individual plugin directories (so the dev file-watcher never sees a
# `target/` storm) and lets the plugins share compiled dependencies.
#
# Usage: build-plugins.sh [dev|release] [id…]
#   dev       — `plugin-dev` cargo profile (opt-level=1, line-tables-only
#               debuginfo; see Plugins/Cargo.toml) for the current machine
#               arch only. Incremental, no lipo; signed with the stable dev
#               identity so TCC grants (Reminders, Notes, …) persist across
#               rebuilds.
#   release   — optimized universal binary (x86_64 + arm64) via lipo.
#   id…       — optional plugin ids (directory names under Plugins/). When
#               present, build and stage only those:
#               `build-plugins.sh dev tmux` is the single-plugin hot loop.

MODE="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
ONLY=("$@")

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"

if [[ "$MODE" == "release" ]]; then
  # Make sure both Apple targets are available; harmless if already added.
  rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
fi

# A real plugin is defined by its manifest.json; support crates such as the
# shared SDK at Plugins/_rust_flash_plugin have none and are built only as
# dependencies.
plugin_dirs=()
for manifest in Plugins/*/Cargo.toml; do
  [[ -e "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  [[ -f "$dir/manifest.json" ]] || continue
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

pkg_args=()
for dir in "${plugin_dirs[@]}"; do
  pkg_args+=(-p "flash-plugin-$(basename "$dir")")
done

echo "==> Building ${#plugin_dirs[@]} plugin(s) ($MODE)"
if [[ "$MODE" == "release" ]]; then
  cargo build --manifest-path Plugins/Cargo.toml --release \
    --target x86_64-apple-darwin \
    --target aarch64-apple-darwin \
    "${pkg_args[@]}"
else
  cargo build --manifest-path Plugins/Cargo.toml --profile plugin-dev \
    "${pkg_args[@]}"
fi

# Stage every binary at a temp path, sign the staged files, then swap each
# in with an atomic `mv`. Overwriting the destination *in place* (cp/lipo
# writing to the existing path) modifies an already-signed Mach-O's bytes,
# which invalidates the kernel's cached code-signature and makes the next
# exec die with "Killed: 9". A rename installs a fresh inode whose
# signature the kernel re-evaluates cleanly. Signing BEFORE the rename
# matters too: the dev file-watcher's restart debounce starts at the
# rename, so the binary must already carry its final signature when it
# lands — plugin binaries that hit TCC-gated APIs (reminders, notes via
# AppleScript, …) get re-prompted on every cdhash change unless their
# designated-requirement clause matches the same stable cert the host
# bundle uses.
staged_paths=()
for dir in "${plugin_dirs[@]}"; do
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

if [[ "$MODE" != "release" && -n "${DEV_PLUGIN_SIGN_IDENTITY:-}" && ${#staged_paths[@]} -gt 0 ]]; then
  codesign --force \
    --sign "$DEV_PLUGIN_SIGN_IDENTITY" \
    "${staged_paths[@]}" >/dev/null
fi

for staged in "${staged_paths[@]}"; do
  mv -f "$staged" "${staged%.staged}"
done
