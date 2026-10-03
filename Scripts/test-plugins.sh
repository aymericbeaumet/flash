#!/usr/bin/env bash
set -euo pipefail

# The one-command plugin gate: Rust lint, unit tests and dev builds for the
# SDK workspace (flash_plugin, its proc macro and the wire probe) and every
# bundled plugin crate. Protocol conformance is the SDK's own cargo test
# suite — Plugins/_flash_plugin_rust/protocol.json pins the constants, the
# wire/runtime tests and the probe crate pin the behaviour — so the units
# lane is where wire behaviour is proven.
#
# Usage: test-plugins.sh [--lane lint|units|build|all]…
#
# Lanes (all = every lane, the CI plugin-gate job's body):
#   lint    cargo fmt --check + clippy for the SDK workspace and every
#           plugin crate
#   units   the plugin publication test (Scripts/test-build-plugins.py) and
#           per-crate `cargo test --locked` for the SDK workspace + all
#           plugin crates
#   build   dev build of every executable plugin (Scripts/build-plugins.sh dev)

LANES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      case "${2:-}" in
        lint | units | build | all) LANES+=("$2") ;;
        *)
          echo "unknown lane: ${2:-}" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    *)
      echo "usage: test-plugins.sh [--lane lint|units|build|all]..." >&2
      exit 2
      ;;
  esac
done
((${#LANES[@]})) || LANES=(all)

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CARGO_TARGET_DIR="$PROJECT_DIR/build/plugin-target"

want() {
  local lane
  for lane in "${LANES[@]}"; do
    [[ "$lane" == "$1" || "$lane" == "all" ]] && return 0
  done
  return 1
}

# The SDK workspace (which includes the probe member) plus every hermetic
# plugin crate. `cd` (not --manifest-path) is load-bearing: clippy discovers
# each crate's clippy.toml by walking up from the cwd.
crate_dirs() {
  local dir
  for dir in Plugins/_flash_plugin_rust Plugins/[!_]*/; do
    [[ -f "$dir/Cargo.toml" ]] && printf '%s\n' "$dir"
  done
}

if want lint; then
  echo "==> lint: Rust"
  while IFS= read -r dir; do
    (cd "$dir" &&
      cargo fmt --all --check &&
      cargo clippy --workspace --all-targets --locked -- -D warnings)
  done < <(crate_dirs)
fi

if want units; then
  echo "==> units: plugin publication"
  python3 Scripts/test-build-plugins.py
  echo "==> units: per-crate cargo test"
  while IFS= read -r dir; do
    (cd "$dir" && cargo test --workspace --locked --quiet)
  done < <(crate_dirs)
fi

if want build; then
  echo "==> build: plugins (dev)"
  ./Scripts/build-plugins.sh dev
fi

echo "test-plugins: done"
