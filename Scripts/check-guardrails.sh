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

check_absent \
  "no keyboard event taps or private event capture" \
  "CGEventTap|CGEventCreateTap|\\.tapCreate\\(" \
  "${PROD_SWIFT[@]}"

check_absent \
  "no global keyboard monitors" \
  "addGlobalMonitorForEvents\\(matching:.*(keyDown|keyUp|flagsChanged)" \
  Sources/flash

check_absent \
  "no screen capture, OCR, or pixel capture" \
  "ScreenCaptureKit|VisionProvider|VNRecognize|NSScreenCaptureUsageDescription|CGWindowListCreateImage|CGDisplayStream" \
  Sources Resources

check_absent_except \
  "no production menu bar, Dock, status, or alert UI" \
  "NSStatusItem|NSStatusBar|NSDockTile|NSAlert|NSMenuBarExtra|NSMenu\\(|NSMenuItem|\\.mainMenu|setActivationPolicy\\(\\.regular" \
  'NSStatusBar\.system\.thickness|NSWindow\.Level = \.mainMenu|app\.mainMenu\?\.menuBarHeight|previousMenu = app\.mainMenu|app\.mainMenu = previousMenu|app\.mainMenu = measurementMenu|NSMenu\(title: "Flash"\)|NSMenuItem\(title: "Flash"' \
  Sources/flash Resources/Info.plist

check_absent \
  "flash://help_show is routed to the alert toast instead of the help overlay" \
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
    "plugin installs must stay localized to FLASH_PLUGIN_DATA_DIR" \
    "sudo|brew install|npm install -g|deno install -g|/usr/local/bin|\\$HOME/\\.local/bin|~/\\.local/bin" \
    Plugins
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "guardrails ok"
