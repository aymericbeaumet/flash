#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

fail=0

check_absent() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output
  if output="$(rg -n "$pattern" "$@" 2>/dev/null)"; then
    echo "GUARDRAIL FAILED: $label" >&2
    echo "$output" >&2
    fail=1
  fi
}

check_absent_except() {
  local label="$1"
  local pattern="$2"
  local allowed="$3"
  shift 3
  local output
  output="$(rg -n "$pattern" "$@" 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    output="$(printf '%s\n' "$output" | rg -v "$allowed" || true)"
  fi
  if [[ -n "$output" ]]; then
    echo "GUARDRAIL FAILED: $label" >&2
    echo "$output" >&2
    fail=1
  fi
}

PROD_SWIFT=(
  Sources/flash
  Sources/FlashCore
  Sources/FlashProviders
)

# NORMAL/hints capture is intentionally a session-level CGEventTap, confined to
# the single sanctioned file `KeyboardCaptureTap.swift` (see its header for the
# rationale: the old key-window model greyed the focused app and leaked keys
# during the normal→hints handoff). Any *other* production file reaching for a
# tap is still a hard failure.
check_absent_except \
  "no keyboard event taps or private event capture (outside KeyboardCaptureTap)" \
  "CGEventTap|CGEventCreateTap|\\.tapCreate\\(" \
  'KeyboardCaptureTap\.swift' \
  "${PROD_SWIFT[@]}"

# Every production app AX element must carry a bounded messaging timeout, or a
# wedged app beachballs Flash's main thread for the 6s system default. The
# AXApp.make factory applies the timeout; nothing else may call the raw API.
check_absent_except \
  "app AX elements must be created via AXApp.make (bounded messaging timeout)" \
  "AXUIElementCreateApplication\\(" \
  'AXApp\.swift' \
  "${PROD_SWIFT[@]}"

check_absent \
  "no global keyboard monitors" \
  "addGlobalMonitorForEvents\\(matching:.*(keyDown|keyUp|flagsChanged)" \
  Sources/flash

check_absent \
  "no screen capture, OCR, or pixel capture" \
  "ScreenCaptureKit|VisionProvider|VNRecognize|NSScreenCaptureUsageDescription|CGWindowListCreateImage|CGDisplayStream" \
  Sources Resources

# StatusItemController.swift is hard rule 1's single sanctioned
# NSStatusItem (About / Open Configuration / Quit, gated by
# [app] menu_bar_icon) — the whole file is exempt; everything else stays
# banned.
check_absent_except \
  "no production menu bar, Dock, status, or alert UI" \
  "NSStatusItem|NSStatusBar|NSDockTile|NSAlert|NSMenuBarExtra|NSMenu\\(|NSMenuItem|\\.mainMenu\\b|setActivationPolicy\\(\\.regular" \
  '^Sources/flash/App/StatusItemController\.swift:|NSStatusBar\.system\.thickness|NSWindow\.Level = \.mainMenu|app\.mainMenu\?\.menuBarHeight|previousMenu = app\.mainMenu|app\.mainMenu = previousMenu|app\.mainMenu = measurementMenu|NSMenu\(title: "Flash"\)|NSMenuItem\(title: "Flash"' \
  Sources/flash Resources/Info.plist

check_absent \
  "the help_show verb is routed to the alert toast instead of the help overlay" \
  "case \\.showUsage:.*alertPanel\\.show" \
  Sources/flash

check_absent \
  "no activation-time hints.keys parsing" \
  "Alphabet\\.resolve" \
  Sources/flash/App Sources/FlashCore Sources/FlashProviders

check_absent \
  "no stale removed config or provider references" \
  "performance\\.concurrent_walk|BrowserScriptProvider|cache_ttl|hints\\.scope|hints\\.layout|hints-layout|FLASH_HINTS_LAYOUT" \
  Sources README.md

if [[ -d Plugins ]]; then
  check_absent \
    "plugin wire methods use namespaced protocol-v2 names" \
    '"(discoverTargets|activateTarget|resolveCandidate|sourceAction)"' \
    Sources/flash Plugins/_rust_flash_plugin

  check_absent \
    "candidate catalog gathering is SDK-owned; plugins cannot define candidate_query" \
    "candidate_query" \
    Plugins

  check_absent \
    "query evaluators are synchronous CPU-only hooks" \
    "async fn query_evaluate" \
    Plugins

  # The Rust-SDK contract greps apply only to Rust plugins (src/main.rs);
  # non-Rust official plugins (python/ruby/bun/go/zig) satisfy the same
  # warm-catalog and sync-evaluator contracts through host-side runtime
  # enforcement (readiness gate, quotas, deadlines) instead of source greps.
  for manifest in Plugins/*/manifest.json; do
    plugin_dir="${manifest%/manifest.json}"
    source="$plugin_dir/src/main.rs"
    [[ -f "$source" ]] || continue
    if rg -q '^[[:space:]]*"sources"[[:space:]]*:' "$manifest"; then
      if ! rg -q 'async fn on_start' "$source"; then
        echo "GUARDRAIL FAILED: candidate plugin must implement on_start: $plugin_dir" >&2
        fail=1
      fi
      if ! rg -q 'set_locations[[:space:]]*\(' "$source"; then
        echo "GUARDRAIL FAILED: candidate plugin must publish warm locations: $plugin_dir" >&2
        fail=1
      fi
    fi
    if rg -q '^[[:space:]]*"queries"[[:space:]]*:' "$manifest"; then
      if ! rg -q 'fn query_evaluate[[:space:]]*\(' "$source"; then
        echo "GUARDRAIL FAILED: query plugin must implement synchronous query_evaluate: $plugin_dir" >&2
        fail=1
      fi
    fi
  done

  check_absent \
    "plugin installs must stay localized to FLASH_PLUGIN_DATA_DIR" \
    "sudo|brew install|npm install -g|deno install -g|/usr/local/bin|\\$HOME/\\.local/bin|~/\\.local/bin" \
    Plugins
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "guardrails ok"
