#!/usr/bin/env bash
set -euo pipefail

# Compile every bundled Rust plugin and drop its binary next to the
# plugin's manifest.json as `flash-plugin-<id>`. The manifest's `start`
# execs that binary directly — there is no cargo at runtime.
#
# A single shared CARGO_TARGET_DIR keeps build artifacts out of the
# individual plugin directories (so the dev file-watcher never sees a
# `target/` storm) and lets the plugins share compiled dependencies.
#
# Usage: build-plugins.sh [dev|release]
#   dev       — debug build for the current machine arch only. Favors speed:
#               no optimization, incremental, rebuilds only what changed.
#   release   — optimized universal binary (x86_64 + arm64) via lipo.

MODE="${1:-release}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"

if [[ "$MODE" == "release" ]]; then
  # Make sure both Apple targets are available; harmless if already added.
  rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
fi

for manifest in Plugins/*/Cargo.toml; do
  [[ -e "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  # A real plugin is defined by its manifest.json; skip support crates such
  # as the shared SDK at Plugins/_flash_plugin_rust, which has none.
  [[ -f "$dir/manifest.json" ]] || continue
  id="$(basename "$dir")"
  bin="flash-plugin-$id"
  echo "==> Building plugin $id ($MODE)"
  # Stage the new binary at a temp path and swap it in with an atomic
  # `mv`. Overwriting the destination *in place* (cp/lipo writing to the
  # existing path) modifies an already-signed Mach-O's bytes, which
  # invalidates the kernel's cached code-signature and makes the next
  # exec die with "Killed: 9". A rename installs a fresh inode whose
  # signature the kernel re-evaluates cleanly.
  staged="$dir/$bin.staged"
  if [[ "$MODE" == "release" ]]; then
    (cd "$dir" && cargo build --release \
      --target x86_64-apple-darwin \
      --target aarch64-apple-darwin)
    lipo -create \
      "$TARGET_DIR/x86_64-apple-darwin/release/$bin" \
      "$TARGET_DIR/aarch64-apple-darwin/release/$bin" \
      -output "$staged"
  else
    # dev: debug, current arch, incremental — the fast path.
    (cd "$dir" && cargo build)
    cp "$TARGET_DIR/debug/$bin" "$staged"
  fi
  chmod +x "$staged"
  mv -f "$staged" "$dir/$bin"
done
