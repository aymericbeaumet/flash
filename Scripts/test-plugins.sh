#!/usr/bin/env bash
set -euo pipefail

# The one-command plugin test entry point: spec validation, Rust lint,
# per-crate unit tests, builds, and the full conformance matrix
# (bundled plugins + the Rust probe + the sandbox lane).
#
# Usage: test-plugins.sh [--lane validate|lint|units|build|conformance|all]…
#        test-plugins.sh --plugin <id> [--plugin <id>…]   # scoped conformance
# Extra flags are forwarded to the conformance runner (e.g. --report r.json
# --github-annotations --jobs 8).
#
# Lane inventory (all = the full pipeline, the CI conformance job's body):
#   validate     spec-file schema validation (fast, no processes)
#   lint         Rust fmt/clippy for the SDK and every executable plugin;
#                Python compile-check for the protocol test runner.
#   units        per-crate `cargo test --locked` for the SDK + all Rust
#                plugins (same loop CI runs)
#   build        all compiled plugins (dev profile) + the conformance probes
#   conformance  runner --all, --probes, and --sandbox (builds the flash
#                binary for profile generation if missing)

MODE_ARGS=()
LANES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)
      LANES+=("$2")
      shift 2
      ;;
    *)
      MODE_ARGS+=("$1")
      shift
      ;;
  esac
done
((${#LANES[@]})) || LANES=(all)

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CARGO_TARGET_DIR="$PROJECT_DIR/build/plugin-target"
RUNNER=(python3 Scripts/plugin-protocol-spec.py)

want() {
  local lane
  for lane in "${LANES[@]}"; do
    [[ "$lane" == "$1" || "$lane" == "all" ]] && return 0
  done
  return 1
}

if want validate; then
  echo "==> validate: spec schema"
  "${RUNNER[@]}" --validate-only
fi

if want lint; then
  echo "==> lint: Rust"
  for dir in Plugins/_flash_plugin_rust Plugins/[!_]*/ \
    Plugins/_flash_plugin_specs/probes/rust; do
    [[ -f "$dir/Cargo.toml" ]] || continue
    (cd "$dir" &&
      cargo fmt --all --check &&
      cargo clippy --workspace --all-targets --locked -- -D warnings)
  done
  echo "==> lint: Python protocol runner"
  python3 -m py_compile Scripts/plugin-protocol-spec.py Scripts/flash_spec_runner/*.py
fi

if want units; then
  echo "==> units: per-crate cargo test"
  for dir in Plugins/_flash_plugin_rust Plugins/[!_]*/; do
    [[ -f "$dir/Cargo.toml" ]] || continue
    (cd "$dir" && cargo test --workspace --locked --quiet)
  done
fi

if want build; then
  echo "==> build: plugins (dev) + probes"
  ./Scripts/build-plugins.sh dev
  ./Scripts/build-probes.sh
fi

if want conformance; then
  echo "==> conformance: bundled matrix"
  "${RUNNER[@]}" --all ${MODE_ARGS[@]+"${MODE_ARGS[@]}"}
  echo "==> conformance: probe matrix"
  "${RUNNER[@]}" --probes ${MODE_ARGS[@]+"${MODE_ARGS[@]}"}
  echo "==> conformance: sandbox lane"
  FLASH_BIN=".build/debug/flash"
  [[ -x "$FLASH_BIN" ]] || swift build --product flash
  "${RUNNER[@]}" --sandbox --flash-bin "$FLASH_BIN" ${MODE_ARGS[@]+"${MODE_ARGS[@]}"}
fi

# Scoped conformance shortcut: test-plugins.sh --plugin tmux
if ! want validate && ! want lint && ! want units && ! want build && ! want conformance &&
  ((${#MODE_ARGS[@]})); then
  "${RUNNER[@]}" ${MODE_ARGS[@]+"${MODE_ARGS[@]}"}
fi

echo "test-plugins: done"
