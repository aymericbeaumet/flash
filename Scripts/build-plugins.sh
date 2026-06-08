#!/usr/bin/env bash
set -euo pipefail

# Compile every bundled Rust plugin and drop its release binary next to
# the plugin's manifest.json as `flash-plugin-<id>`. The manifest's
# `start` execs that binary directly — there is no cargo at runtime.
#
# A single shared CARGO_TARGET_DIR keeps build artifacts out of the
# individual plugin directories (so the dev file-watcher never sees a
# `target/` storm) and lets the plugins share compiled dependencies.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"

for manifest in Plugins/*/Cargo.toml; do
  [[ -e "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  id="$(basename "$dir")"
  bin="flash-plugin-$id"
  echo "==> Building plugin $id"
  (cd "$dir" && cargo build --release)
  cp "$TARGET_DIR/release/$bin" "$dir/$bin"
  chmod +x "$dir/$bin"
done
