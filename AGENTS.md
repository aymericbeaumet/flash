# Flash contributor guide

Flash is a resident macOS app for keyboard-driven hints, normal/insert/command
modes, a configurable status bar, terminal popups and managed stdio plugins.
The `flash` executable is both CLI and resident. Read the relevant maintained
contracts before changing a subsystem:

- [Runtime ownership and determinism](docs/architecture.md).
- [Prepared hint models and refresh scheduling](docs/prepared-model.md).
- [Configuration and command boundaries](docs/configuration.md), with
  `config.default.toml` as the canonical reference.
- [Normal mode and input latency](docs/normal-mode.md).
- [Plugin protocol](docs/plugin-protocol.md), [Rust SDK](docs/plugin-rust-sdk.md),
  [cookbook](docs/plugin-cookbook.md), [performance](docs/plugin-performance.md).
- [Status format](docs/status-format.md), [status plugins](docs/status-plugins.md),
  [status popups](docs/status-popups.md), [terminal popups](docs/terminal-popups.md),
  [help](docs/help.md).

## Hard constraints

1. UI is confined to hint/grid overlays, advanced-mode status/command surfaces,
   help/open-app views, explicit alerts, About, and configured terminal popups.
   The sole `NSStatusItem` belongs to `StatusItemController.swift`, gated by
   `app.menu_bar_icon`, with exactly About / Open Configuration / Quit. No other
   status items, Dock tile, preferences window or `NSAlert`.
2. Global keyboard capture lives only in `KeyboardCaptureTap.swift` (session
   keyDown tap) and Carbon registrations for explicit modified-key mappings.
   The tap only decides swallow versus passthrough and routes permitted keys;
   it never logs, persists or exfiltrates keys. Command/modal typing goes through
   `NSPanel.keyDown`; the key-window path also supplies the no-tap fallback.
   No additional event taps or global key monitors.
3. Autolaunch is configuration-owned `AutoLaunch.reconcile` using SMAppService.
   No LaunchAgents, helpers or login-item UI. The installer only cleans up the
   retired LaunchAgent.
4. One resident process, bundle identifier `com.flash.app`. External activation
   uses the custom `Flsh`/`Cmd ` AppleEvent; native mappings dispatch in-process.
   Plugins are host-owned NDJSON stdio children, with stderr for diagnostics and
   stdin EOF for shutdown. No custom external IPC, sockets, Mach services,
   daemonized clients, `flash://` URL scheme or separate `flashctl` executable.
5. No OCR, Vision, ScreenCaptureKit, screenshots, pixel capture or Screen
   Recording permission. WindowServer metadata is allowed for geometry and
   occlusion only. Accessibility is the grant for AX and the keyboard tap; do
   not add Input Monitoring requests.
6. Empty target discovery stays silent. Never show a no-targets banner.
7. No backward-compatibility shims. Renames update code, bundled plugins,
   defaults, tests, docs and affected `~/.config/flash/flash.toml` entries together.
   Reject malformed input; do not add aliases, dual wire readers, old-name type
   aliases, deprecations or transitional accept-both paths.
8. Providers describe target geometry and semantics; `ActionDispatcher` owns
   every committed host mouse event. There are only two hint providers: generic
   Accessibility and the bundled tmux plugin. Browser content comes through AX
   web areas; do not add DOM bridges or AppleScript-based hint discovery.
9. Default keyboard shortcuts must not enter INSERT (`a/A/i/I/o/O/gi` included).
   `enter_insert_mode` and `focus_input` are explicit configuration choices;
   unmapped-key/modifier passthrough forwards the event and enters INSERT only
   when the app then focuses an editable element. App activation or editable
   focus alone never changes NORMAL. See the mode document for deliberate pointer/target commits.
10. Dev deployment must use `Scripts/install.sh --dev`, which owns build,
    signing, replacement and restart order. Do not hand-copy/sign/kill the app.
    The dev bundle is `/Applications/Flash 🧪.app`; release is
    `/Applications/Flash.app`. Bare install defaults to a clean universal release
    and must not be used for development.

Surface requests that would violate these constraints before implementing them.

## Change discipline

- Prefer explicit value state, pure transitions and one owner for each resource.
  Invalidate asynchronous ownership before teardown; never let an old callback
  mutate a replacement. Add meaningful failing regression tests for nontrivial
  behavior before implementing its fix.
- Preserve deterministic complete discovery. AX events invalidate dirty tokens;
  configuration changes invalidate revisions. New UI-mutating notifications must
  join `AppMonitor.observedNotifications`. Do not deadline-truncate walks or serve
  partial captures. Keep refresh cancellation and maintenance generation-scoped.
- Use primary-screen height for AX/CGEvent versus NSScreen Y conversion. Screen
  unions start at `.null`. Layer changes disable implicit animation and new layer
  properties join `OverlayPanel.noActions`.
- Keep the main-loop keypress/recapture path free of AX/WindowServer IPC, sleeps,
  subprocesses, filesystem I/O, full layout and Carbon registration churn. With
  a live tap, recapture only restores NORMAL routing. Scope-only changes call
  `MappingsCoordinator.apply(scope:)`; full registry rebuilds require changed
  effective mappings. Build command completion inventory once per session.
- Reuse `FlashSource` capabilities, activation/readiness policies and semantic
  `FlashPriority`. Per-input computation belongs to `FlashQueryEvaluator`, not
  catalog sources. Sources return global NSScreen coordinates and canonical
  openable URLs when available. `.failed` owns a failed action and prevents a
  duplicate fallback; `.unhandled` permits the next source or host fallback.
- Validate plugin wire changes across Swift, Rust and Python. A wire bug gets a
  minimal shared repro in `Plugins/_flash_plugin_specs/regressions/` before its
  fix; domain scenarios belong in `Plugins/<id>/specs/`. `overrides.json` is the
  only skip/xfail mechanism, requires a reason, and fails on XPASS.
- Keep plugin stdout protocol-only and bound encoded bytes, queue admission,
  requests and shutdown. Third-party GitHub refs require a full pinned commit.
  Capabilities default-deny sensitive surfaces; explicit plugin settings carry
  credentials, never inherited ambient secrets or inspector-visible values.
- Seatbelt denies cannot be reopened by later allows. Carve permitted children
  out of the deny, canonicalize symlinked paths, and retain secret-read denies.
  Local socket connections require network capability. Do not widen the sandbox
  to host credentialed network CLIs that require the subprocess shape.
- Config validation is shared by all layers; preserve authored values and derive
  only after overrides. Only executable/working-directory fields receive path
  resolution; argv tails stay opaque. Update whole-section default parity tests.
- Log diagnostics through the serial log writer. XCTest disk logging uses only
  temporary destinations. Never capture a handle that rotation can invalidate.
- Keep this guide actionable and concise; explanations belong in `docs/`.
  Resumption notes belong in transient `.handouts/`, never external memory.
  Static unused-code reports need caller/protocol/dynamic-dispatch review before
  deletion; app-layer declarations can still have runtime consumers.

## Deliberately maintained infrastructure

Extend these implementations instead of replacing them with dependencies:

- `NormalMode/FuzzyMatcher.swift` and `CandidateFinder.swift`: tuned alias/title,
  frecency, short-query mask and top-K ranking contracts.
- `HintAssigner.swift`: fixed eight-entry, single-writer LRU.
- `Frecency/FrecencyStore.swift`: ranking-contract decay math.
- `DebugServer.swift`: loopback HTTP/SSE without a web framework.
- `FlashBrowserTestSupport/MarionetteClient.swift`: Firefox-specific framing and
  reconnect behavior.
- `Shortcuts/HotkeySyntax.swift`, `Shortcut.swift`, `CommandArguments.swift`:
  Flash's key DSL and argv/verb grammar.

A dependency exception needs a concrete unsupported requirement; surface it
before replacing these implementations.

## Build, verify and deploy

Run inside the current bonsai worktree. Prefix shell commands with `rtk`.
Fresh checkouts need `mise install` and `Scripts/build-ghostty.sh --dev` before
standalone SwiftPM commands; build/install/integration scripts bootstrap Ghostty.

Required checks for relevant changes:

```sh
rtk proxy swift format format --in-place --recursive Sources Tests Package.swift
rtk proxy swift format lint --strict --recursive Sources Tests Package.swift
rtk proxy ./Scripts/check-guardrails.sh
rtk proxy swift test
rtk proxy ./Scripts/test-plugins.sh --lane all
```

The plugin gate includes schema validation, Rust lint/tests, runner tests, builds
and bundled/probe/sandbox conformance. Use targeted suites during development;
run the full relevant gate before finishing. Status-language changes also run
`Scripts/test-status-format-oracle.py` against the pinned tmux baseline.

Every verified app-code iteration ends with `Scripts/install.sh --dev`, commit
and push. The installed resident does not use `.build` directly. Use the commit
and push skills, re-inspect state between stages, and stage explicit paths only;
never `git add -A` because the maintainer may edit concurrently. Do not add any
agent/tool attribution. Branches created for work use `ab/<kebab-case-slug>`.
Bonsai alone manages worktree lifecycle.

After installation, verify one resident under `/Applications/Flash 🧪.app` and
that `flash hints_dismiss` dispatches. `flash quit` is the quit verb. Changes to
hint discovery/commit should run the signed native, browser and Electron fixtures:

```sh
rtk proxy ./Scripts/test-integration-native.sh
rtk proxy ./Scripts/test-integration-browser.sh
rtk proxy ./Scripts/test-integration-electron.sh
```

The integration scripts own their fixture processes and cleanup. Native/Electron
oracles verify real host clicks; the browser oracle compares AX targets with
reference DOM markers. The no-tap key-window fallback may dismiss native menus.
Type-checking and pure tests do not verify the visible overlay: report any
remaining manual verification honestly.
