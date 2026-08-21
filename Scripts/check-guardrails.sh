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
  # The protocol-v1 redefinition retired these wire names outright (repo
  # rule 9: no compatibility shims) — none may reappear as wire strings in
  # the host or the Rust SDK.
  check_absent \
    "retired protocol wire names must not reappear" \
    '"(sources\.snapshot|sources\.query|query\.evaluate|hints\.discover|candidate\.resolve|source\.action|command\.invoke|navigation\.restore|heartbeat|sources\.invalidated|status\.updated|flash\.log)"' \
    Sources/flash Plugins/_flash_plugin_rust

  check_absent \
    "candidate catalog gathering is SDK-owned; plugins cannot define candidate_query" \
    "candidate_query" \
    Plugins

  # Query evaluators stay synchronous CPU-only hooks — an async evaluate in
  # a plugin or SDK would put I/O on the 50 ms per-keystroke path.
  check_absent \
    "query evaluators are synchronous CPU-only hooks" \
    "async fn evaluate\\(" \
    Plugins

  # Every SDK (and the host) hardcodes the one protocol version; a drift
  # here means a stale SDK shipping against a redefined wire. Pattern-based
  # on purpose — the SDKs are rewritten wholesale and only the constant is
  # contractual (naming varies per language convention).
  for sdk in \
    Plugins/_flash_plugin_rust/src/runtime.rs \
    Plugins/_flash_plugin_python/flashplugin.py \
    Plugins/_flash_plugin_ruby/flashplugin.rb \
    Plugins/_flash_plugin_typescript/flashplugin.ts \
    Plugins/_flash_plugin_go/flashplugin.go \
    Plugins/_flash_plugin_zig/flashplugin.zig \
    Plugins/_flash_plugin_swift/flashplugin.swift; do
    [[ -f "$sdk" ]] || {
      echo "GUARDRAIL FAILED: missing SDK file: $sdk" >&2
      fail=1
      continue
    }
    if ! rg -qi 'protocol_?version(:\s*\w+)?\s*=\s*1\b' "$sdk"; then
      echo "GUARDRAIL FAILED: $sdk must pin PROTOCOL_VERSION = 1" >&2
      fail=1
    fi
  done
  if ! rg -q 'static let version = 1\b' Sources/flash/App/Plugins/PluginProtocol.swift; then
    echo "GUARDRAIL FAILED: PluginProtocol.swift must pin protocol version 1" >&2
    fail=1
  fi

  # The Rust-SDK contract greps apply only to Rust plugins (src/main.rs);
  # non-Rust official plugins satisfy the same push-catalog contract through
  # host-side runtime enforcement (quotas, deadlines) instead of source greps.
  for manifest in Plugins/*/manifest.json; do
    plugin_dir="${manifest%/manifest.json}"
    # Hermetic-crate invariants: every Rust plugin is a standalone crate with
    # a committed lock and a byte-identical copy of the canonical clippy
    # config (Plugins/_flash_plugin_rust/clippy.toml) — no workspace anywhere.
    if [[ -f "$plugin_dir/Cargo.toml" ]]; then
      if rg -q 'workspace' "$plugin_dir/Cargo.toml"; then
        echo "GUARDRAIL FAILED: hermetic plugin crates must not reference a cargo workspace: $plugin_dir" >&2
        fail=1
      fi
      if ! cmp -s "$plugin_dir/clippy.toml" Plugins/_flash_plugin_rust/clippy.toml; then
        echo "GUARDRAIL FAILED: Rust plugin must carry the canonical clippy.toml: $plugin_dir" >&2
        fail=1
      fi
      if [[ ! -f "$plugin_dir/Cargo.lock" ]]; then
        echo "GUARDRAIL FAILED: hermetic plugin crate must commit its Cargo.lock: $plugin_dir" >&2
        fail=1
      fi
    fi
    source="$plugin_dir/src/main.rs"
    [[ -f "$source" ]] || continue
    if rg -q '^[[:space:]]*"sources"[[:space:]]*:' "$manifest"; then
      # Warm sources push their catalog; live sources (all-or-nothing per
      # plugin) serve per-keystroke search instead and never publish.
      if rg -q '"live"[[:space:]]*:[[:space:]]*true' "$manifest"; then
        if ! rg -q 'fn on_search' "$source"; then
          echo "GUARDRAIL FAILED: live-sources plugin must implement on_search: $plugin_dir" >&2
          fail=1
        fi
      elif ! rg -q 'publish[[:space:]]*\(' "$source"; then
        echo "GUARDRAIL FAILED: sources plugin must push-publish its catalog: $plugin_dir" >&2
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
