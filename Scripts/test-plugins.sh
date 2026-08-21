#!/usr/bin/env bash
set -euo pipefail

# The one-command plugin test entry point: spec validation, per-language
# lint, per-crate unit tests, builds, and the full conformance matrix
# (bundled plugins + the 7 conformance probes + the sandbox lane).
#
# Usage: test-plugins.sh [--lane validate|lint|units|build|conformance|all]…
#        test-plugins.sh --plugin <id> [--plugin <id>…]   # scoped conformance
# Extra flags are forwarded to the conformance runner (e.g. --report r.json
# --github-annotations --jobs 8).
#
# Lane inventory (all = the full pipeline, the CI conformance job's body):
#   validate     spec-file schema validation (fast, no processes)
#   lint         gofmt+go vet, zig fmt --check, ruby -cw, python compile,
#                bun syntax build, swift-format lint over Plugins/**/*.swift.
#                Deliberately minimal and dependency-free: rust fmt/clippy
#                live in the per-crate cargo loop (CI `plugins` job), and
#                heavier linters (ruff/tsc/rubocop) are out until they earn
#                their toolchain weight.
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
  echo "==> lint: go"
  for dir in Plugins/*/ Plugins/_flash_plugin_specs/probes/*/; do
    [[ -f "$dir/go.mod" ]] || continue
    unformatted="$(gofmt -l "$dir")"
    if [[ -n "$unformatted" ]]; then
      echo "gofmt needed:" "$unformatted" >&2
      exit 1
    fi
    (cd "$dir" && mise exec go -- go vet ./...)
  done
  echo "==> lint: zig fmt"
  mise exec zig -- zig fmt --check \
    Plugins/_flash_plugin_zig/flashplugin.zig \
    Plugins/*/main.zig \
    Plugins/_flash_plugin_specs/probes/zig/main.zig
  echo "==> lint: ruby -cw"
  for file in Plugins/_flash_plugin_ruby/flashplugin.rb Plugins/*/main.rb \
    Plugins/_flash_plugin_specs/probes/ruby/main.rb; do
    [[ -e "$file" ]] || continue
    mise exec ruby -- ruby -cw "$file" >/dev/null
  done
  echo "==> lint: python compile"
  mise exec python -- python3 -m py_compile \
    Plugins/_flash_plugin_python/flashplugin.py Plugins/*/main.py \
    Plugins/_flash_plugin_specs/probes/python/main.py \
    Scripts/plugin-protocol-spec.py Scripts/flash_spec_runner/*.py
  echo "==> lint: bun syntax"
  # Transpile-to-stdout is the parse check (an --outdir/--outfile write path
  # trips a bun bug on external bare specifiers); type errors are out of
  # scope — this pins syntax, the conformance matrix pins behavior.
  for file in Plugins/_flash_plugin_typescript/flashplugin.ts Plugins/*/main.ts \
    Plugins/_flash_plugin_specs/probes/typescript/main.ts; do
    [[ -e "$file" ]] || continue
    mise exec bun -- bun build --no-bundle "$file" >/dev/null
  done
  echo "==> lint: swift-format"
  xcrun swift format lint --strict --recursive \
    Plugins/_flash_plugin_swift Plugins/reminders Plugins/shortcuts \
    Plugins/_flash_plugin_specs/probes/swift
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
