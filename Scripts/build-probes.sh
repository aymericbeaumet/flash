#!/usr/bin/env bash
set -euo pipefail

# Build the compiled per-language conformance probes under
# Plugins/_flash_plugin_specs/probes/ and drop each binary next to its
# manifest.json as `flash-plugin-conformance` (the manifest's exec).
# Interpreted probes (python/ruby/typescript) run in place — nothing to
# build. No signing: probes only ever run under the spec runner
# (Scripts/plugin-protocol-spec.py --probes), never under the host, and the
# probes tree is deliberately invisible to Scripts/build-plugins.sh (it
# globs Plugins/*/manifest.json one level deep).
#
# Mirrors Scripts/build-plugins.sh dev-mode flags per language; artifacts
# land under build/plugin-target so the watched plugin trees stay clean.
#
# Usage: build-probes.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PROBES_DIR="$PROJECT_DIR/Plugins/_flash_plugin_specs/probes"
TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"
OUT_DIR="$TARGET_DIR/probes"
mkdir -p "$OUT_DIR"

BIN="flash-plugin-conformance"

echo "==> Building conformance probe (rust)"
cargo build --manifest-path "$PROBES_DIR/rust/Cargo.toml" --profile plugin-dev
cp "$TARGET_DIR/plugin-dev/$BIN" "$PROBES_DIR/rust/$BIN"

echo "==> Building conformance probe (go)"
(cd "$PROBES_DIR/go" && env GOFLAGS=-trimpath CGO_ENABLED=0 \
  mise exec go -- go build -o "$OUT_DIR/$BIN-go" .)
cp "$OUT_DIR/$BIN-go" "$PROBES_DIR/go/$BIN"

echo "==> Building conformance probe (zig)"
(cd "$PROBES_DIR/zig" && mise exec zig -- zig build-exe \
  -O ReleaseSafe -lc -femit-bin="$OUT_DIR/$BIN-zig" \
  --dep flashplugin -Mroot=main.zig \
  -Mflashplugin=../../../_flash_plugin_zig/flashplugin.zig)
cp "$OUT_DIR/$BIN-zig" "$PROBES_DIR/zig/$BIN"

echo "==> Building conformance probe (swift)"
(cd "$PROBES_DIR/swift" && xcrun swiftc -O \
  main.swift ../../../_flash_plugin_swift/flashplugin.swift -o "$OUT_DIR/$BIN-swift")
cp "$OUT_DIR/$BIN-swift" "$PROBES_DIR/swift/$BIN"

chmod +x "$PROBES_DIR/rust/$BIN" "$PROBES_DIR/go/$BIN" \
  "$PROBES_DIR/zig/$BIN" "$PROBES_DIR/swift/$BIN"
echo "==> Probes built (python/ruby/typescript run in place)"
