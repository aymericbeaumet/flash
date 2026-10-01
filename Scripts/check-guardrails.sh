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

# `CGWindowListCopyWindowInfo` off the main thread deadlocks against a
# main-thread Core Animation commit until SkyLight's 500 ms timeout, freezing
# main with it. `WindowSnapshot.windowList` is the one door and always runs the
# read on main.
check_absent_except \
  "window-list reads go through WindowSnapshot.windowList (main thread only)" \
  "CGWindowListCopyWindowInfo\\(" \
  '/WindowSnapshot\.swift:' \
  "${PROD_SWIFT[@]}"

# Polling is a last resort and goes through PollScheduler, the one clock in
# the process: a cadence registers, an irregular or re-arming deadline uses
# `scheduleOnce` or `PollDeadline`. No other timer source exists in runtime
# code, and nothing sleeps a task to schedule work. One-shot `asyncAfter`
# stays legal only for a timeout bounding one operation, the fixed timing of
# an interaction in progress, or a bounded fan-out of settle passes after one
# event (docs/architecture.md lists them); anything that re-arms itself rides
# the scheduler.
RUNTIME_SWIFT=("${PROD_SWIFT[@]}" Sources/FlashTerminal)
check_absent_except \
  "recurring or deadline timers go through PollScheduler" \
  "DispatchSource\\.makeTimerSource|DispatchSourceTimer|Timer\\.scheduledTimer|Timer\\.publish|[^[:alnum:]_.]Timer\\(|CFRunLoopTimerCreate|Task\\.sleep|afterDelay:" \
  '^Sources/flash/App/PollScheduler\.swift:' \
  "${RUNTIME_SWIFT[@]}"
# Blocking sleeps only inside one bounded operation, never as a loop's clock:
# - ActionDispatcher.swift: the spacing of one synthesized mouse gesture on
#   the click queue (down/up hold, drag steps);
# - PluginHostRPC.swift: the measurement window of one `host.process_metrics`
#   call, on its own queue;
# - TerminalSession.swift: the 1 ms back-off inside a bounded wait for one
#   child's exit when the kqueue wait itself fails.
check_absent_except \
  "blocking sleeps stay inside one bounded operation" \
  "Thread\\.sleep|usleep\\(|[^[:alnum:]_.]sleep\\(|nanosleep\\(" \
  '^Sources/flash/App/ActionDispatcher\.swift:|^Sources/flash/App/Plugins/PluginHostRPC\.swift:|^Sources/FlashTerminal/TerminalSession\.swift:' \
  "${RUNTIME_SWIFT[@]}"

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

# Hard rule 1 names every UI surface; each draws in one of these windows. A new
# NSWindow/NSPanel subclass is a new surface and needs the rule amended first.
check_absent_except \
  "NSWindow/NSPanel subclasses are limited to the sanctioned surfaces" \
  "class [A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*(NSPanel|NSWindow)([^[:alnum:]_]|$)" \
  'class (OverlayPanel|StatusBarWindow|StatusBarClickPanel|StatusPopupPanel|AboutWindow|WidgetWindow)[[:space:]]*:' \
  "${PROD_SWIFT[@]}"

# Desktop widgets alone sit at desktop level (above the wallpaper, below the
# Finder's icons and every app window), and only in their own window.
check_absent_except \
  "desktop window levels belong to WidgetWindow" \
  "CGWindowLevelForKey\\(\\.desktop|kCGDesktop" \
  '/WidgetWindow\.swift:' \
  "${PROD_SWIFT[@]}"

# Widgets are click-through and never take focus.
widget_window=Sources/flash/App/Overlay/WidgetWindow.swift
if [[ ! -f "$widget_window" ]] || ! search_paths -q 'ignoresMouseEvents = true' "$widget_window"; then
  echo "GUARDRAIL FAILED: $widget_window must set ignoresMouseEvents = true" >&2
  fail=1
fi
check_absent \
  "widget windows never take mouse input or key/main focus" \
  "ignoresMouseEvents = false|canBecomeKey: Bool \\{ true|canBecomeMain: Bool \\{ true" \
  "$widget_window"

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

  # Plugins never arm a timer or sleep to schedule work: cadences, deadlines
  # and waits go through the host clock (`ctx.interval`, `ctx.after`,
  # `ctx.wait`, `Settle`), each at an explicit priority. Timeouts bounding one
  # awaited operation (`tokio::time::timeout`) stay legal. Test code (items
  # under `#[cfg(test)]`, including test-only module files) is exempt, as is
  # the SDK's wire probe, a test fixture that is never shipped or spawned.
  if ! plugin_timer_report="$(python3 - <<'PY'
import pathlib
import re
import sys

ROOT = pathlib.Path("Plugins")
BANNED = re.compile(
    r"\b(?:tokio::)?time::(?:sleep|sleep_until|interval|interval_at)\b"
    r"|\bthread::sleep\b"
    r"|use\s+tokio::time::\{[^}]*\b(?:sleep|sleep_until|interval|interval_at)\b"
)
SCHEDULING = re.compile(r"\.(?:interval|after|wait)\(|\bSettle::new\(")


def strip_comments(text):
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def blank(text, start, end):
    return text[:start] + re.sub(r"[^\n]", " ", text[start:end]) + text[end:]


def matching(text, start, opening, closing):
    depth = 0
    for index in range(start, len(text)):
        if text[index] == opening:
            depth += 1
        elif text[index] == closing:
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


def without_tests(path, text, test_files):
    for attribute in reversed(list(re.finditer(r"#\[cfg\(test\)\]", text))):
        rest = text[attribute.end():]
        declaration = re.match(r"\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;", rest)
        if declaration:
            base = path.parent if path.name in ("main.rs", "lib.rs", "mod.rs") else path.with_suffix("")
            test_files.add(base / f"{declaration.group(1)}.rs")
            test_files.add(base / declaration.group(1) / "mod.rs")
            text = blank(text, attribute.start(), attribute.end() + declaration.end())
            continue
        semicolon = text.find(";", attribute.end())
        brace = text.find("{", attribute.end())
        if brace == -1 or (semicolon != -1 and semicolon < brace):
            end = semicolon + 1
        else:
            end = matching(text, brace, "{", "}")
        text = blank(text, attribute.start(), end)
    return text


sources = {}
test_files = set()
for path in sorted(ROOT.rglob("*.rs")):
    parts = path.parts
    if "target" in parts or path.is_relative_to(ROOT / "_flash_plugin_rust" / "probe"):
        continue
    sources[path] = without_tests(path, strip_comments(path.read_text()), test_files)

failures = []
for path, text in sources.items():
    if path in test_files:
        continue
    for match in BANNED.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        failures.append(f"{path}:{line}: {match.group(0)} (use the host clock)")
    if path.parts[1].startswith("_"):
        continue
    for match in SCHEDULING.finditer(text):
        end = matching(text, match.end() - 1, "(", ")")
        arguments = text[match.end():end - 1]
        if match.group(0) == ".wait(" and not arguments.strip():
            continue
        if "PollPriority::" not in arguments:
            line = text.count("\n", 0, match.start()) + 1
            failures.append(f"{path}:{line}: {match.group(0)} without an explicit PollPriority")

print("\n".join(failures))
sys.exit(1 if failures else 0)
PY
)"; then
    echo "GUARDRAIL FAILED: plugins schedule through the host clock at an explicit priority" >&2
    echo "$plugin_timer_report" >&2
    fail=1
  fi

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

if tracked="$(git ls-files -- 'Tests/BrowserSnapshots/snapshots/collected-*' 'Tests/BrowserSnapshots/allowlists/collected-*')" &&
  [[ -n "$tracked" ]]; then
  echo "GUARDRAIL FAILED: collected browser captures are personal browsing data and must stay untracked" >&2
  echo "$tracked" >&2
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "guardrails ok"
