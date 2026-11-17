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

# Hard constraint 4: the resident listens in exactly three places. Its IPC
# socket is one Unix domain socket (IPCServer, with IPCEndpoint's bind),
# never TCP; besides it only the loopback help server (DebugServer) and the
# opt-in OTLP receiver (OTLPReceiver) accept connections. No other listener,
# Mach service or XPC listener, and no Apple Event command handler: `flash`
# reaches the resident over the socket, and the retired `Flsh`/`Cmd ` event
# is not spelled anywhere it once was (rule 7: no dual paths).
check_absent_except \
  "listeners are IPCServer's socket, DebugServer and OTLPReceiver" \
  "NWListener\\(|[^A-Za-z_.]listen\\(|Darwin\\.bind\\(|CFMessagePortCreateLocal|NSXPCListener|xpc_connection_create_mach_service|bootstrap_check_in" \
  '^Sources/flash/App/(IPC/IPCServer|IPC/IPCEndpoint|DebugServer|Telemetry/OTLPReceiver)\.swift:' \
  "${PROD_SWIFT[@]}"
check_absent \
  "the IPC socket is a Unix domain socket, never TCP" \
  "AF_INET|NWListener|NWParameters|NWConnection" \
  Sources/flash/App/IPC Sources/flash/IPCClient.swift
check_absent \
  "no Apple Event command handler: commands arrive over the IPC socket" \
  "NSAppleEventManager|AEInstallEventHandler|Flsh" \
  Sources Resources AGENTS.md SECURITY.md README.md docs config.default.toml

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

# App knowledge is plugin data: what an app does for a Flash command is the
# winning manifest `bindings` entry, dispatched by CommandBindingDispatch.
# Virtual key constants therefore appear only where Flash parses or names
# keys (hotkey syntax, the keyboard layout, NORMAL's key names, Escape
# detection), brackets UIKit modifiers, or applies the terminal rule — never
# as a chord a command synthesizes.
check_absent_except \
  "no kVK_ chord synthesis for app commands outside the binding dispatcher" \
  "kVK_" \
  '/(HotkeySyntax|KeyboardLayout|UIKitApps|NormalModeTerminalChords)\.swift:|/NormalMode\.swift:[0-9]+:[[:space:]]*case kVK_|/AppDelegate\.swift:[0-9]+:.*== Int64\(kVK_Escape\)' \
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

# Accessibility / CGEvent (top-left) and NSScreen (bottom-left) coordinates
# convert about the primary display's height in exactly one place:
# `ScreenSpace.flip`, behind the typed `ScreenPoint` / `ScreenRect`
# `toAX` / `toNS` conversions. An inline `height - y` anywhere else is the
# mix-up the types exist to prevent.
check_absent_except \
  "AX/NSScreen Y conversions go through ScreenPoint/ScreenRect (ScreenSpace.swift)" \
  '(^|[^A-Za-z_])(screenH|primaryH|primaryHeight|screenHeight|primaryScreenHeight)(\(\))? *- *[A-Za-z_(.]*(y|Y|minY|maxY)([^A-Za-z_]|$)|y: *[A-Za-z_.]*[Hh]eight[A-Za-z_.]* *- *[A-Za-z_.()]*\.(y|minY|maxY)([^A-Za-z_]|$)' \
  '/ScreenSpace\.swift:' \
  "${PROD_SWIFT[@]}"

check_absent_except \
  "Raw coordinate flips stay private to ScreenSpace.swift" \
  'ScreenSpace\.flip\(' \
  '/ScreenSpace\.swift:' \
  "${PROD_SWIFT[@]}"

# Flash writes one Apple preference: NativeMenuBarAutoHide owns the menu
# bar's auto-hide, and reverses only what it set. Every other preference is
# the user's, set from `[startup] run` with the system's own tools. Flash's
# own code writes no plist file and runs no `defaults`, which cfprefsd's
# cache would overwrite or never see.
check_absent_except \
  "Apple preferences are written only by NativeMenuBarAutoHide" \
  "CFPreferencesSetValue|CFPreferencesSetAppValue|CFPreferencesSetMultiple" \
  '/NativeMenuBarAutoHide\.swift:' \
  "${PROD_SWIFT[@]}"
check_absent \
  "no defaults(1) subprocess" \
  "/usr/bin/defaults" \
  "${PROD_SWIFT[@]}"

# Mode entry changes capture over the current app. App commands and committed
# clicks own activation; a cached NORMAL PID must never become an INSERT target.
check_absent \
  "mode events and effects never target application activation" \
  'targetPID|case[[:space:]]+[[:alnum:]_]*[Aa]ctivat' \
  Sources/flash/App/Mode

# Host RPC queue hops must validate the requesting transport when dequeued,
# before any input, activation, storage or AX operation can affect the host.
check_absent \
  "queued host RPC work must use its transport scope" \
  '\.async(After)?([^[:alnum:]_]|$)|scope:[[:space:]]+PluginHostRequestScope[[:space:]]*=' \
  Sources/flash/App/Plugins/PluginHostRPC.swift Sources/flash/App/Plugins/AXBroker.swift

# A bare-name executable resolution that misses its cache spawns `mise which`,
# which can stall for seconds while syspolicyd is busy. It runs only on a
# plugin's queue and the doctor's background queue, never on the main
# thread's keyboard path.
check_absent_except \
  "executable resolution stays off the main thread" \
  "resolveExecutable\\(" \
  '^Sources/flash/App/Plugins/(PluginSandbox|PluginProcess|PluginDoctor)\.swift:' \
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
# A registration's priority and its handler queue's QoS must match: a
# `system` or `high` wake-up planned onto a `.utility` queue is starved under
# load however tight its slack (AGENTS.md, docs/architecture.md). Pairs each
# `register`/`scheduleOnce`/`PollDeadline` at those priorities with the
# `on:` queue it names and fails when that queue is declared `.utility` in
# the same file.
if ! python3 -I - "${RUNTIME_SWIFT[@]}" <<'PY'
import pathlib, re, sys

utility = re.compile(
    r"(?:let|var)\s+(\w+)(?:\s*:\s*DispatchQueue)?\s*=\s*DispatchQueue\(\s*label:[^)]*?qos:\s*\.utility",
    re.S)
default_param = re.compile(
    r"(\w+)\s*:\s*DispatchQueue\s*=\s*DispatchQueue\(\s*label:[^)]*?qos:\s*\.utility", re.S)
registration = re.compile(
    r"(?:register|scheduleOnce|PollDeadline)\((?:(?!\n\s*\n).){0,400}?priority:\s*\.(?:system|high)"
    r"(?:(?!\n\s*\n).){0,200}?on:\s*([\w.]+)",
    re.S)
failed = False
for root in sys.argv[1:]:
    for file in sorted(pathlib.Path(root).rglob("*.swift")):
        text = file.read_text(encoding="utf-8")
        names = set(utility.findall(text)) | set(default_param.findall(text))
        if not names:
            continue
        for match in registration.finditer(text):
            queue = match.group(1).split(".")[-1]
            if queue in names:
                line = text.count("\n", 0, match.start()) + 1
                print(f"{file}:{line}: system/high registration on utility queue `{queue}`")
                failed = True
sys.exit(1 if failed else 0)
PY
then
  echo "GUARDRAIL FAILED: system/high poll registrations run on user-initiated queues" >&2
  fail=1
fi

# Blocking sleeps only inside one bounded operation, never as a loop's clock:
# - ActionDispatcher.swift: the spacing of one synthesized mouse gesture on
#   the click queue (down/up hold, drag steps);
# - ProcessTable.swift: the CPU measurement window of a pid read for the
#   first time, on the reader's background queue;
# - TerminalSession.swift: the 1 ms back-off inside a bounded wait for one
#   child's exit when the kqueue wait itself fails.
check_absent_except \
  "blocking sleeps stay inside one bounded operation" \
  "Thread\\.sleep|usleep\\(|[^[:alnum:]_.]sleep\\(|nanosleep\\(" \
  '^Sources/flash/App/ActionDispatcher\.swift:|^Sources/flash/App/ProcessTable\.swift:|^Sources/FlashTerminal/TerminalSession\.swift:' \
  "${RUNTIME_SWIFT[@]}"

# Every production app AX element must carry a bounded messaging timeout, or a
# wedged app beachballs Flash's main thread for the 6s system default. The
# AXApp.make factory applies the timeout; nothing else may call the raw API.
check_absent_except \
  "app AX elements must be created via AXApp.make (bounded messaging timeout)" \
  "AXUIElementCreateApplication\\(" \
  'AXApp\.swift' \
  "${PROD_SWIFT[@]}"

# A timeout set on a system-wide AX element is the process-wide default for
# every AX call. AXApp sets it once at launch and hands out the element;
# nothing else creates one, so no probe can rewrite every walk's bound.
check_absent_except \
  "system-wide AX elements come from AXApp.systemWide (one process timeout)" \
  "AXUIElementCreateSystemWide\\(" \
  'AXApp\.swift' \
  "${PROD_SWIFT[@]}"

# Flash activates itself only through AppActivation, which does nothing in
# the test runner: an xctest process that activates takes the keyboard from
# the user's app, and its transparent test windows swallow the keys.
check_absent_except \
  "self-activation and activation policy go through AppActivation" \
  "(NSApp|NSApplication\\.shared)\\.activate\\(|setActivationPolicy\\(|NSRunningApplication\\.current\\.activate\\(|[^.]current\\.activate\\((from|options)" \
  'AppActivation\.swift|/main\.swift' \
  "${PROD_SWIFT[@]}"

# macOS 13's URL(string:) and URLComponents(string:) return nil for a string
# macOS 14 repairs (a space, a non-ASCII path or host). Every string Flash did
# not write as a literal parses through URLParsing, which repairs it the same
# way on both.
check_absent_except \
  "URL strings parse through URLParsing (same result on every supported macOS)" \
  "(NSURL|URL|URLComponents)\\(string: [^\"]" \
  'FlashCore/URLParsing\.swift' \
  "${PROD_SWIFT[@]}" Sources/FlashTerminal

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
  "the help show command is routed to the alert toast instead of the help overlay" \
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

check_absent \
  "no references to removed bundled plugins" \
  "windows\\.items|kitty\\.windows|github\\.(repos|prs)|spotify_player|kitten @|httpstatus\\.codes|flash-plugin-reference|flash\\.plugin\\.tmux\\.|\\[plugin\\.tmux\\]|flash-plugin-tmux|flash-plugin-history|flash\\.plugin\\.(cpu|memory|disks|network|power)\\.|\\[plugin\\.(cpu|memory|disks|network|power)\\]|flash-plugin-(cpu|memory|disks|network|power)|flash-plugin-marks|flash-plugin-vscode|Plugins/vscode/" \
  Sources README.md docs config.default.toml

if [[ -d Plugins ]]; then
  # The protocol-v1 redefinition retired these wire names outright (repo
  # rule 9: no compatibility shims) — none may reappear as wire strings in
  # the host or the Rust SDK.
  check_absent \
    "retired protocol wire names must not reappear" \
    '"(sources\.snapshot|sources\.query|query\.evaluate|hints\.discover|candidate\.resolve|source\.action|command\.invoke|navigation\.restore|heartbeat|sources\.invalidated|status\.updated|flash\.log)"' \
    Sources/flash Plugins/_flash_plugin_rust

  # Flash has one vocabulary for what it asks of the focused app: commands.
  # A plugin performs a core command through a `commands[]` entry under one
  # of Flash's topics, `bindings` keyed by the command line say what an app
  # does for one, and `confirm` on the entry gates a destructive one. The
  # retired source-action vocabulary (manifest actions, action bindings and
  # confirmations, the `action` perform kind and its SDK types) must not
  # reappear anywhere it was spelled (rule 7: no dual readers). The one
  # allowed site is the SDK runtime test that pins the retired kind as
  # unknown.
  check_absent_except \
    "retired action vocabulary must not reappear" \
    'action_bindings|action_confirmations|"actions"[[:space:]]*[:)]|kind"?:[[:space:]]*"action"|on_action|ActionRequest|SourceActionName|SourceAction\b' \
    'Plugins/_flash_plugin_rust/src/runtime\.rs:[0-9]+:.*decode_perform\(json!\(\{ "kind": "action"' \
    Sources/flash Sources/FlashCore Sources/FlashProviders Plugins/*/manifest.json \
    Plugins/_flash_plugin_rust/src Plugins/_flash_plugin_rust/macros Plugins/_flash_plugin_rust/probe \
    Plugins/*/src docs AGENTS.md README.md config.default.toml Inspector/src

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
    [[ -f "$plugin_dir/src/main.rs" ]] || continue
    # Plugin sources are warm: each pushes its complete catalog, whole or
    # source by source, from whichever module of the crate owns it.
    if search_paths -q '^[[:space:]]*"sources"[[:space:]]*:' "$manifest" &&
      ! search_paths -q 'publish(_source)?[[:space:]]*\(' "$plugin_dir/src"; then
      echo "GUARDRAIL FAILED: sources plugin must push-publish its catalog: $plugin_dir" >&2
      fail=1
    fi
  done

  check_absent \
    "plugin installs must stay localized to FLASH_PLUGIN_DATA_DIR" \
    "(^|[^[:alnum:]_])sudo($|[^[:alnum:]_])|brew install|npm install -g|deno install -g|/usr/local/bin|\\$HOME/\\.local/bin|~/\\.local/bin" \
    Plugins
fi

# The help serves the manual from the app bundle at /docs/<page>: nothing the
# resident or its pages render links the published copy. docs/nav.json alone
# names the site's URL, and the renderer turns a link into it into a local one.
check_absent \
  "the help links its bundled manual (/docs/<page>), never the published site" \
  'aymericbeaumet\.github\.io' \
  Sources Inspector/src config.default.toml Plugins/*/manifest.json

# Every command is `flash <topic> <action>`: no default, doc, help text or
# bundled manifest names a one-word command in an argv, and every bundled
# plugin command is two words of [a-z][a-z0-9_]*. CommandGrammarTests holds
# the command table and plugin loading to the same shape.
check_absent \
  "every Flash command is two words: flash <topic> <action>" \
  '"flash",[[:space:]]*"[a-z][a-z0-9_]*"[[:space:]]*(\]|,[[:space:]]*"--)' \
  config.default.toml README.md AGENTS.md docs Inspector/src Plugins/*/manifest.json \
  Sources/flash/App/HelpDocs.swift Sources/flash/App/NormalMode/HelpText.swift

if ! plugin_command_report="$(python3 - <<'PY'
import json
import pathlib
import re

word = re.compile(r"[a-z][a-z0-9_]*\Z")
bad = []
for path in sorted(pathlib.Path("Plugins").glob("*/manifest.json")):
    for command in json.loads(path.read_text()).get("commands", []):
        pair = (command.get("command", ""), command.get("subcommand", ""))
        if not all(word.match(part) for part in pair):
            bad.append(f"{path}: flash {pair[0]} {pair[1]}")
print("\n".join(bad))
raise SystemExit(1 if bad else 0)
PY
)"; then
  echo "GUARDRAIL FAILED: bundled plugin commands are two words of [a-z][a-z0-9_]*" >&2
  echo "$plugin_command_report" >&2
  fail=1
fi

if tracked="$(git ls-files -- 'Tests/BrowserSnapshots/snapshots/collected-*' 'Tests/BrowserSnapshots/allowlists/collected-*')" &&
  [[ -n "$tracked" ]]; then
  echo "GUARDRAIL FAILED: collected browser captures are personal browsing data and must stay untracked" >&2
  echo "$tracked" >&2
  fail=1
fi

# mise is the single developer environment: tools, environment and tasks live
# in mise.toml, and Scripts/ holds what the tasks run. No other task runner or
# task file exists; every task is described and runs scripts that exist; every
# script is reachable from a task or another script; and no guide, workflow or
# message tells a developer to call a script, or a tool through `mise exec`,
# instead of `mise run <task>`. The task table in docs/development.md lists
# exactly the tasks, and only it names the script behind each one.
if ! dev_env_report="$(python3 - <<'PY'
import os
import pathlib
import re
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:
    print("python3 has no tomllib (3.11+): use 'mise run guardrails'")
    sys.exit(1)

VENDORED = {"build", ".build", "node_modules", "target"}
RUNNER = re.compile(r"(?:gnu)?makefile|\.?justfile|taskfile(?:\.dist)?\.ya?ml", re.IGNORECASE)
FILE_TASKS = re.compile(r"(?:^|/)(?:\.?mise-tasks|\.?mise/tasks|\.config/mise/tasks)/")
MISE_CONFIG = re.compile(
    r"(?:^|/)(?:\.?mise(?:\.[\w-]+)?\.toml|\.tool-versions|\.?mise/config\.toml|\.config/mise(?:/config)?\.toml)$"
)
SCRIPT = re.compile(r"(?<![\w./-])(\./)?(Scripts/[\w.-]+)")
MISE_EXEC = re.compile(r"\bmise\s+(?:exec|x)\b")
INVOKE = re.compile(
    r"(?:\./|\b(?:bash|sh|zsh|python3?|source|exec)\s+(?:\./)?"
    r"|\b[Rr]un:?\s+(?:\x60|<code>)?(?:\./)?|\$\(\s*(?:\./)?)(Scripts/[\w.-]+)"
)
RUN_HINT = re.compile(r"\b[Rr]un:?\s+(?:\x60|<code>)?(?:\./)?(Scripts/[\w.-]+)")
SPAN_WITH_ARGS = re.compile(r"\x60(?:\./)?(Scripts/[\w.-]+)\s[^\x60]*\x60")
FENCE = re.compile(r"^\s*(?:\x60{3,}|~{3,})")
FENCED_COMMAND = re.compile(r"^\s*(?:\$\s+)?(?:\w+=\S*\s+)*(?:\./)?(Scripts/[\w.-]+)")
CODE_ROOTS = {"Sources", "Tests", "Scripts", "Plugins", "Inspector"}
CODE_SUFFIXES = {".swift", ".sh", ".py", ".rs", ".ts", ".svelte"}

failures = []


def git_files(*arguments):
    try:
        output = subprocess.run(
            ["git", "ls-files", "-z", *arguments], check=True, capture_output=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [path for path in output.decode().split("\0") if path]


tracked = git_files("--cached")
present = git_files("--cached", "--others", "--exclude-standard")
if tracked is None or present is None:
    present = []
    for root, directories, names in os.walk("."):
        directories[:] = [name for name in directories if name not in VENDORED | {".git"}]
        present += [os.path.relpath(os.path.join(root, name)) for name in names]
    tracked = present
present = [
    path for path in present
    if os.path.isfile(path) and not VENDORED.intersection(path.split("/")[:-1])
]

for path in present:
    if RUNNER.fullmatch(path.rsplit("/", 1)[-1]):
        failures.append(f"{path}: another task runner; define a task in mise.toml")
    elif FILE_TASKS.search(path):
        failures.append(f"{path}: a file task; define the task in mise.toml")
for path in tracked:
    if path != "mise.toml" and MISE_CONFIG.search(path):
        failures.append(f"{path}: a second mise configuration; tools, env and tasks live in mise.toml")

try:
    config = tomllib.loads(pathlib.Path("mise.toml").read_text())
    tasks = config.get("tasks", {})
except (OSError, tomllib.TOMLDecodeError) as error:
    print(f"mise.toml: {error}")
    sys.exit(1)
if not tasks:
    failures.append("mise.toml: no tasks")

# A tool pin without its platform downloads silently loses reproducibility.
try:
    locked_tools = tomllib.loads(pathlib.Path("mise.lock").read_text())["tools"]
except (OSError, KeyError, tomllib.TOMLDecodeError) as error:
    failures.append(f"mise.lock: {error}")
    locked_tools = {}
requests = dict(config.get("tools", {}))
for task in tasks.values():
    if isinstance(task, dict):
        requests.update(task.get("tools", {}))
for name, request in requests.items():
    version = request.get("version", "") if isinstance(request, dict) else request
    pattern = r"[0-9]+\.[0-9]+" if name == "protoc" else r"[0-9]+(?:\.[0-9]+){2}"
    if not re.fullmatch(pattern, str(version)):
        failures.append(f"mise.toml: {name} needs an exact version")
    entries = [entry for entry in locked_tools.get(name, []) if entry.get("version") == version]
    if len(entries) != 1:
        failures.append(f"mise.lock: {name}@{version} is missing or ambiguous; run mise lock")
    elif name not in {"rust", "cargo:cargo-about"}:
        for platform in config.get("settings", {}).get("lockfile_platforms", []):
            download = entries[0].get(f"platforms.{platform}", {})
            if not download.get("url") or not download.get("checksum"):
                failures.append(f"mise.lock: {name}@{version} lacks {platform} download integrity")

runs = {}
for name, task in tasks.items():
    where = f"mise.toml: task {name}"
    if not isinstance(task, dict):
        failures.append(f"{where}: not a table")
        continue
    if not str(task.get("description", "")).strip():
        failures.append(f"{where}: no description")
    steps = task.get("run", [])
    steps = steps if isinstance(steps, list) else [steps]
    if not steps and "file" not in task:
        failures.append(f"{where}: runs nothing")
    references = []
    for key in ("depends", "depends_post", "wait_for"):
        value = task.get(key, [])
        references += [value] if isinstance(value, str) else value
    for step in steps:
        if isinstance(step, dict):
            references += [step["task"]] if "task" in step else step.get("tasks", [])
            continue
        for match in SCRIPT.finditer(step):
            script = pathlib.Path(match.group(2))
            if not script.is_file():
                failures.append(f"{where}: runs missing {script}")
            elif match.group(1) and not os.access(script, os.X_OK):
                failures.append(f"{where}: runs ./{script}, which is not executable")
            runs.setdefault(str(script), []).append(name)
    if "file" in task and not pathlib.Path(str(task["file"])).is_file():
        failures.append(f"{where}: runs missing {task['file']}")
    for reference in references:
        reference = (reference[0] if isinstance(reference, list) else reference).split()[0]
        if reference not in tasks:
            failures.append(f"{where}: refers to unknown task {reference}")

scripts = sorted(path for path in present if re.fullmatch(r"Scripts/[^/]+\.(?:sh|py)", path))
texts = {path: pathlib.Path(path).read_text(errors="replace") for path in scripts}
for script in scripts:
    name = script.rsplit("/", 1)[-1]
    if script in runs or any(name in text for path, text in texts.items() if path != script):
        continue
    failures.append(f"{script}: no task or script runs it; add a task to mise.toml")

documented = re.findall(
    r"^\| \x60([^\x60]+)\x60 \|", pathlib.Path("docs/development.md").read_text(), re.MULTILINE
)
for name in sorted(set(tasks) - set(documented)):
    failures.append(f"docs/development.md: the task table lacks {name}")
for name in sorted(set(documented) - set(tasks)):
    failures.append(f"docs/development.md: the task table lists {name}, which mise.toml lacks")


def task_hint(script):
    names = runs.get(script)
    if names:
        return "use " + " or ".join(f"'mise run {name}'" for name in sorted(set(names)))
    return "add a task to mise.toml for this entry point"


guides = [
    path for path in present
    if path.endswith(".md") or (path.startswith(".github/") and path.endswith((".yml", ".yaml")))
]
for path in guides:
    fenced = False
    for number, line in enumerate(pathlib.Path(path).read_text(errors="replace").splitlines(), 1):
        if path.endswith(".md") and FENCE.match(line):
            fenced = not fenced
            continue
        where = f"{path}:{number}"
        if MISE_EXEC.search(line):
            failures.append(f"{where}: mise exec; run a task instead")
        if path == "docs/development.md" and line.startswith("| \x60"):
            continue
        found = {match.group(1) for match in INVOKE.finditer(line)}
        found |= {match.group(1) for match in SPAN_WITH_ARGS.finditer(line)}
        if fenced:
            found |= {match.group(1) for match in FENCED_COMMAND.finditer(line)}
        for script in sorted(found):
            failures.append(f"{where}: calls {script} directly; {task_hint(script)}")

for path in present:
    if (
        path == "Scripts/check-guardrails.sh"
        or path.split("/", 1)[0] not in CODE_ROOTS
        or pathlib.Path(path).suffix not in CODE_SUFFIXES
    ):
        continue
    for number, line in enumerate(pathlib.Path(path).read_text(errors="replace").splitlines(), 1):
        for match in RUN_HINT.finditer(line):
            script = match.group(1)
            failures.append(f"{path}:{number}: tells developers to run {script}; {task_hint(script)}")

print("\n".join(failures))
sys.exit(1 if failures else 0)
PY
)"; then
  echo "GUARDRAIL FAILED: mise is the single developer environment (tools, env and tasks in mise.toml)" >&2
  echo "$dev_env_report" >&2
  fail=1
fi

# Diagnostics go through FlashLog's serial writer: the CLI's own usage text is
# the one stdout print in the resident's sources.
check_absent_except \
  "diagnostics go through FlashLog (no print, NSLog or debugPrint in the resident)" \
  "^[[:space:]]*(print|NSLog|debugPrint)\\(" \
  '^Sources/flash/FlashCLI\.swift:' \
  "${RUNTIME_SWIFT[@]}"

# Every literal log message names its event `[area] event`
# (docs/observability.md); values go in `fields`. The area is one snake_case
# word (`LogAreaTests` pins the set); an interpolated area is checked there.
if ! log_name_report="$(python3 -I - "${RUNTIME_SWIFT[@]}" <<'PY'
import pathlib, re, sys

patterns = [
    re.compile(r'FlashLog\.(?:trace|debug|info|warn|error)\(\s*"(?!\[)'),
    re.compile(r'FlashLog\.log\(\s*[^,()]+,\s*"(?!\[)'),
    re.compile(r'FlashLog\.plugin\([^"]{0,200}?message:\s*"(?!\[)', re.S),
]
area = re.compile(r'"\[([^\]"]+)\] ')
word = re.compile(r'[a-z][a-z0-9_]*')
failures = []
for root in sys.argv[1:]:
    for file in sorted(pathlib.Path(root).rglob("*.swift")):
        text = file.read_text(encoding="utf-8")
        for pattern in patterns:
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                failures.append(f"{file}:{line}: log message does not start with [area]")
        for match in area.finditer(text):
            name = match.group(1)
            if "\\(" in name or word.fullmatch(name):
                continue
            line = text.count("\n", 0, match.start()) + 1
            failures.append(f"{file}:{line}: [{name}] is not a snake_case area")
print("\n".join(failures))
sys.exit(1 if failures else 0)
PY
)"; then
  echo "GUARDRAIL FAILED: log messages are named [area] event, the area one snake_case word" >&2
  echo "$log_name_report" >&2
  fail=1
fi

# Every GitHub Action runs at a full commit, never a movable tag or branch:
# `uses: owner/repo@<40 hex> # vX.Y.Z` (supply-chain pinning).
unpinned_actions="$(grep -En '^[[:space:]]*(-[[:space:]]*)?uses:' .github/workflows/*.yml |
  grep -Ev 'uses:[[:space:]]*[^[:space:]@]+@[0-9a-f]{40}([[:space:]]+#[[:space:]]*v[0-9][^[:space:]]*)?[[:space:]]*$' || true)"
if [[ -n "$unpinned_actions" ]]; then
  echo "GUARDRAIL FAILED: workflow actions are pinned to a full commit with a # vX.Y.Z comment" >&2
  echo "$unpinned_actions" >&2
  fail=1
fi

# An unquoted heredoc runs its backticks as commands: a comment in the
# Homebrew cask template once ran brew upgrade on a developer's Mac. Write
# $(...) when a substitution is meant, or quote the heredoc's delimiter.
if ! heredoc_report="$(python3 - <<'PY'
import pathlib, re, sys
opener = re.compile(r"<<(-?)\s*([A-Za-z_][A-Za-z0-9_]*)\b")
failures = []
for path in sorted(pathlib.Path("Scripts").rglob("*.sh")):
    lines = path.read_text(errors="replace").splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        match = None if line.lstrip().startswith("#") else opener.search(line)
        if not match:
            continue
        strip, word = match.group(1) == "-", match.group(2)
        while index < len(lines):
            body = lines[index]
            index += 1
            if (body.lstrip("\t") if strip else body) == word:
                break
            if chr(96) in body:  # a backtick, spelled so bash 3.2 can parse this
                failures.append(f"{path}:{index}: backtick in an unquoted heredoc")
print("\n".join(failures))
sys.exit(1 if failures else 0)
PY
)"; then
  echo "GUARDRAIL FAILED: unquoted heredocs run backticks as commands" >&2
  echo "$heredoc_report" >&2
  fail=1
fi

# One macOS floor. Resources/Info.plist's LSMinimumSystemVersion is the
# source: Package.swift's platform (the compiler rejects any API newer than
# it outside an #available branch), the plugins' MACOSX_DEPLOYMENT_TARGET
# (Scripts/_common.sh) and the fixture bundles name the same version. An
# availability check at or below the floor is always true, and would hide
# the fallback its branch needs once the floor moves.
if ! floor_report="$(python3 - <<'PY'
import pathlib, plistlib, re, sys
failures = []
with open("Resources/Info.plist", "rb") as stream:
    floor = plistlib.load(stream)["LSMinimumSystemVersion"]
match = re.fullmatch(r"(\d+)\.0", floor)
if not match:
    sys.exit(f"Resources/Info.plist: LSMinimumSystemVersion {floor} is not a major release")
major = int(match.group(1))
if f"platforms: [.macOS(.v{major})]" not in pathlib.Path("Package.swift").read_text():
    failures.append(f"Package.swift: platforms must be [.macOS(.v{major})]")
if f'\nMACOS_MINIMUM="{floor}"\n' not in pathlib.Path("Scripts/_common.sh").read_text():
    failures.append(f"Scripts/_common.sh: MACOS_MINIMUM must be {floor}")
fixture = re.compile(r"<key>LSMinimumSystemVersion</key>\s*<string>([^<]*)</string>")
for path in sorted(pathlib.Path("Scripts").glob("test-integration-*.sh")):
    for value in fixture.findall(path.read_text()):
        if value != floor:
            failures.append(f"{path}: fixture LSMinimumSystemVersion {value}, not {floor}")
check = re.compile(r"[#@](?:un)?available\(\s*macOS\s+(\d+)((?:\.\d+)*)")
for root in ("Sources", "Tests"):
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for found in check.finditer(line):
                minor = [int(part) for part in found.group(2).split(".") if part]
                if int(found.group(1)) < major or (
                        int(found.group(1)) == major and not any(minor)):
                    failures.append(f"{path}:{number}: always true at the macOS {floor} floor")
print("\n".join(failures))
sys.exit(1 if failures else 0)
PY
)"; then
  echo "GUARDRAIL FAILED: the macOS floor is one version everywhere" >&2
  echo "$floor_report" >&2
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "guardrails ok"
