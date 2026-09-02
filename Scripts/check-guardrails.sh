#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

fail=0

if command -v rg >/dev/null 2>&1; then
  search_paths() {
    rg "$@"
  }
else
  search_paths() {
    grep -ER "$@"
  }
fi

check_absent() {
  local label="$1"
  local pattern="$2"
  shift 2
  local output
  if output="$(search_paths -n "$pattern" "$@" 2>/dev/null)"; then
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
  output="$(search_paths -n "$pattern" "$@" 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    output="$(printf '%s\n' "$output" | grep -Ev "$allowed" || true)"
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
  "NSStatusItem|NSStatusBar|NSDockTile|NSAlert|NSMenuBarExtra|NSMenu\\(|NSMenuItem|\\.mainMenu([^[:alnum:]_]|$)|setActivationPolicy\\(\\.regular" \
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

  # The Rust SDK and host hardcode the one protocol version; drift means a
  # stale implementation is shipping against the redefined wire.
  sdk=Plugins/_flash_plugin_rust/src/runtime.rs
  if ! search_paths -qi 'protocol_?version(:[[:space:]]*[[:alnum:]_]+)?[[:space:]]*=[[:space:]]*1([^[:alnum:]_]|$)' "$sdk"; then
    echo "GUARDRAIL FAILED: $sdk must pin PROTOCOL_VERSION = 1" >&2
    fail=1
  fi
  if ! search_paths -q 'static let version = 1([^[:alnum:]_]|$)' Sources/flash/App/Plugins/PluginProtocol.swift; then
    echo "GUARDRAIL FAILED: PluginProtocol.swift must pin protocol version 1" >&2
    fail=1
  fi

  for manifest in Plugins/*/manifest.json; do
    plugin_dir="${manifest%/manifest.json}"
    plugin_id="${plugin_dir##*/}"
    if search_paths -q '^[[:space:]]{2}"exec"[[:space:]]*:' "$manifest"; then
      if [[ ! -f "$plugin_dir/Cargo.toml" || ! -f "$plugin_dir/src/main.rs" ]]; then
        echo "GUARDRAIL FAILED: executable official plugin must be Rust: $plugin_dir" >&2
        fail=1
        continue
      fi
      if ! search_paths -q '"\./flash-plugin-'"$plugin_id"'"' "$manifest"; then
        echo "GUARDRAIL FAILED: official plugin exec must be ./flash-plugin-$plugin_id: $manifest" >&2
        fail=1
      fi
    fi
    # Hermetic-crate invariants: every executable plugin is a standalone
    # crate with a committed lock and canonical clippy config.
    if [[ -f "$plugin_dir/Cargo.toml" ]]; then
      if search_paths -q 'workspace' "$plugin_dir/Cargo.toml"; then
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
    if search_paths -q '^[[:space:]]*"sources"[[:space:]]*:' "$manifest"; then
      # Warm sources push their catalog; live sources (all-or-nothing per
      # plugin) serve per-keystroke search instead and never publish.
      if search_paths -q '"live"[[:space:]]*:[[:space:]]*true' "$manifest"; then
        if ! search_paths -q 'fn on_search' "$source"; then
          echo "GUARDRAIL FAILED: live-sources plugin must implement on_search: $plugin_dir" >&2
          fail=1
        fi
      elif ! search_paths -q 'publish[[:space:]]*\(' "$source"; then
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
