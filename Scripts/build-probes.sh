#!/usr/bin/env bash
set -euo pipefail

# Build the Rust conformance probe under
# Plugins/_flash_plugin_specs/probes/ and drop each binary next to its
# manifest.json as `flash-plugin-conformance` (the manifest's exec).
# No signing: the probe only ever runs under the spec runner
# (Scripts/plugin-protocol-spec.py --probes), never under the host, and the
# probes tree is deliberately invisible to Scripts/build-plugins.sh (it
# globs Plugins/*/manifest.json one level deep).
#
# Mirrors Scripts/build-plugins.sh dev-mode flags; artifacts land under
# build/plugin-target so the watched plugin trees stay clean.
#
# Usage: build-probes.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PROBES_DIR="$PROJECT_DIR/Plugins/_flash_plugin_specs/probes"
TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"
BIN="flash-plugin-conformance"

echo "==> Building conformance probe (rust)"
cargo build --manifest-path "$PROBES_DIR/rust/Cargo.toml" --profile plugin-dev
cp "$TARGET_DIR/plugin-dev/$BIN" "$PROBES_DIR/rust/$BIN"
chmod +x "$PROBES_DIR/rust/$BIN"
echo "==> Rust probe built"
