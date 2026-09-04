# AGENTS.md — guide for AI agents working on Flash

This document orients an agent (Claude, etc.) editing the Flash codebase. Read this before touching anything beyond a trivial change.

## What Flash is

A headless, resident macOS app that, when triggered by `flash mouse_target` from the CLI or a configured mapping, overlays hint labels on clickable elements in the focused app and clicks or moves to one when the user types its hint. It also supports normal/insert/command modes, a persistent top status bar when advanced mode is enabled, managed stdio plugins, `mouse_grid` screen-position targeting, `alert_show message=...` / `alert_dismiss` for a temporary centered toast, and `help_show` / `plugins` modal views. No menu bar, no Dock icon, no preferences window.

Activation comes either through the `flash` CLI (which AppleEvents the verb to the resident over a custom event class) or through Flash's `[mode.all.mappings]` / `[mode.normal.mappings]` / `[mode.insert.mappings]` Carbon registry. Mapping actions are argv arrays, either used directly as the mapping value or under `action` in an inline table with optional metadata such as `repeat = true`. Arrays whose head is `"flash"` resolve through the in-process verb table (the same one the AppleEvent handler consults); any other head is launched as argv with `~` and env expansion on each element. There is no `flash://` URL scheme and no separate `flashctl` binary — the `flash` Mach-O does both jobs.

## Hard rules (do not violate)

1. **No UI surface** beyond the transparent hint overlay, the advanced-mode status bar / command-line cell, the help and open-app overlays, explicit `alert_show` toast, and exactly ONE sanctioned `NSStatusItem`: the menu-bar bolt in `StatusItemController.swift`, gated by `[app] menu_bar_icon` (default true), carrying exactly About / Open Configuration / Quit — it must never grow into a preferences surface (configuration stays in the TOML file the middle entry opens). Beyond that: no other menu bar items, no `NSDockTile`, no `NSAlert`, no preferences window. Logging is stderr / `~/Library/Logs/Flash/`.
2. **Keyboard capture is confined to the sanctioned session tap + Carbon.** Global keystroke handling lives in exactly two places: (a) `Sources/flash/App/KeyboardCaptureTap.swift`, a session-level `CGEventTap` (`.cgSessionEventTap`, `keyDown` only, never mouse) that swallows NORMAL / hint keys and recognized modified mappings, passes INSERT, command-line, candidate-finder, configured unmapped key/modifier passthrough, and Flash's own synthetic keys straight through; and (b) `RegisterEventHotKey` for explicit modified-key entries in `[mode.all.mappings]`, `[mode.normal.mappings]`, or `[mode.insert.mappings]`. Do **not** add any *other* event tap, global key monitor, or keylogger, and the tap must never persist, log, or exfiltrate keystrokes — its only job is the swallow-vs-passthrough decision (`KeyboardCaptureTap.shouldSwallow`, a pure unit-tested function). `Scripts/check-guardrails.sh` enforces that `CGEventTap` appears only in `KeyboardCaptureTap.swift`. The tap runs under the Accessibility grant; if the OS refuses it, capture falls back to the overlay `NSPanel.keyDown` key-window path. Command-line, help, and open-app typing (the key-window surfaces) are handled through `NSPanel.keyDown` and are never swallowed by the tap.
3. **Autolaunch is config-owned through SMAppService.** `AutoLaunch.reconcile` registers/unregisters the login item from `[app] autostart` (default true) on every config load — the entry shows in System Settings → General → Login Items. `Scripts/install.sh` only cleans up the legacy LaunchAgent. Do not add login-item UI, LaunchAgents, background helpers, or additional autostart mechanisms elsewhere.
4. **No unowned resident helpers / no custom external IPC.** External activation is `NSAppleEventManager` receiving the custom `Flsh`/`Cmd ` event class from the `flash` CLI; native mappings dispatch pre-resolved `MappingAction` values in the resident app. Flash-managed plugin children are allowed only through NDJSON over stdin/stdout (protocol v1: one JSON object per newline-terminated line) with stderr as diagnostics only; Flash owns their lifecycle, liveness, reload, and shutdown (stdin EOF). Do not add Unix sockets, mach services, background helpers, daemonized clients, or any always-running client outside `PluginManager`. Do not re-introduce a `flash://` URL scheme; the only allowed external entry point is the custom AppleEvent sent by the `flash` CLI sibling.
5. **Single resident process.** Code assumes one `NSApplication` instance; bundle identifier `com.flash.app`.
6. **Hand-rolled infrastructure inventory — do not "fix" by adding a dependency.** Several pieces of plumbing in this repo are intentionally hand-rolled to keep the dep graph minimal and the wire formats / parsers under our own version control. Before reaching for a library, check this list first; if your change needs to touch one of these surfaces, extend the hand-roll rather than swap it out. The list (file → what it is → why the hand-roll stays):
   - `Sources/flash/App/NormalMode/FuzzyMatcher.swift` + `Sources/flash/App/CandidateFinder.swift` — flashlight fuzzy scorer + LCS-style highlighting + the Algolia-style typeahead path. Don't add `swift-algorithms` or a Fuse-style package; the scoring is tuned to specific ranking invariants (alias tier > title tier, frecency boost contained inside the smallest match-quality tier, the per-candidate `wordStartMask` UInt64 hard-gate on 1–2-char queries, and the top-K partial sort via `sortedMatches(_:limit:)` / `topRecords`). A generic scorer changes ranking silently and the typeahead gate's correctness depends on `prepare()` populating the mask from the same token list the live scorer reads.
   - `Sources/flash/App/HintAssigner.swift` — 8-slot LRU cache for sorted hint candidates. Don't pull `swift-collections` for this; the capacity is fixed and the access pattern is single-writer.
   - `Sources/flash/App/Frecency/FrecencyStore.swift` — exponential-decay frecency math. Don't swap for a package; the decay constants are part of the ranking contract.
   - `Sources/flash/App/DebugServer.swift` — loopback-only HTTP/SSE server. Don't pull Vapor / Hummingbird; we want zero dep surface for a debug-only feature and the wire is ~250 lines of `NWListener` glue.
   - `Sources/FlashBrowserTestSupport/MarionetteClient.swift` — Firefox WebDriver-over-TCP for the integration tests. Don't replace with a WebDriver lib; the framing is Firefox-specific and the test harness depends on the exact reconnect behaviour.
   - `Sources/flash/Shortcuts/HotkeySyntax.swift` + `Shortcut.swift` — hotkey DSL (`cmd+shift+k`, `<colemak>` alphabet refs, etc.) and `--flag=value` argv parsing. Don't add `swift-argument-parser`; the DSL has Flash-specific aliases and the argv parser is intentionally ~15 lines.

   The bar to deviate from this list is a concrete problem the hand-roll can't model (e.g. honouring TOML datetimes), not "a library would be nicer". When in doubt, surface it to the user first.
7. **No OCR / no Screen Recording.** Don't reintroduce `VisionProvider`, `ScreenCaptureKit`, screenshots, or pixel capture. WindowServer metadata via `CGWindowListCopyWindowInfo` is allowed only for window geometry / occlusion filtering and must not touch the screen recording permission. If a request requires capturing pixels, surface it instead of silently adding it back.
8. **Silent on no-targets.** If the discovery pipeline returns no `JumpTarget`s, `activate(action:)` returns without rendering anything. No "no targets" banner, no error chip. The only banners the user should ever see are the Accessibility-permission walkthrough.
9. **No backward-compatibility shims on master.** Flash has one user — the maintainer. When a config field, action name, mapping syntax, internal API, or wire format is renamed, update every call site, the defaults, the user's `~/.config/flash/flash.toml`, the bundled plugins, and the tests in the same change. **Do not** add legacy aliases, dual-syntax parsers, dual-key JSON readers (`as? T ?? response?["camelCase"]` etc.), `typealias OldName = NewName`, `// removed` placeholders, deprecation comments, or transitional accept-both paths. Reject malformed input loudly rather than silently translating it. The goal is the smallest possible code per feature. When in doubt, delete the old name — the maintainer can recover from `git log` if needed.
10. **Dev deploys go through `./Scripts/install.sh --dev`.** It owns the incremental current-arch dev build (debug Swift + `plugin-dev`-profile plugins) → codesign with the stable `Flash Dev` identity → kill running instances → reinstall to `/Applications/Flash 🧪.app` (release: `/Applications/Flash.app`) → launch flow. **Do not** hand-roll `cp build/flash /Applications/Flash.app/Contents/MacOS/flash && codesign … && pkill && open …` in agent sessions — TCC/permissions, plugin install stamps, and the launch agent all depend on the script's exact ordering. If you need a one-step "build and verify", run `./Scripts/install.sh --dev` (incremental, current-arch). Bare `./Scripts/install.sh` defaults to `--release`: a full, clean, universal build — slower, and its ad-hoc signature re-triggers the TCC grant, so reserve it for shipping.

If a request would violate any of the above, surface it to the user instead of silently complying.

## Project layout

```
Package.swift                        # SwiftPM, macOS 14+, swift 5 mode
config.default.toml                  # Canonical user-facing config reference
Sources/
  FlashCore/                         # Public SPI (source protocol + value types)
    AppContext.swift                 # Front-app context: bundle, pid, window frame
    JumpTarget.swift                 # A clickable thing with a screen rect + semantic commit metadata
    JumpAction.swift                 # .leftClick | .rightClick | .doubleClick
    FlashSource.swift                # FlashSource protocol + readiness/activation policy + capability set
    QueryEvaluator.swift             # Typed additive per-input answer facet; separate from catalog sources
    TargetFinalizer.swift            # Shared visible-region filter + smaller-frame-wins dedup before label assignment
  FlashProviders/                    # Built-in jump-target sources (depend on FlashCore + AppKit)
    Accessibility/AccessibilityProvider.swift   # Generic AX walk. Open class.
    Accessibility/AXClick.swift                 # AX action inspection for tentative target discovery; never the hint commit path.
  FlashBrowserTestSupport/           # Browser integration fixture catalog, Firefox harness, Marionette client, and reference-marker diff helpers.
  FlashIntegrationTestSupport/       # Shared GUI integration helpers: AX launch/wait/context, matching, timing, recorder.
  flash/                             # Resident app executable target — fat binary: argv-less = resident, argv = CLI
    main.swift                       # Branches into FlashCLI when argv > 1; otherwise boots NSApplication
    FlashCLI.swift                   # CLI half: AppleEvents the verb to the resident, exits
    App/
      AppDelegate.swift              # Orchestrator + OverlayCoordinator
      URLEventHandler.swift          # Registers the `Flsh`/`Cmd ` AppleEvent handler; shared verb table for CLI + mapping commands
      AppMonitor.swift               # Focused-app prepared model + AX walk dispatcher (serial AX queue)
      OverlayPanel.swift             # Reusable transparent NSPanel, CALayer pool, animations disabled
      OverlayInput.swift             # NSPanel.keyDown — the ONLY keyboard code in the project
      HintAssigner.swift             # Prefix-free label generator + memoised candidate cache
      ActionDispatcher.swift         # Uniform host CGEvent click dispatch for committed hints
      SourceRegistry.swift           # Built-in source descriptors; activation-gated source loading + priority chain
      Plugins/                       # Plugin manifest/process/manager, AX broker, and FlashSource adapter
      DebugServer.swift              # loopback-only dense HTTP/SSE debug page
      CandidateFinder.swift          # Flashlight candidate preparation, fuzzy matching, and answer merge
      CandidateSnapshotBarrier.swift # One-shot, bounded first-paint fan-in for warmed catalog snapshots
      ApplicationSource.swift        # Warm app catalog and `app_open` verb resolver
    Config/
      Config.swift                   # Decoded model — defaults here MUST match config.default.toml
      ConfigLoader.swift             # TOMLKit-backed TOML loading + DispatchSource fs-watch hot-reload
      Alphabet.swift                 # layout selector / literal hints.keys resolution
    Permissions/PermissionCheck.swift  # AXIsProcessTrusted() — read-only, no UI prompt
Tests/FlashTests/                    # XCTest: Alphabet, ConfigLoader, HintAssigner, TargetFinalizer, WindowSnapshot, plugin system, source candidates, browser fixture catalog, shared integration support.
Tests/BrowserSnapshots/              # Browser integration offline HTML snapshots discovered by Scripts/test-integration-browser.sh.
Tests/ElectronFixture/               # Pinned minimal Electron app used by Scripts/test-integration-electron.sh.
Plugins/                             # Official bundled plugins, each a hermetic standalone build (no shared cargo workspace), symlinked into the dev app
Plugins/_flash_plugin_rust/          # Sole maintained plugin SDK crate (package flash_plugin, own 2-member workspace + lock + canonical clippy.toml); no Flash business concepts
Plugins/_flash_plugin_specs/         # Language-agnostic JSON protocol-conformance specs, run by Scripts/plugin-protocol-spec.py
Resources/Info.plist                 # LSUIElement, AppleEvent usage description
Scripts/build-plugins.sh                     # per-crate hermetic cargo builds for [dev|release] [id…] → flash-plugin-<id> binary beside its manifest (dev = plugin-dev profile, current arch; release = universal lipo; ids filter to the single-plugin hot loop)
Scripts/_common.sh                           # Shared constants + helpers (signing identity, login agent, app assembly) sourced by build.sh / install.sh
Scripts/build.sh                             # Build Flash.app into build/ without installing. Default --release = clean universal optimized + zip; --dev = fast incremental optimized current-arch
Scripts/install.sh                           # build.sh then install to /Applications (dev: "Flash 🧪.app", release: "Flash.app") + restart. Default --release = clean universal; --dev = stable dev-signed, plugin symlinks
Scripts/test-integration-native.sh           # Build/sign/run native AppKit integration fixture + oracle
Scripts/test-integration-electron.sh         # Install pinned Electron fixture deps, build/sign/run Electron oracle
Scripts/check-guardrails.sh                  # CI hard-rule scanner for banned production APIs / stale config references
README.md                            # User-facing
AGENTS.md                            # This file
```

## Activation flow (read this before editing the hot path)

1. The `flash` CLI runs (`flash mouse_target [secondary=1|double=1|middle=1|triple=1|move=1|drag=1|select=1] [multi=1] [modifiers=cmd+…]`, `flash mouse_grid [secondary=1|double=1|middle=1|triple=1|move=1|drag=1|select=1] [multi=1] [modifiers=cmd+…]`), or a configured `[mode.*]` mapping fires a pre-resolved `MappingAction`. The CLI sends a custom AppleEvent (class `Flsh`, ID `Cmd `); mappings dispatch the same `URLCommand` value directly.
2. URL-scheme activation routes via Launch Services to the running instance as a `kAEGetURL` Apple Event; native mappings dispatch a pre-resolved action inside the resident process.
3. `URLEventHandler` parses URL host/query for AppleEvents and provides the shared parser used by mapping config loading.
4. `AppDelegate.activate(action:)` captures `NSWorkspace.shared.frontmostApplication`'s pid via `AppMonitor.currentContext()`, then takes an activation generation token.
5. `AppMonitor.discoverAsync` first probes activation-only providers such as tmux, whose output is volatile. If a dynamically scoped provider explicitly declines the context with an empty result, discovery falls through to the AX-event-driven prepared model (see *Prepared model contract* below), which delivers native AX-backed `[AssignedHint]` values without an activation-time AX walk.
6. On the AX queue, `AppMonitor` runs the selected provider chain in descending priority against the focused app only, filters candidates by the focused pid's WindowServer-derived visible region (occluded pixels excluded), then dedupes overlapping rects via spatial-hash with a **smaller-frame-wins** policy (`> 70%` overlap → smaller rect survives). Inside `AccessibilityProvider`, serial tree descent uses an explicit depth-first worklist (never recursive Swift calls), the focused window's direct children are fanned out across concurrent walkers, and action-name IPCs for tentative web-area / AXImage targets are resolved in a parallel post-pass.
7. `HintAssigner.assign` produces prefix-free labels using the configured alphabet — pre-uppercased as `AssignedHint.display`, memoised by `(alphabet, leftHand, length)`.
8. Bounces back to main; if the activation generation still matches (no cancel / app switch / commit in flight), `OverlayPanel.display(hints:)` wraps all layer mutations in `CATransaction.setDisableActions(true)` → no implicit animation; chips appear in place.
9. Panel becomes key (without activating Flash as app, because it's a `.nonactivatingPanel`).
10. `OverlayPanel.keyDown(with:)` matches typed prefix against assigned labels; on a unique match, `AppDelegate.commit` reactivates the focused pid (via `hint.target.pid`) and runs `ActionDispatcher.perform` after a 20 ms delay. The activation gate stays closed across that delay so a rapid second ctrl+space can't race.
11. `ActionDispatcher` always synthesizes the committed mouse event into the owning app; providers and plugins never activate a target themselves. Every target preserves the requested click modifiers. `f` requests none and is therefore a plain current-context click, including in Firefox; `F` requests Command-Shift as the uniform new-context gesture. `FlashTerminalLink` targets additionally require Shift so the terminal handles the link instead of forwarding it to tmux (`f` is Shift-click; `F` remains Command-Shift). The cursor lands on the committed chip. The dispatcher is the only place hint mouse synthesis lives.
12. Overlay hides; process stays resident.

## Coordinate systems (subtle, get this right)

Flash juggles three coordinate spaces. Mixing them up causes hints to land in the wrong place, especially on multi-monitor.

| Space          | Origin                              | Y axis  | Used by                                              |
| -------------- | ----------------------------------- | ------- | ---------------------------------------------------- |
| NSScreen / NSWindow | Bottom-left of primary screen   | Up      | NSPanel frame, JumpTarget.frame (canonical)          |
| AX `kAXPositionAttribute` | Top-left of primary screen | Down    | Raw AX position values                               |
| CGEvent mouse coords  | Top-left of primary screen     | Down    | `CGEvent(mouseEventSource:...)`                      |

The reference height for AX↔NSScreen conversion is the **primary screen height** — the screen with `frame.origin == .zero`, *not* the max of all screens. Using `max(maxY)` was a real bug: on a stacked dual-display setup it shifted every hint by the secondary's height. Helper pattern:

```swift
let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
    ?? NSScreen.main?.frame.height ?? 1080
let nsY = screenH - axY      // AX → NSScreen
let cgY = screenH - nsY      // NSScreen → CGEvent (same as AX y)
```

The overlay panel's union frame must start from `CGRect.null`, not `.zero`. Starting from `.zero` includes (0,0) in the union, which corrupts the bounds when a monitor sits to the left of primary (negative x).

```swift
var u: NSRect = .null
for s in NSScreen.screens { u = u.union(s.frame) }
```

## Determinism

The activation hot path **must return the same result for the same UI state**.

An earlier cache attempt got this wrong by serving deadline-truncated walk captures, and by falling back to a fresh walk on cache miss — so two presses in the same UI state could land on either a partial capture or a complete fresh walk, producing different hint sets. That broken cache was deleted.

The current prepared model is a different design. It preserves determinism by:

- **Walks are never truncated.** No per-walk deadline; walks always run to `maxDepth` / `maxTargets`. A walk that times the user out is preferable to a non-deterministic hint set.
- **No partial model.** A walk either completes and writes a full prepared model, or its result is discarded — never half-served.
- **Model reads are atomic against AX events and config.** `dirtyTokens[pid]` is bumped on every observed AX event (and on focused-app change). `configRevision` is bumped on config reload. A walk captures both before starting; it only writes the model if both still match at completion and the pid is still frontmost. Reads only serve a hit if token, config revision, and freshness all match.
- **Provider ordering is by priority desc.** Within a provider, traversal order is deterministic (AX child order for `AccessibilityProvider`, visible-grid order for `TmuxProvider`). Concurrent walking fans out subtree workers but the dedup + sort passes after merging are deterministic, so the final hint order is independent of worker scheduling.

See *Prepared model contract* below for the exact invariants.

### Prepared model contract

`AppMonitor` maintains a `PreparedModelStore`, a per-pid `dirtyTokens: [pid_t: UInt64]`, and a `configRevision` counter touched only from the main thread. An `AXObserver` is installed on the focused application; the workspace `didActivateApplicationNotification` swaps observers as focus changes.

**Token bump triggers** (each bumps `dirtyTokens[pid]`):

- Workspace focus change → bump new pid.
- Config reload, active Space change, and screen-parameter change → bump the focused pid.
- Any of these AX notifications on the focused pid: `kAXFocusedUIElementChanged`, `kAXFocusedWindowChanged`, `kAXMainWindowChanged`, `kAXLayoutChanged`, `kAXSelectedChildrenChanged`, `kAXSelectedRowsChanged`, `kAXValueChanged`, `kAXWindowResized`, `kAXWindowMoved`, `kAXWindowCreated`, `kAXWindowMiniaturized`, `kAXWindowDeminiaturized`, `kAXApplicationHidden`, `kAXApplicationShown`, `kAXTitleChanged`, `kAXCreated`, `kAXUIElementDestroyed`, `kAXRowExpanded`, `kAXRowCollapsed`.

**Walk life-cycle:**

1. `scheduleModelRefresh(for: pid)` — 80-ms debounced. Multiple bumps coalesce.
   When a pid exceeds the AX event-storm threshold, every event still bumps its
   dirty token and invalidates the model, but speculative AX/queued/maintenance
   rebuilds pause until a quiet event window clears the storm. Explicit hint
   activation still runs one complete deterministic walk on demand.
   Likewise, an automatic walk that takes at least 50 ms keeps its completed
   model but backs that pid off from further speculative AX/queued/maintenance
   warming; focus/config refreshes may reassess it, and activation remains a
   complete on-demand walk.
2. On debounce fire, capture `startToken = dirtyTokens[pid]` and `configRevision` on main, dispatch a continuous-provider walk on `axQueue`.
3. Walk runs to completion (never truncated).
4. Result hops back to main. If token and config revision still match AND pid is still frontmost → write a `PreparedModel` with targets, assigned hints, token, config revision, and timestamp. Else discard.
5. A maintenance refresh is scheduled before the freshness ceiling so a quiet focused app stays warm.

**Activation lookup** (`lookupPreparedModel`):

- Model hit iff `model.dirtyToken == dirtyTokens[pid]` AND `model.configRevision == configRevision` AND `now - model.computedAt < modelFreshnessMs`.
- On miss, activation waits for a model build and stores it if still valid; if the build also returns nothing (e.g. focused-window changed mid-build) activation falls back to a synchronous full provider walk.
- Volatile providers (`readinessPolicy == .volatile`, e.g. `TmuxProvider`) skip prepared-model lookup and writes; activation probes them on demand. A provider declaring empty-result fallback may then fall through to a prepared continuous provider such as `AccessibilityProvider` without merging results.

If you add new AX events that mutate UI state, add them to `AppMonitor.observedNotifications` in the same commit — otherwise the model can silently serve stale hints when those events fire. The freshness ceiling is a safety belt for events we forgot to subscribe to; don't lean on it as a primary mechanism.

The active-window mode border has a stricter lifecycle than the prepared hint model. `AppMonitor` registers move, resize, minimize, restore, and destruction notifications directly on the focused AX window (application-level registration alone does not reliably receive window-owned events), and refreshes that registration when focus/window lifecycle changes. Border reconciliation is event-driven: lifecycle events update immediately and schedule only bounded, one-shot WindowServer checks to absorb delayed state propagation; there is no resident border poll. Lock/session switch, screen sleep, system sleep, and secure login/screen-saver activation hide the border and cancel pending checks immediately; resume rebuilds from the current WindowServer frame and runs a bounded recovery sequence. A missing frame always clears the stroke rather than preserving a ghost window.

## Animations

CALayer mutates implicitly animate by default — including `frame`, `bounds`, `position`, `hidden`, `backgroundColor`. The visible bug was hints sliding into position after being shown. Two safeguards in `OverlayPanel`:

1. Every method that mutates layers wraps the work in:
   ```swift
   CATransaction.begin()
   CATransaction.setDisableActions(true)
   defer { CATransaction.commit() }
   ```
2. Each pooled chip/label has `layer.actions = OverlayPanel.noActions`, a dict that maps every relevant key to `NSNull()`, so even out-of-transaction mutations don't animate.

If you add a new visible property (gradient, shadow path, …), add its key to `OverlayPanel.noActions` too.

## Adding a new source

A source conforms to `FlashSource` in `FlashCore`. The canonical declaration is
`Sources/FlashCore/FlashSource.swift`; do not duplicate its full signature here.
It is the host adapter for jump targets, warmed catalog snapshots, candidate
resolution, focused-document lookup, source actions, and navigation restore.
Per-input computation deliberately uses the separate `FlashQueryEvaluator`
facet in `Sources/FlashCore/QueryEvaluator.swift`: do not add query parsing or a
regex-claim API to `FlashSource`.

Most source methods are optional in practice through default protocol-extension implementations that return no candidates, no document URL, or `.unhandled`. Implement only the capabilities the source actually owns.

Steps:

1. Create the source in `Sources/FlashProviders/<Group>/` when it is reusable jump-target logic, or under `Sources/flash/App/` when it is app-owned `:flashlight` / command-resolution glue.
2. Implement the protocol. For jump targets, return a complete deterministic `[JumpTarget]` set with **global NSScreen coordinates** (bottom-left origin of primary screen). Do not deadline-truncate output.
3. For `:flashlight` catalog items, return `Candidate(title:url:metadata:effect:)`. `title` is the primary searchable value, `metadata["source"]` is a short stable manifest-declared label, and `url` should be openable whenever present. App candidates must use an absolute `file://` URL to the `.app` bundle; browser tabs and external resources should use their canonical openable URL. Omit `url` only when the source must resolve through source-specific payload or AX state. Use the shared `FlashPriority` / plugin SDK `Priority` enum (`low`, `normal`, `high`, `important`, `urgent`) for candidate row salience; do not invent plugin-domain source kinds for ranking. `:open` is not a finder: it forwards its arguments verbatim to `/usr/bin/open`.
4. Pick an activation policy. Use `.always` only for cheap universal sources, `.bundleIDs(...)` for app-scoped sources like browser tabs, and `.terminalBundles` for terminal-backed sources. `SourceRegistry` instantiates non-`.always` sources only while a matching app is running.
5. Register a `SourceDescriptor` in `Sources/flash/App/SourceRegistry.swift`. Pick a numeric provider priority for overlapping jump-target providers — higher wins. Candidate source descriptors separately declare generalized source priority with `CandidateSourceDescriptor(name:kind:priority:)` or plugin manifest `sources[].priority`; keep those source priorities semantic (`low` … `urgent`) rather than plugin-specific.
   Existing jump-target provider scale:
   - 20: the bundled `tmux` plugin (attached local clients plus SSH/Mosh-hosted remote tmux sessions discovered from the live process graph; no terminal bundle allowlist)
   - 10: generic `AccessibilityProvider` (universal AX walker; also handles browser in-page DOM via `AXWebArea` descendants)
6. Add focused tests. At minimum cover source activation gating in `SourceRegistryTests` or the source's parsing/resolution helpers, then update README when user-facing behavior changes.

Flash deliberately uses **only two jump-target sources**: `AccessibilityProvider` as the universal default, and the bundled `tmux` plugin's hints provider for terminals whose visible content macOS Accessibility cannot see. App-specific sources may contribute `:flashlight` items or custom resolution when that data does not belong in the AX walker. There is no DOM bridge / `do JavaScript` provider — browser page content reaches us through `AXWebArea` descendants the same way every other web area does. If you find yourself reaching for AppleScript-based discovery, surface that to the user instead of adding it.

A `JumpTarget` describes geometry and semantics only. Providers never activate
targets: `ActionDispatcher` owns the real host mouse event for every commit.

## Configuration

`~/.config/flash/flash.toml`. Hot-reloaded via `DispatchSource.makeFileSystemObjectSource`. `$XDG_CONFIG_HOME/flash/flash.toml` takes precedence when `XDG_CONFIG_HOME` is set. There is no legacy `~/.flash.toml` fallback. TOML syntax is parsed with the Swift package `TOMLKit`; `Sources/flash/Config/ConfigLoader.swift` owns only Flash's typed schema, validation, source-location indexing for known values, and command-path resolution.

The user-facing top-level sections are exactly `[app]`, `[hints]`, `[overlay]`, `[open]`, `[plugins]`, `[statusbar]`, `[statusbar.popup]`, `[statusbar.click]`, `[flashlight]`, `[flashlight.aliases]`, `[flashlight.precedence]`, `[mode]`, `[mode.all.mappings]`, `[mode.normal]`, `[mode.normal.mappings]`, `[mode.insert.mappings]`, and `[debug]`, in that order in `config.default.toml`.

**`config.default.toml` at the repo root is the canonical user-facing reference.** When you change a default or add a mapping/action, update `Config.swift`, `ConfigLoader.swift`, `URLEventHandler.swift` when needed, `config.default.toml`, `README.md`, this section, and tests in the same commit.

Keys:

| Key                                | Type           | Default              |
| ---------------------------------- | -------------- | -------------------- |
| `app.menu_bar_icon`                | bool           | `true`               |
| `app.autostart`                    | bool           | `true`               |
| `hints.keys`                       | string         | `"<qwerty_homerow+qwerty_toprow>"` |
| `hints.min_length`                 | int            | `1`                  |
| `hints.magic_modifiers`            | string array   | `["cmd", "ctrl", "alt", "shift"]` |
| `hints.mouse_grid_steps`           | int (2..6)     | `3`                  |
| `hints.mouse_grid_opacity`         | float (0..1)   | `0.5`                |
| `overlay.font_size`                | float (1..200) | `12`                 |
| `overlay.hint_fg` / `hint_bg_top` / `hint_bg_bottom` / `hint_border` | hex color | chip yellows |
| `overlay.important_hint_fg` / `…_bg_top` / `…_bg_bottom` / `…_border` | hex color | accent reds |
| `overlay.window_border`            | bool           | `true`               |
| `overlay.window_border_size`       | float (0..20, `0` = per-mode) | `0`   |
| `overlay.window_border_color`      | hex color (`""` = per-mode) | `""`    |
| `open.ignored_apps`                | string array   | `[]`                 |
| `open.app_directories`             | string array   | standard macOS app dirs |
| `plugins.disabled`                 | string array   | `[]`                 |
| `plugins.third_party`              | string array   | `[]`                 |
| `plugins.watching_enabled`         | bool           | `true`               |
| `statusbar.enabled`                | bool           | `false`              |
| `statusbar.template`               | string         | `"#[align=left]#{mode}#[align=right]#{date}"` |
| `statusbar.monitor`                | string (`"all"` \| `"primary"`) | `"all"`  |
| `statusbar.interval`               | int (seconds, `0` = poll off) | `5`     |
| `statusbar.font_size`              | float (8..32)  | `13`                 |
| `statusbar.command_timeout`        | float (1..60 s) | `6.0`               |
| `statusbar.notch_margin`           | float (0..64 pt) | `0`                |
| `statusbar.click.<name>`           | URL string or action array | battery pane |
| `overlay.alert_duration`           | float (0.2..30 s) | `2.0`             |
| `overlay.banner_duration_ms`       | int (100..10000) | `700`              |
| `mode.scroll_step`                 | int (10..500 px) | `60`               |
| `mode.scroll_page_fraction`        | float (0.05..1) | `0.5`               |
| `mode.click_hold_ms`               | int (0..200)   | `18`                 |
| `mode.send_key_interval_ms`        | int (0..500)   | `35`                 |
| `flashlight.frecency_half_life_days` | float (0.5..365) | `14.0`           |
| `flashlight.frecency_max_boost`    | int (0..10000, `0` = off) | `600`     |
| `flashlight.snapshot_timeout_ms`   | int (20..2000) | `150`                |
| `plugins.install_timeout`          | int (10..1800 s) | `120`              |
| `plugins.startup_timeout`          | int (1..120 s) | `15`                 |
| `flashlight.suggestion_count`      | int            | `10`                 |
| `flashlight.precedence_alive_bonus` | int            | `10`                 |
| `[flashlight.aliases]` entries     | string         | none                 |
| `[flashlight.precedence]` entries  | int            | source-kind override |
| `mode.labels`                      | inline string table | `{ normal = "NORMAL", insert = "INSERT", command = "COMMAND" }` |
| `mode.sequence_timeout_ms`         | int (ms)       | `1000`               |
| `[mode.all.mappings]` entries      | argv array or `{ action = [...], repeat = bool }` | none             |
| `mode.normal.leader`               | string         | `"\\"`             |
| `mode.normal.passthrough_keys`     | string array   | `["escape"]`         |
| `mode.normal.passthrough_modifiers` | string array | `["cmd", "ctrl", "shift", "alt"]` |
| `[mode.normal.mappings]` entries   | argv array or `{ action = [...], repeat = bool }` | built-in normal map |
| `[mode.insert.mappings]` entries   | argv array or `{ action = [...], repeat = bool }` | none             |
| `debug.show_hints_bounds`                | bool           | `false`              |
| `debug.hints_bounds_bg` / `hints_bounds_fg`    | hex string     | transparent / `"#FF3B9A"` |
| `debug.log_level`                  | string         | `"info"`             |
| `debug.http_inspector_enabled`          | bool           | `false`              |
| `debug.http_inspector_host`             | string         | `"localhost"` (also accepts `127.0.0.1`, `::1`) |
| `debug.http_inspector_port`             | int (1..65535) | `4242`               |

`hints.magic_modifiers` supports `"cmd"`, `"ctrl"`, `"alt"`, and `"shift"`.
If the resolved `hints.keys` contains non-letter characters, Flash logs a warning
and removes `"shift"` because shifted-character input is ambiguous at the
hint-input layer: Flash cannot distinguish `shift+1` from `!`. `[]` disables
modified clicks.

`open.ignored_apps` excludes app results from `:flashlight` and the
`app_open name=...` verb. Entries match an app's display name, bundle
identifier, full bundle path, `.app` filename, or filename without `.app`,
case-insensitively.

Logs are newline-delimited JSON written to stderr and
`~/Library/Logs/Flash/flash.log`. Every log line has a `source` field:
`core:<file>.<function>` for Flash code, or `plugin:<id>` for plugin logs.
`debug.log_level = "trace"` includes AX tree dumps. Accepted levels are
`trace`, `debug`, `info`, `warn`, `error`, and `fatal`.

`plugins.third_party` accepts only `github:user/project@<commit-sha>` and `file:<path>`. The `@<commit-sha>` pin is mandatory for `github:` references — it must be a full 40-character lowercase hex commit SHA, and the loader rejects anything else (branch names, tags, short SHAs). Third-party `install` scripts run sandboxed (writes confined to the plugin root/data dir/temp, secrets read-denied, output persisted for forensics) and `exec` argvs run under the plugin's launch profile, but a pinned ref is still the primary trust boundary; the materializer fetches *exactly* the pinned commit and refuses to start a plugin whose checked-out HEAD doesn't match. Plugin manifests declare sensitive runtime surfaces through `capabilities`: `"clipboard"` gates `core:clipboard.changed`, `"accessibility"` gates the AX broker and host-posted keyboard chords, `"network"` opts out of the default network-denying seatbelt profile, `"subprocess"` permits privileged helpers that cannot run under that profile, and `"app_control"` gates the `host.normal_mode_target` and `app.activate` host RPCs. Running-app and focus events are currently delivered according to `listen` independently of `"app_control"`; the capability does not gate observation. Omitted capabilities are default-denied.
Official bundled plugins under `Contents/Resources/Plugins` are enabled unless
their id is listed in `plugins.disabled`; use `["defaults"]` for a raw host-only
experience without built-in plugin-layer defaults. In the checkout they live under root
`Plugins/` so `Scripts/install.sh --dev` can symlink them into the installed app. Every plugin root must contain
`manifest.json` with `id`, `name`, `version`, `description`, optional
`install` (third-party-only; runs sandboxed), optional `exec`, optional
`sandbox` deny-default spec, optional `listen` event patterns, the root
`only_bundle_ids` selector, and provider registrations. Command providers
expose one or more subcommands; status providers declare segment names in the
`status` array.
There is no `manifest_version` field on master. The host rejects unknown
top-level and nested provider/item manifest keys instead of accepting legacy
aliases; malformed known fields are rejected instead of silently defaulted.
Mapping items must use exactly `all`, `normal`, or `insert` scopes. `install`
is a shell string run from the plugin root; `exec` is an argv array the host
execs directly with the scrubbed plugin environment (no shell wrap — a
`/bin/sh -lc` here used to source login rc files and silently re-widen the
env allowlist), resolving a relative first element against the plugin root.
Omitting `exec` declares a
**manifest-only plugin**: no child process ever runs (no install, liveness, or
watchdog), and validation restricts the manifest to host-served surfaces —
`mappings`, `help`, and `verbs` whose every entry has a default inline
keystroke. The bundled `defaults` plugin is manifest-only: its four keystroke
verbs and help topic come straight from `Plugins/defaults/manifest.json` with
no crate behind them. Runtime children receive
`FLASH_PLUGIN_ID`, `FLASH_PLUGIN_VERSION`, `FLASH_PLUGIN_DATA_DIR`,
`FLASH_PLUGIN_PARENT_PID`, and the plugin's `[plugin.<id>]` settings serialized
as a JSON object in `FLASH_PLUGIN_CONFIG`. Flash does not inherit the complete
login environment: it preserves only basic process locale/path keys, so secrets
and credentials must be explicit plugin settings rather than ambient
environment variables. The debug inspector may report setting keys but must
redact their values.
Plugins speak NDJSON over stdin/stdout: one JSON object per
newline-terminated line (protocol v1, no envelope beyond
id/method/params/result; every result carries boolean `ok`). Host input goes
to stdin, protocol results go to stdout, and stderr is diagnostics only.
Plugins log through the Flash logger by sending `log` notifications. The
method set is deliberately tiny — host→plugin `initialize`, `ping`, `event`,
`evaluate`, `search`, `hints`, `perform`; plugin→host `publish`, `status`,
`log`, and the capability-gated `host.*` RPCs — do not add camel-case
aliases or new methods outside `Plugins/_flash_plugin_specs/protocol.json`.
Official plugin installers must keep downloaded CLI binaries under their own
`FLASH_PLUGIN_DATA_DIR`; do not write into global shell paths.

`[statusbar]` configures the persistent top status bar format. `template`
is one tmux-style string; `#[align=left]`, `#[align=centre]` / `#[align=center]`,
and `#[align=right]` route following text into the left, centre, and right
regions. Separators are literal inline text inside the template. Supported
template variables are `#{mode}`, `#{active_app_name}`,
`#{active_bundle_identifier}`, `#{date}`, `#{plugin:loaded_count}`,
`#{plugin:ready_count}`, `#{plugin:error_count}`,
the OS primitives `#{host}` (`#H`), `#{host_short}` (`#h`), `#{user}`,
`#{uid}`, `#{pid}`, `#{plugin:<plugin>.<segment>}`,
`#{script:<path>}`, `#{command:<shell command>}`, and `#{cycle:<path>}` (rotate
through the script's stdout lines). Any other bare `#{token}` is a config
error — there is no silently-empty tmux dialect. tmux session/window/pane
state comes from the bundled tmux plugin's status segments
(`#{plugin:tmux.session}`, `#{plugin:tmux.window}`, `#{plugin:tmux.pane}`),
and the bundled system plugin exposes `#{plugin:system.battery}` plus
`#{plugin:system.battery_details}`. The bundled aiproviders plugin owns the
Claude, Fable, and Codex compact/detail usage segments declared in its manifest.
The format grammar is a strict tmux superset: modifiers `#{?cond,a,b}`,
`#{==:}`/`#{!=:}`/`#{<:}`/`#{>:}`/`#{<=:}`/`#{>=:}`/`#{&&:}`/`#{||:}`,
`#{s/re/repl/[i]:var}`, `#{pN:}`/`#{p-N:}`, `#{=N:}`/`#{=-N:}` (Flash `…`
ellipsis extension) and `#{=/N/marker:}`, nesting for chaining, `#,` comma
escape; style scoping via `#[default]`/`#[push-default]`/`#[pop-default]`;
strftime `%`-literals expand before formats (tmux semantics — `%%`
escapes); colours are the full xterm-256 palette + `#RRGGBB` + ANSI names
(colour0/178/196/245 keep Nord-theme shades). One tokenizer
(`StatusBarMarkup.swift`) is the only scanner of the marker grammar —
extend it, never hand-roll another `#[`-walk.
Named `#[popup=<name>]…#[nopopup]` spans resolve rich multiline bodies from
`[statusbar.popup]`. Dynamic values can instead carry a percent-encoded body in
`#[popup=inline:<encoded>]`; the body remains zero-width and rotates atomically
with a cycle row. Popup work is scheduled with normal status refreshes—hovering
only shows or repositions already-rendered content.
Template newlines are ignored before rendering. Mode, focused-app, plugin
status, and date changes re-render from their own change sources. Command/script
sections are stale-while-refresh and are polled only when present: the previous
successful value stays visible until a replacement is ready. Poll cadence is
`[statusbar] interval` (default 5 s, `0` = run once), overridable per source
inline — `#{script=N:…}` / `#{command=N:…}` re-run every N seconds, and
`#{cycle=R/N:…}` rotates every R while re-running every N (default
`max(R, interval)`). Each section schedules and drops overrun ticks
independently, so one slow script never starves the others. The menu-bar
reveal probe behind the bar's click windows runs on a utility queue, armed
only while the pointer is in the band. `#[breathing]`/`#[blink]` spans
animate via render-server CAKeyframeAnimations on pooled overlay layers
(the base layer draws them at foreground alpha 0; `effectAlphaMultiplier`
is the curve oracle) — the status bar does ZERO periodic work, main-thread
or otherwise, beyond rendering actual model changes. All screens lay out
through ONE function (`configureStatusBarSurface` + `StatusBarSurface`);
never fork a per-screen layout copy. Overflow is handled by the elastic
`#[shrink]…#[noshrink]` span (pixel-accurate ellipsis; fixed content keeps
full width) and layout keeps a 16 pt margin around a notch.

**Every executable bundled plugin is Rust and macOS-only.** The wire protocol
remains language-neutral for third-party executables, but the repository
maintains one SDK, one conformance probe, and one build path. Official plugin
manifests use `["./flash-plugin-<id>"]`; only manifest-only plugins omit a
binary. Rust stays rustup-managed for universal builds. `mise.toml` pins only
Python for the language-neutral conformance runner.

Rust plugins under `Plugins/<id>/` are **hermetic standalone crates** — there
is no cargo workspace under `Plugins/` (the SDK dir's own two-member
workspace is the single exception). Each plugin's `Cargo.toml` path-depends
on the local SDK crate (`flash_plugin = { path = "../_flash_plugin_rust" }`),
which owns all the generic protocol scaffolding (JSON-lines framing,
`initialize`/`ping`/EOF-shutdown, structured logging, a sandboxed
`run_command`, background tasks/timers, and the tokio runtime) and carries
**no Flash business concepts**. Every plugin crate inlines its own dependency
versions, carries its own `[profile.plugin-dev]`/`[profile.release]` blocks,
commits its own `Cargo.lock` (kept honest by `--locked` in CI and release
builds; version skew between plugins is allowed by design), and carries a
byte-identical copy of the canonical clippy config
(`Plugins/_flash_plugin_rust/clippy.toml`; `check-guardrails.sh` fails on
drift) — a bundled plugin's build files are exactly what a third-party author
would write. Always set `CARGO_TARGET_DIR=build/plugin-target` for manual
cargo runs: it dedupes SDK builds across crates, and a bare run creates a
watched `Plugins/<id>/target/`. A plugin's `main.rs` implements the `Plugin`
trait; everything domain-specific lives there, never in the template. The crate
hardcodes `edition = "2021"` and `license = "MIT"`. Plugins may assume macOS and
must **not** use `unsafe` Rust (objc2 0.6 exposes the AppKit/Foundation calls we
need safely; the SDK confines its own unsafe to `process.rs`/`runtime.rs`).
`Plugins/_flash_plugin_specs/*.json` is the language-agnostic
conformance suite (lifecycle + wire-noise robustness always;
snapshot/query gated on the manifest's provider sections);
`Scripts/plugin-protocol-spec.py` drives any plugin binary/runtime through
it without a host, and CI runs it against every official plugin and the Rust
probe. `Scripts/build-plugins.sh [dev|release] [id…]` builds every executable
plugin with one cargo invocation per hermetic crate into a shared
`build/plugin-target` (kept out of the watched
plugin trees) and stages each `flash-plugin-<id>` binary next to its
`manifest.json` through the same sign-then-atomic-rename flow. `dev` uses the `plugin-dev` cargo profile
(opt-level=1, line-tables-only debuginfo — mildly optimized, incremental,
current arch); `release` produces optimized universal binaries (x86_64 +
arm64) joined with `lipo`.
Trailing ids restrict the build to those plugins:
`Scripts/build-plugins.sh dev tmux` is the single-plugin hot loop. Candidate providers declare manifest root `sources` descriptors, build
their complete row set from light host events such as `core:apps.changed`,
`core:focus.changed`, and `core:ax.changed` when possible (polling only when
the underlying source cannot be watched), and push it with `publish` — the
host owns the catalog store and the flashlight open path never touches a
plugin process. The manifest's `exec` is
`["./flash-plugin-<id>"]` and there is no install step (the `install` key is
third-party-only) — no cargo, Python, or interpreter at runtime. `Scripts/build.sh` / `Scripts/install.sh`
invoke `build-plugins.sh` with the matching mode; dev symlinks the repo
`Plugins/` into the app, while release stages only `manifest.json` + the binary
per plugin (no sources). The compiled binaries and per-crate build output are
git-ignored.

**Push-catalog contract (binding for every candidate provider).** The catalog
is push-based and host-owned: a plugin builds its complete candidate set and
sends one `publish` notification with the FULL replacement row set (rows carry
a first-class `source` field naming a manifest `sources[].name`); the host
validates quotas at receipt on that plugin's reader queue and stores the rows
in `PluginCatalogStore`. The flashlight first paint is a synchronous read of
host memory — it never waits on, or talks to, a plugin process. There is no
snapshot pull, no readiness gate (initialize replies immediately; `on_start`
runs after the reply and publishes when ready), and no invalidation
round-trip: publishing IS the invalidation, and an open flashlight refreshes
from the store on a coalesced ≤1/s lossless tick.

The one sanctioned exception is `sources[].live = true` (file search and other
catalogs that are structurally impossible to keep warm): a live plugin serves
per-keystroke `search` requests through the SDK's `on_search` hook, never
joins the default pool or the first paint, and only participates when the
query explicitly scopes to it (`@source` or a bang's `source`) under the
drop-late `[flashlight] live_query_timeout_ms` deadline. One plugin's sources
are all-warm or all-live, and `live` cannot combine with `kind = "locations"`.

  1. **Publish complete replacements, never deltas.** Every `publish` is the
     plugin's whole canonical aggregate catalog (all of its declared source
     names together). `{"rows": []}` is an authoritative empty and clears the
     stored catalog. On transient refresh failure, simply don't publish — the
     host keeps the last-good catalog by construction, across crashes and
     restarts. Never translate a transient error into an empty publish, and
     never publish partial state mid-refresh.

  2. **All I/O lives in bounded background refreshes.** Filesystem, database,
     subprocess, AX, AppleScript, and network work belongs to startup, event,
     and `interval(...)` poll refreshes with explicit time/count/byte bounds.
     Refresh on host events that correlate with change (`core:focus.changed`,
     `core:apps.*`, `core:flash.started`, and the advisory
     `core:session.opened` when open-time freshness genuinely matters); poll
     only when the source has no push channel. The store must be fresh by the
     time the user opens the flashlight; nothing refreshes on the open path.

  3. **Rows must be resolvable from their own content.** The stored catalog
     outlives the process that published it, so a `perform {kind: "resolve"}`
     can arrive at a freshly restarted plugin carrying a row published by its
     previous life. Resolve from the row's own url/metadata; a plugin that
     cannot replies `{"ok": false, "error": …}` and its next publish replaces
     the rows.

  4. **Dedup is cheap, not required.** A publish just replaces the stored
     rows, so re-publishing identical data is nearly free; still skip an
     expensive refresh that would produce no change (fingerprint-diff, then
     publish).

  5. **Parallelise per-target I/O.** When the rows come from N independent
     backends (tmux sockets, browser bundles, app databases, …), fan the
     per-backend work out concurrently so the slowest backend does not
     dominate every refresh.

  6. **Quota rejection is atomic and host-side.** A malformed or over-quota
     publish is rejected whole (content-free log) and the previous catalog is
     retained — the SDKs deliberately do not duplicate quota validation.

**Query-evaluator contract.** A manifest root `"query": {}` registers the
plugin for bare flashlight input. Evaluators are additive parsers by default.
A provider may declare literal `prefixes` (for example `"="` for a
calculator); a matching request is routed only to providers declaring that
exact marker. The host never accepts plugin regexes, and explicit `!bang` /
`@source` intent bypasses evaluators. The `evaluate` hook is synchronous.
It may only compute from the request plus immutable state warmed during
`on_start` / events — no filesystem, subprocess, network, AppleScript, or
other I/O. `evaluate` responses are combined once behind the 50-ms host
deadline, ordered by manifest root priority (ties by plugin id), prepended in
a fixed answer lane, and discarded when their per-query generation is stale.
A response may contain at most 16 answers; crossing that or any
field/aggregate payload boundary rejects the whole response and logs only
content-free counts/limits. The wire response is the narrow
`{ "ok": true, "answers": [{ "title", "subtitle"?, "effect" }] }` shape with
`copy_text`/`insert_text` effects only. Unknown keys, URLs, metadata, pids,
priorities, and routing fields are rejected; the host owns and stamps answer
provenance, urgency, and finisher semantics.
Return, Tab, and Command-Return stay deferred until both the evaluator aggregate
and the answer-lane re-render settle for that exact session/query generation;
edits and cancellation discard the deferred action.
The bundled calculator uses `fend-core`; `1+1`, `2 km to m`, and currency
expressions produce copyable answers. Before reporting ready it loads the
last-good ECB rate snapshot from disk into immutable evaluator state; any
network refresh runs in the background and atomically replaces that state
without delaying arithmetic or query evaluation. It defaults target conversions
to USD; configure up to eight codes with
`[plugin.calculator] target_currencies = ["USD", "EUR"]`.

**Plugin latency telemetry is binding and content-free.** The host warns when
its end-to-end `evaluate` RPC reaches 40 ms, before the 50-ms hard deadline —
treat a slow evaluator body as a bug. Warn when a publish validation takes at
least 100 ms. The flashlight first paint is a synchronous store read and must
stay effectively instant. Every host RPC timeout
and every successful generic RPC over 1 s logs the plugin id, method, and
elapsed milliseconds; plugin-to-host RPC timeouts log the method and
elapsed/timeout only. The shared subprocess runner warns at 1 s or timeout with
the executable, status, elapsed, and timeout. Background/event
refreshers log outcome (`ok`, `partial`, `failed`, or authoritative `empty`),
candidate count, and elapsed milliseconds. These records must never contain the
query text, candidate titles/URLs/payloads, clipboard text, event payload, or
other user data.

**Plugins must never block the async runtime (enforced, no exceptions).** Every
plugin runs on one current-thread Tokio executor shared by all its async work —
events, catalog refreshes, hint discovery. Async I/O and `spawn_blocking` still
make progress, but one blocking syscall pins the executor
thread and stalls every other in-flight operation (this is exactly how a
flashlight open ends up waiting hundreds of ms on a single plugin). So sync/
blocking I/O is **banned outright in plugin code** — there is no
`#[allow(clippy::disallowed_methods)]` escape hatch. Use the async API everywhere:
`tokio::fs::*` for files (it offloads to its own blocking pool internally, so
plugin code stays fully async and never names `std::fs`), `tokio::process::Command`
for subprocesses, `tokio::time::sleep` for delays. A `read_dir` becomes a
`tokio::fs::read_dir` stream (`while let Some(entry) = rd.next_entry().await?`);
make the enclosing helper `async` and `await` it up the call chain. The tokio
runtime itself is built once by the SDK's `run()` — a plugin's `main` must never
build its own (`tokio::runtime::Builder`/`block_on`); do async startup work in
`on_start`, or resolve lazily with a `tokio::sync::OnceCell` (see
`Plugins/tmux/src/main.rs` `resolved_tmux_path`). Enforced by each crate's
`clippy.toml` (byte-identical copies of
`Plugins/_flash_plugin_rust/clippy.toml`, guardrail-checked;
`disallowed-methods`/`disallowed-types`):

```
(cd Plugins/<id> && CARGO_TARGET_DIR=../../build/plugin-target \
  cargo clippy --all-targets -- -D clippy::disallowed_methods -D clippy::disallowed_types)
```

(`flash_plugin_macros` reads `manifest.json` at *compile* time, where there
is no async runtime — its single read site carries a scoped
`#[allow(clippy::disallowed_methods)]`.)

Tests should pin these invariants in place — see
`Plugins/tmux/src/main.rs` for the canonical pattern (`hash_candidates`,
`refresh_candidate_locations_for_path` with `last_locations_hash` dedup,
`run_tmux_aggregate_inventory` parallel socket fan-out, and
`refresh_remote_backends` parallel host fan-out). `Scripts/check-guardrails.sh`
rejects any resurrection of the old pull-protocol wire names, requires every
manifest with warm `sources` to implement `on_start` and push through
`publish`, and requires every `query` provider to implement the synchronous
`evaluate` hook.

Setting `debug.http_inspector_enabled = true` starts a loopback-only single-page
debug server with live logs, resolved config, focused app state, and plugin
state, bound to `debug.http_inspector_host` (`localhost` / `127.0.0.1` / `::1`)
and `debug.http_inspector_port`. Resolved plugin setting keys may be shown, but
their values stay redacted. Keep it dense and diagnostic-focused; do not turn
it into a preference UI. Inspector mapping rows are diagnostic output and may
be identical across contributing mapping sources; render them unkeyed (or key
by occurrence), never by a supposedly unique scope/key/action tuple.

Performance behaviours are **not configurable.** The prepared AX model,
the concurrent subtree walk, and the parallel deferred action-name
IPC pass are always on. Per-IPC AX messaging timeout is never set
(see *Prepared model contract* below).

There is intentionally **no** `per_app.*` table. The project's working assumption is to converge on universal rules before re-introducing per-bundle knobs — `Config.perAppRoles` and its TOML parser case were removed for this reason.

### Mode Mappings

`[mode] labels = { normal = "...", insert = "...", command = "..." }` controls the left-side status-bar text. `[mode.all.mappings]`, `[mode.normal.mappings]`, and `[mode.insert.mappings]` map `"key" = ["flash", "<verb>", "--key=value"]` (in-process verb) or `"key" = ["<executable>", "<arg>", …]` (argv exec). A mapping that needs metadata uses `{ action = [...], repeat = true }`; `repeat` keeps the completed normal-mode mapping armed so additional presses of its final key dispatch it again. Every built-in `[` / `]` mapping enables this metadata. `[mode.normal] leader = "\\"` configures a normal-mode sequence prefix that can be referenced in `[mode.normal.mappings]` as `<leader>`. `[mode.normal] passthrough_keys = ["escape"]` and `passthrough_modifiers = ["cmd", "ctrl", "shift", "alt"]` make matching unmapped keypresses enter INSERT and continue natively; explicit mappings win, and setting both lists to `[]` keeps NORMAL hermetic.

- Modified-key entries in `[mode.all.mappings]` apply in every mode, including
  command-line and candidate-finder surfaces. Non-modified entries are available
  only while the overlay owns normal-mode input.
- `[mode.normal.mappings]` applies only while the overlay is capturing normal-mode input.
- `[mode.insert.mappings]` applies only in insert mode.

Actions must be non-empty string arrays. Use the array directly for a simple mapping or `{ action = [...], repeat = true }` when the final key should repeat a completed normal-mode sequence. Bare strings, URLs, and any other shape are deliberately unsupported. Arrays whose head is `"flash"` are interpreted as in-process verb dispatches and resolve through `URLEventHandler.parse(verb:args:)`; any other head is executed directly as argv (no shell wrap) with leading `~` expanded in each element. Relative path arguments containing `/` are resolved from the config file location at load time, so `["../../scripts/toggle"]` works for dotfiles-managed configs.

Native modified-key mappings are registered through Carbon when the key contains `"+"`; unmodified normal-mode mappings are read only while the overlay panel owns keyboard input. `[mode.normal.mappings]` entries extend the built-in normal map and override only matching keys, so unrelated defaults stay available unless that exact key is remapped.

When any `[mode.all.mappings]` mapping resolves to `["flash", "enter_normal_mode"]`, Flash enters advanced mode:

- starts in normal mode by default;
- always displays the status bar using configured `mode.labels`, including in the help view;
- extends the `help_show` modal with ACTION / NORMAL / INSERT columns.

`app_previous` / `app_next` traverse one circular app ring. Observed app
activations own its MRU order; when a fresh resident has no usable history, the
ring is seeded deterministically from regular running apps. A failed macOS
activation must leave the ring at its prior position so the next key can retry.

The status bar is rendered from `FlashStatusBarTemplate`: one template string can read Flash SDK state (`mode`, `active_app_name`, `active_bundle_identifier`, `date`), tmux-compatible variables, plugin state (`PluginStatusSnapshot` counts and plugin `status` segment values), or command/script output. The default template shows the mode cell on the left and the date on the right. Command-backed sections are stale-while-refresh: keep the previous successful value until a replacement is available, and do not blank a section during refresh. The controller is source-driven where possible: mode, focused-app, plugin, and clock changes publish directly; command/script sections get their own poll only when the template contains them. The top bar content is inset from the screen edges for rounded display corners. When the Flash status bar is enabled, Flash keeps the macOS top-band reservation in place, uses each screen's native reserved top-band height, falls back to the measured native menu-bar reveal height when macOS reports no top-band reservation, stays below the native menu/status bar reveal, and the `window_move` verb computes slots/remaps inside that reserved usable frame. Reading `NSStatusBar.system.thickness` and temporarily measuring `NSMenu.menuBarHeight` are allowed only for this geometry fallback; do not create additional persistent `NSStatusItem`s (the single sanctioned one lives in `StatusItemController.swift`; see hard rule 1), menu extras, app menus, or any other native menu/status UI.

`["flash", "enter_normal_mode"]` is the only accepted normal-mode entry. `[mode.normal.mappings]` and `[mode.insert.mappings]` mappings to it do not enable advanced mode by themselves. When no `[mode.all.mappings]` advanced-mode mapping is configured, the status bar is hidden and help stays simple while still listing the normal map.

### Verbs

Every action Flash takes must have a corresponding entry in `URLEventHandler.commands`. Keep `URLCommand`, parser wiring, `URLCommand.diagnosticDescription`, mapping help, README, default config examples, and tests in sync.

Normal-mode verbs currently include: `mouse_target [secondary=1|double=1|middle=1|triple=1|move=1|drag=1|select=1] [modifiers=cmd+…]`, `mouse_grid [secondary=1|double=1|middle=1|triple=1|move=1|drag=1|select=1] [modifiers=cmd+…]` (`drag=1` and `select=1` run a two-phase session: the first commit picks the anchor point, the second picks the end point, and the host synthesizes one continuous drag — or, for select, a click + shift-click text selection; `multi=1` keeps the session alive after every commit so several targets can be clicked, Escape ends it), `mouse_repeat` (re-click the last Flash-committed point; honours normal-mode counts), `mouse_target --adjust` (post-match precision sub-state: h/j/k/l or arrows snap the click point to the target's bounding-box edges, digits 1–9 interpolate across its width, 0 recentres, Return/space commits, Escape cancels; rejected on `mouse_grid` — the grid is already the precision surface), `mouse_target --search` (seek & click: type visible label/url text to filter the discovered targets — substring first, subsequence fallback — Tab cycles the highlighted selection, Return commits it with the pending click action, Escape cancels; `mouse_target` only), `mouse_target --scope=screen` (click variants only: hints across the front-most surface of every app on the focused window's screen via the explicit slower path — per-app complete-or-discard, multi-surface WindowServer visibility, one shared prefix-free assignment; the focused-app prepared model is never used), `mouse_dock` / `mouse_statusbar` (Dock items via the Dock's AX tree; menu-bar status items via WindowServer layer-25 geometry — a committed status-item click suspends capture for the menu it opens), `mouse_pointer` (freestyle pointer mode: h/j/k/l or arrows move with autorepeat acceleration, shift = 2px fine step, `m`/`,`/`.` click left/middle/right in place, `v` toggles a drag, Return/space clicks and exits with the grid-commit INSERT handoff, Escape/`q` exits), `focus_input` (Vimium `gi`: focus the count-th editable text input of the focused window via the AX focused attribute, then enter INSERT; default mapping `gi`), `scroll_target` (hint-label the focused window's AXScrollAreas; committing moves the pointer into the chosen one so every scroll verb — which already prefers the cursor's position — lands there; one area short-circuits to a direct move), and the flashlight's `@menus` source (`core.menus`, a built-in live source: the menu-bar-owning app's full menu tree walked on demand — Apple menu skipped, 3 s per-app cache — with selection pressing the AX menu item directly), `enter_command_mode [input=<text> restore_mode=1]`, `scroll_left`, `scroll_down`, `scroll_up`, `scroll_right`, `scroll_half_page_down`, `scroll_half_page_up`, `scroll_top`, `scroll_bottom`, `app_reload [force=1]`, `app_undo`, `app_redo`, `window_close`, `app_find`, `app_open_finder [all=1]`, `url_copy`, `tab_next`, `tab_previous`, `tab_first`, `tab_last`, `tab_select index=<n>`, `tab_close`, `history_back`, `history_forward`, `movement_back`, `movement_forward`, `app_quit [force=1]`, `app_save`, `app_save_and_quit [force=1]`, `app_print`, `document_open`, `window_new`, `tab_new`, `clipboard_copy`, `clipboard_cut`, `clipboard_paste`, `clipboard_copy_all`, `plugins`, and `plugin_command command=<command> subcommand=<subcommand>`.

`:flashlight <query>` results render below the centered command line, ordered top-to-bottom with the best match closest to the prompt. `:open <args>` is a dumb forward to `/usr/bin/open` and never enters the finder. App bundles are warmed and cached by `ApplicationSource`. Result titles include the source prefix, e.g. `[tmux] scratch gors` or `[firefox] Gmail (https://mail.google.com)`. Plugin candidates should provide their own `source` / `title` labels.

**Flashlight loading sequence.** On panel open the host renders and focuses the command prompt immediately with no result rows. Every default location source — including `core.apps` — joins `CandidateSnapshotBarrier`; ready/degraded plugin sources answer immediately from SDK-owned warm stores and `ApplicationSource` answers from its atomic installed-bundle cache. `ApplicationSource` starts that index asynchronously during resident startup. If the first open races it, the snapshot callback only awaits the already-running prewarm; activation never initiates filesystem I/O. The list is revealed exactly once, in deterministic source-id order, when every source settles or the 150-ms end-to-end first-paint budget expires. Every plugin lifecycle state other than ready/degraded settles immediately instead of consuming the paint budget. Late replies, including a late initial app index, are logged and ignored for that session; the next open reads the completed warm state. A `candidateFinderSessionGeneration` token and deadline cancellation drop work from closed or superseded sessions. The host keeps no persistent plugin candidate cache. Non-default source catalogs remain plugin-warm but are read/filtered only after the first explicit `@source`/`!`bang query.

**Candidate schemas.** Catalog rows (for `publish` and `search`) use `{ source: String, title: String, url: URL?, metadata: [String: String], effect: CandidateEffect? }`. `source` is first-class and must name one of the plugin's manifest-declared `sources[].name` descriptors; routing `source_id` is always host-stamped with `plugin:<manifest-id>` and never crosses the wire. `title` is the primary searchable string and the highest-precedence ranking field. `url` is the typed openable destination — apps point to their `.app` bundle file URL; browser tabs point to the page URL; sources without an openable destination omit it. `effect` is a closed, host-validated action union — `copy_text`, `insert_text`, and (rows only) `open` — and rendering never executes it. `metadata` is opaque to FlashCore and the matcher indexes its values at a low tier. The bundled host conventions (defined in `Sources/flash/App/CandidateMetadata.swift` and mirrored as `candidate_metadata::*` constants in `Plugins/_flash_plugin_rust/src/types.rs`) are: `kind`, `entity`, `pid`, `navigation_url`, `bundle_id`, `subtitle`, `payload`, `aliases`, `finishes_command`, `current_location`, `priority`. `priority` must be one shared enum value (`low`, `normal`, `high`, `important`, `urgent`), not a source-local number. Catalogs are bounded to 10,000 rows / 4 MiB encoded; titles to 4 KiB, URLs to 16 KiB, metadata to 64 entries with 256-byte keys and 64-KiB values, and effect text to 64 KiB. A publish is atomic: one malformed or oversized row rejects the complete catalog (the host keeps the previous one), never a valid-looking prefix. Query evaluators have the narrower `{ ok, answers: [{ title, subtitle?, effect }] }` response described above: they cannot emit URLs, metadata, or `open` effects, and the host stamps their registered source, `query_answer` kind, plugin ownership, urgency, and finisher behavior. Query responses are bounded to 16 answers / 256 KiB with 16-KiB title, subtitle, and effect-text fields.

**Flashlight source ordering.** Explicit `!<bang>` / `@source` intent owns the surface and does not run bare query evaluators. For bare text, ephemeral query answers occupy a fixed prepended lane and are never fuzzy-filtered by their answer title; the frozen catalog below them is ordered by `CandidateFinder.sortedMatches`. A deliberate exact/title-prefix/alias hit is promoted first. Default location rows then follow the strict category ladder `tmux window > running app > installed app > browser tab > remaining location`; match quality (the field-aware exact/prefix/word-prefix/substring/fuzzy ladder in `fieldScoreNormalized`) is authoritative only within one category. Defaults come from native source descriptors and plugin manifest `sources[].kind` values (`locations` vs. `default`) plus the shared source `priority` enum. Once match scores tie, source weight (including `precedence_alive_bonus` for pid-backed candidates), candidate priority, alive state, and stable identity break the tie in that order. `[flashlight.precedence]` overrides the source weight for specific source labels or parent prefixes; it does not change source kind or the category ladder.

**Flashlight bangs.** Registered plugin bangs are exclusively in scope when the user types `!`. With no `!` typed the candidate pool excludes bang candidates entirely; the moment the query starts with `!`, the pool is replaced with the bang registry alone (no app/tab/tmux noise), fuzzy-matched against the token text after `!`. Submitting a bang routes the remainder through `PluginManager.invokeShebang`; the catch-all `"*"` registration is reached through the same path when no exact token matches what the user typed. A bang manifest entry can declare a `candidate_source` — once the user confirms `!<token> ` (trailing space), the flashlight pool swaps to that source's live candidates so the user picks the target directly (e.g. `!kill ` → processes plugin's process list; selection routes through that source's `resolve_candidate`).

**Flashlight key bindings (unified contract).** App, browser-tab, tmux-window, and typed-effect answer rows are final destinations: selecting them with `<tab>` or `<cr>` submits the row, equivalent to `<cmd+cr>` (a calculator answer copies its exact result). Synthetic source-filter rows insert `@<source> ` and are never finishers, including on `<cmd+cr>`. Bang rows insert `!<token> `, and non-final real source-owned rows insert `@<source> <name> `. `<cr>` otherwise uses the insert-first path unless the selected candidate is a source-owned finisher (`Candidate.finishesCommand`), an exact primary-title match, or a text-insertion candidate such as an emoji. `<cmd+cr>` is the explicit force-submit/open chord for real candidates. Cycling moves to arrow keys and `<shift-tab>`. Command-line *completions* (`:help <topic>`, `:plugins <sub>`, `:<plugin> <action>`) keep their separate contract: `<tab>` inserts the value without sending, while `<cr>` inserts and then submits only for terminal/plugin-subcommand completions; `acceptsArgs` completions leave the line open.

**Flashlight source narrowing.** `:flashlight @<source> <query>` restricts the pool to one source — `@<source>` is the only structured filter, no `@<field>:<pattern>` form. `NormalModeDispatcher.candidateFinderSourceFilter` parses the first `@<token>` in the query; `CandidateFinder.candidateMatchesSourceFilter` matches it against `candidate.source` by exact name or prefix on dotted labels (`@firefox` matches `firefox.tabs`). A confirmed `@<source> ` with no residual text lists every candidate from that source — `:flashlight @emojis.glyphs ` enumerates the whole emoji set, otherwise excluded from the default pool. The flag is ignored in `:emojis` mode.

App/system verbs include: `enter_normal_mode`, `enter_insert_mode`, `enter_command_mode`, `alert_show message=... [duration=seconds style=standard|error]`, `alert_dismiss`, `hints_dismiss`, `app_open name=...`, `window_move ...`, `help_show`, `plugins`, `about`, and `quit`. `window_move` accepts either a named `position` or all four of `x`, `y`, `width`, and `height` as `%`-suffixed values relative to the Flash-usable screen; `x`/`y` are top-left offsets, and the usable frame reserves Flash's bar only on displays selected by `statusbar.monitor`. Named and proportional layouts are semantic intent retained across explicit screen moves, usable-frame changes, resolution changes, and display attachment/removal. Plugin actions also become command-line commands through their registered `command` field, e.g. `:spotify pause`.

**Plugin commands can raise a window.** A plugin's `perform` result may include `{ "ok": true, "target_pid": <pid> }`. When present, Flash activates that app (raising its window) after the command succeeds and records the jump into the movement history, so `ctrl-o` / `ctrl-i` replay it like any other navigation. This is how the tmux plugin's jump commands work: `:tmux session <name>` and `:tmux window <session:index>` route `switch-client` to the discovered local or remote backend, then return the exact terminal pid/window metadata hosting that backend. Bind them to a key with `["flash", "plugin_command", "--command=tmux", "--subcommand=window", "--args=main:1"]` (the `args` value is split on spaces). `target_pid` is optional — commands that don't move focus omit it.

**Command-line candidate contract.** Command and sub-command suggestions (`:help <topic>`, `:plugins <sub>`, `:<plugin> <subcommand>`, the top-level `:<tab>` list) are modelled by `CommandLineCompletion`. Every candidate has a **value** (`insertion`) and a **label** (`label`). The label is purely cosmetic — it is what shows in the suggestion list and never affects behaviour; when omitted, set it equal to the value so the value shows through. Selection semantics are uniform across built-in and plugin candidates: `<tab>` inserts the selected candidate's value into the buffer **without** sending the command (keep typing args), and `<CR>` inserts the value, then submits for terminal/plugin-subcommand completions or leaves the line open for `acceptsArgs`. Arrow keys (and `<shift-tab>`) cycle the selection. The candidate finder (`:flashlight` / `:emojis`) is a separate live-results mechanism with canonical command insertions; app, browser-tab, and tmux-window rows are final destinations and submit on `<tab>`/`<CR>`, `<CR>` may also open when the row is a finisher or exact enough, `<cmd+cr>` force-opens real candidates, and synthetic `[source] @...` rows only insert their source token. `:open` remains a direct `/usr/bin/open` forward and does not participate.

### Unified Action Contracts

Three normal-mode keys carry a single semantic meaning regardless of focused-app context. Plugins/sources own the context-specific dispatch; the host owns the uniform fallback. Adding a new source means deciding which of these you implement and which you let fall through.

**`f` — the `mouse_target` verb (click a hinted target).** `f` invokes the target set without modifiers for a same-context click; `F` invokes the same set with `modifiers=cmd+shift` as the global new-context gesture. All target roles preserve the requested modifiers, so Firefox now receives the same plain `f` as other native/browser apps and every `F` target receives Command-Shift. Terminal-content links use role `FlashTerminalLink` and add Shift (`f` Shift, `F` Command-Shift) because the emulator otherwise forwards the click to tmux instead of opening the link. `ctrl-f` / `ctrl-shift-f` retain the same plain/Command-Shift pair for `mouse_grid`. Hint providers run through `SourceRegistry.hintProviderPlan(for:)` in descending priority: built-in `AccessibilityProvider` (priority 10) is the universal default; a plugin opts in via a `hints` provider at higher priority (e.g., `Plugins/tmux` at 20). There is no additive merge: the first non-empty result wins, and an empty result advances only when that provider explicitly declares `fallback_on_empty` because its applicability is discovered dynamically. Individual hint targets may still carry the shared `priority` enum; `.important` and `.urgent` use the accent hint style without changing commit behavior. Providers return geometry and semantics only; `ActionDispatcher.perform` posts the host `CGEvent` directly and never calls provider/plugin activation code. Insert-mode entry after commit is driven solely by `JumpTarget.entersInsertMode`, which providers set per target.

**`t` — the `tab_new` verb (open a new tab/window in this context).** Routed through `SourceRegistry.tabNew` against every source advertising `.tabCreation`, in priority order. The first source whose disposition is not `.unhandled` wins; on `.failed` the host stops the chain (no keystroke fallback — see *Source action dispositions* below). On `.unhandled` from every source the host synthesizes a context-aware keystroke fallback via `AppDelegate.tabNewFallbackKey`: ⌘N for window-only terminal bundles (Alacritty), ⌘T elsewhere.

**`x` — the `window_close` verb (close current tab/window in this context).** Routed through `SourceRegistry.tabClose` against every source advertising `.tabClosing`. On `.unhandled` the fallback is ⌘W. Closing the last tab in a browser via the plugin's AppleScript path collapses to closing the window, matching the native ⌘W feel. The `tabClose` variant exists for the `tab_close` verb and uses the same dispatch.

**Source action dispositions.** `SourceActionResult.Disposition` is `.performed | .failed | .unhandled`. Use `.unhandled` only when the source doesn't apply to this context (wrong bundle, missing client, etc.); use `.failed` when the source owns this context but the underlying command failed or timed out — the host must NOT keystroke-fall-back after `.failed`, or a synthesized key can double-fire on top of a real (but late) effect. The Rust SDK exposes the same trichotomy as `SourceActionResponse::performed(pid)` / `failed(pid)` / `unhandled()`.

### Normal-Mode Audit Rule

Flash must never leave normal mode because focus changed on its own. Leaving normal mode must follow an auditable user-intent path, logged with a reason where practical. The **complete** set of valid insert transitions is:

- A normal-mode `a`, `A`, `i`, `I`, `o`, or `O` keypress (or its insert-mode verb twin invoked by the user).
- A configured unmapped `passthrough_keys` / `passthrough_modifiers` keypress. The original event continues natively and the mode changes to INSERT, including when the About window owns the keyboard (for example, default `cmd+w` closes About and enters INSERT); an explicit mapping still wins.
- A user-driven normal-mode command that intentionally opens a typing surface, currently `/` (`app_find`) and `t` (`tab_new`).
- A physical pointer click while idle normal mode is capturing input; Flash enters insert mode and replays the click so it reaches the underlying app.
- A committed `f` / `F` (`mouse_target`) click on a target whose owning provider set `JumpTarget.entersInsertMode = true`. `AccessibilityProvider` sets it on `AXTextField` / `AXSearchField` / `AXTextArea` / `AXComboBox`. A target with `false` is authoritative and stays normal even when the app already has editable focus — notably, both tmux pane and link hints stay in NORMAL.
- A committed `ctrl-f` / `ctrl-shift-f` (`mouse_grid`) left or double click. The grid is mouse simulation, so it enters insert unconditionally just like a physical pointer click. Grid move never enters insert, and grid right-click stays normal while its context menu owns the keyboard.

Nothing else may auto-enter insert. Specifically: focused-element changes, app activation, and unrelated configured key sequences must leave the mode alone. Do not reintroduce passive focused-element observers that switch to insert merely because macOS reports an editable focus. While advanced normal mode is active, Flash must aggressively recapture the overlay after app activation, app launch, Space changes, and panel key-focus loss; this intentionally prioritizes keeping normal-mode keyboard capture over preserving native menus or popovers.

Insert mode is allowed to leave automatically when input focus is lost. Track the pid that owned INSERT entry; if the focused app changes away from that pid, transition back to normal mode even if generic editable focus-loss exit was never armed. For focus changes inside the same app, require arming first: on INSERT entry, run a short delayed `AppMonitor.focusedElementIsEditable` probe for the active app; if it is false, leave generic focus-loss exit unarmed so non-input contexts can stay in INSERT pass-through. Once armed, a focused-element or focused-window change for the active app should query `AppMonitor.focusedElementIsEditable`, and if it is false, transition back to normal mode. If a mouse button is currently pressed, defer that transition until release and re-check editability; otherwise click-drag text selection gets interrupted by the normal-mode overlay recapturing mid-drag. Do not run that exit probe for `kAXValueChangedNotification`, or typing in an editable element will pay an AX query per keystroke.

Browser `t` (`tab_new`) is a special insert exit: after opening a browser tab, Flash may poll the focused document URL on the AX queue and return to normal once it changes from the pre-tab baseline/internal new-tab URL to a committed `http` / `https` URL. This covers address-bar Return, where browsers often keep the location field as the focused editable AX element after navigation, so generic focus-loss detection never fires.

One structural exception: when a config reload removes the last `["flash", "enter_normal_mode"]` binding (advanced mode no longer wired), Flash forces `.insert` because there is no normal mode without that binding. Reason `.advancedModeDisabled`, `force: true`.

`hints.keys` accepts either a literal alphabet (`"asdfghjkl"`, ASCII letters only, deduped) or a layout selector token. Selector syntax is `<$layout[_$row][_$hand]+...>` where layout is `qwerty` / `colemak` / `dvorak`, row is `homerow` / `toprow` / `bottomrow`, and hand is `lefthand` / `righthand`. Examples: `<colemak>`, `<colemak_homerow+colemak_toprow>`, `<colemak_homerow_lefthand+colemak_toprow_righthand>`, `<colemak_lefthand>`. Selectors cannot mix layouts. Layout selectors are scored by the inferred layout's key scores; literal strings are scored by their written order. There is no `hints.layout` key. Resolution lives in `Alphabet.resolve(_:)`.

**Flash always walks the focused app only.** There is no `hints.scope` knob and no multi-app walk machinery — background apps and other monitors are ignored. `JumpTarget.pid` carries the focused app's pid so `commit` can re-activate it before dispatching the click. There is **no per-walk deadline** — walks always run to their `maxDepth`/`maxTargets` caps.

## Permissions

Required:

- **Accessibility** — required for AX walks and `AXUIElementPerformAction`. Granted in *System Settings → Privacy & Security → Accessibility*. The bundle identifier is `com.flash.app`; release installs live at `/Applications/Flash.app`, dev installs at `/Applications/Flash 🧪.app` (moving between them re-prompts the grant once).

Declared / conditional:

- **Automation (`NSAppleEventsUsageDescription`)** — declared for the `app_open` verb's Launch Services calls (launch/reopen/focus another app) and so the `flash` CLI can AppleEvent into the resident. Flash still discovers browser page content through `AXWebArea` descendants in the AX tree, not via `do JavaScript`.

Not required:

- **Input Monitoring** — **NOT** required and **NOT** requested. Flash's session-level `KeyboardCaptureTap` (see rule 2) operates under the Accessibility grant, so it does not need the separate Input Monitoring permission. If you find yourself wanting to request Input Monitoring, stop and reconsider.
- **Screen Recording** — **NOT** required and **NOT** requested. See rule (7) above. The plist no longer declares `NSScreenCaptureUsageDescription`.

### TCC and rebuilds

`./Scripts/install.sh --dev` signs with the stable self-signed "Flash Dev" identity (autostart is app-owned via SMAppService; the script removes the legacy LaunchAgent). The first run with that identity resets Accessibility once so the next grant binds to the stable certificate; subsequent rebuilds should preserve the grant.

## Build / install / verify

**Every app-code change requires reinstalling** to see it in action. Flash is a resident background process launched out of the installed bundle (dev: `/Applications/Flash 🧪.app`); there is no app-code live-reload, dev server, or attached debugger flow. Plugin files can live-reload through `PluginManager` when bundled plugins are symlinked by `Scripts/install.sh --dev`. `swift build` produces a binary in `.build/` that the resident process is *not* using — only the installed copy matters. So the developer loop is:

```bash
# Make code change → run install (NOT just `swift build`)
./Scripts/install.sh --dev

# Trigger and verify
flash mouse_target
```

**Iteration-loop rule (agents): every iteration ends with deploy + commit + push.** After each change that builds and passes tests, the loop is non-negotiably: (1) `./Scripts/install.sh --dev` so the running app reflects the change, then (2) commit and push. Don't batch several changes before deploying, and don't leave verified work uncommitted — each green iteration is deployed and pushed before moving on.

`./Scripts/install.sh --dev` is what builds optimized current-arch products, codesigns, quits the running instance, replaces the bundle, symlinks bundled plugins for live reload, and relaunches. After any code edit (Swift, Info.plist, config defaults, scripts), re-run it. `swift build` / `swift test` are useful only for type-check and unit tests — they do **not** update the binary the system actually runs. `./Scripts/build.sh --dev` does the same build without installing; `--release` produces an optimized universal (Intel + Apple Silicon) `.app` + zip.

```bash
# Build only (debug; type-check + unit tests, NOT for behaviour verification)
swift build

# Tests
swift test

# Build optimized current-arch, install to /Applications/Flash.app, relaunch — required after every app-code change
./Scripts/install.sh --dev
```

`--dev` is the fast inner loop: an incremental current-arch build (debug Swift + `plugin-dev`-profile plugins), then reinstall + restart. Because dev installs symlink `Contents/Resources/Plugins` to the live `Plugins/` tree and `PluginProcess` watches each plugin directory, rebuilding a plugin binary (the `mv -f` swap in `build-plugins.sh` lands as a `rename`) triggers `scheduleFileReload()` and restarts only that plugin — the resident Flash process and every other plugin keep running. If the watcher doesn't pick up a new plugin binary (e.g. `[plugins] watching_enabled = false`), run `:plugins reload` in Flash's command-line cell. Any change to Swift code, `Resources/Info.plist`, `config.default.toml`, or the bundle / signing flow requires a full `./Scripts/install.sh --dev`.

`install.sh --dev`:

1. `swift build --product flash` (debug, incremental) in parallel with `build-plugins.sh dev` (plugin-dev profile) and `build-inspector.sh --dev` — the single flash Mach-O is both resident and CLI
2. Assembles `build/Flash.app` from the resident binary and `Resources/Info.plist`
3. Codesigns the staging bundle
4. Quits any running Flash (`osascript`, `flash flash_quit`, `pkill` fallback)
5. Replaces `/Applications/Flash.app`
6. Codesigns the installed copy
7. Symlinks `~/.local/bin/flash` to the bundled CLI
8. Symlinks official bundled plugins from the checkout into `Contents/Resources/Plugins`
9. `open` the installed app so it's resident again

After install, verify:

- `pgrep -fl '/Applications/Flash.app/Contents/MacOS/flash'` shows one PID.
- `flash hints_dismiss` triggers no visible side effect (overlay was already hidden).
- `flash help_show` opens the in-app help topic index.
- `flash flash_quit` exits the process; relaunch with `open /Applications/Flash.app`.

Karabiner-Elements mappings live in `~/.config/karabiner/karabiner.json` under `profiles[<active>].complex_modifications.rules`.

## Dead code analysis

Static, index-based detection of declarations with no callers. Both tools are read-only — **review findings before deleting.**

### Swift — periphery

```bash
brew install periphery          # macOS-only Swift tooling
periphery scan --disable-update-check
```

`periphery scan` builds the SPM package with an index store and reports unused functions / properties / initializers / types / enums / imports across every target (tests included, so test-only helpers are *not* flagged). `.periphery.yml` pins the config.

It cannot see cross-language usage: **FlashCore / FlashProviders public API consumed by Rust plugins over the plugin IPC has no Swift call site and is reported as unused — it is not dead.** Review every `FlashCore` / `FlashProviders` finding against the plugin protocol before deleting. The app layer (`Sources/flash`) has no external consumers, so its findings are safe to remove.

### Rust — built-in `dead_code` lint

```bash
find Plugins -name '*.rs' -not -path '*/target/*' -exec touch {} +   # force cached crates to re-emit
export CARGO_TARGET_DIR="$PWD/build/plugin-target"
for dir in Plugins/_flash_plugin_rust Plugins/[!_]*/; do
  [ -f "$dir/Cargo.toml" ] || continue
  (cd "$dir" && cargo clippy --workspace --all-targets 2>&1) |
    grep -iE 'never used|never read|never constructed'
done
```

The plugins are binary crates, so rustc's `dead_code` lint flags unused items (including `pub`) with no extra tooling — touch the sources first, since incremental builds suppress warnings for unchanged crates.

## Testing UI behavior

Tests in `Tests/FlashTests/` are stratified by what they exercise:

- **Pure-unit** (`AlphabetTests`, `ConfigLoaderTests`, `HintAssignerTests`, `SourceCandidateTests`, …). Deterministic, run in milliseconds, no external state. Run on every `swift test`.
- **tmux logic** (link extraction, cell geometry, status-bar parsing, client/process-tree resolution) lives in the Rust `Plugins/tmux` crate — cover changes there with crate tests, not Swift tests.
- **Browser integration** (`Scripts/test-integration-browser.sh`). Provisions a Firefox profile template with a pinned reference extension, builds/codesigns the browser oracle runner, then runs every `Tests/BrowserSnapshots/snapshots/*.html` fixture through a parallel worker pool. `manifest.json`, when present, is only optional metadata/order; unlisted snapshots still run by default. Each worker gets its own Firefox profile and Marionette port. Per fixture, Marionette injects fiducials and captures reference marker DOM via WebDriver script execution; Flash walks Firefox's AX tree; the two sets are diffed under strict-ISO. Catches both undermatch and overmatch against the browser reference. Run order: build + sign once (`./Scripts/install.sh --dev` to create the `Flash Dev` identity), then `./Scripts/test-integration-browser.sh`. The script kills its oracle app and Firefox worker-profile processes on exit/interruption.
- **Native AppKit integration** (`Scripts/test-integration-native.sh`). Builds/codesigns `flash-native-fixture` and `flash-native-oracle`, launches a deterministic AppKit window, compares generic AX targets against expected controls, verifies a host mouse click mutates a fixture state file, and records the open-NSMenu limitation under the no-key-capture production rule. It covers buttons, image-backed buttons, duplicate labels, checkboxes, radio buttons, popups, search/text areas, tabs, rows, and negative controls such as disabled/hidden/decorative/slider elements. It does not add production global key capture or private APIs, and the script kills its test apps on exit/interruption.
- **Electron integration** (`Scripts/test-integration-electron.sh`). Runs `npm ci` for the pinned Electron fixture, builds/codesigns `flash-electron-oracle`, launches Electron with a deterministic DOM fixture, reads expected target JSON emitted by the fixture, compares it against Flash's generic AX provider output, and verifies a host mouse click mutates fixture state. The script kills its oracle app and fixture Electron process on exit/interruption.

Run order:

```bash
swift test                                           # unit (incl. plugin engine + host RPC suites)
./Scripts/test-plugins.sh --lane all                 # spec validation, lint, cargo units, builds, and the full conformance matrix (plugins + probes + sandbox lane)
./Scripts/install.sh --dev                           # one-time: creates the Flash Dev signing identity
./Scripts/test-integration-browser.sh                # builds + signs + runs the browser corpus
./Scripts/test-integration-native.sh                 # builds + signs + runs native AppKit fixture
./Scripts/test-integration-electron.sh               # installs pinned Electron fixture and runs oracle
```

A plugin/protocol change is not done until `Scripts/test-plugins.sh --lane
all` is green, and a protocol bug found in any SDK lands its repro spec in
`Plugins/_flash_plugin_specs/regressions/` BEFORE the fix (see the README
there): the shared suite is the cross-stack ISO-behavior guarantee, and it
only grows. `:plugins doctor` is the in-app checkhealth.

Anything that requires the full overlay / commit pipeline (chip rendering, key handling, host clicks against a live focused app) is still **manually verified**: run `./Scripts/install.sh --dev`, grant permissions if needed, then exercise the app in real target apps.

Do not claim UI-level changes "work" based on the type-checker alone. State explicitly when you couldn't verify visually.

## Known limitations

### Open menus dismiss when Flash activates (largely resolved)

When any non-menu window becomes the system's key window, AppKit's menu
tracking session cancels and the menu closes. Historically Flash's overlay
panel became key to receive hint keystrokes via `NSPanel.keyDown`, which
tripped this dismissal whenever Flash was triggered on top of an open
`NSMenu` / `NSPopover` / popup-button menu.

Flash now captures NORMAL / hint keystrokes through the session-level
`KeyboardCaptureTap` (a `CGEventTap`) **without** taking key window, so with
the Accessibility grant in place activating Flash no longer collapses an open
menu. This is the "global event tap" approach that used to be off the table;
it is now the sanctioned capture path (see hard rule 2).

Residual: the collapse can still occur only in the key-window *fallback*
path, which is reached only when the Accessibility grant is missing — in which
case hint clicking itself would not work anyway. Rendering below the menu
plane via private CGS / SkyLight APIs remains out of scope.

### `cmd+tab` cannot be fully intercepted without user opt-in

`RegisterEventHotKey` accepts a `cmd+tab` registration and Flash's
callback fires when the user presses it, but the Dock's system-wide app
switcher uses a CGEventTap that runs before Carbon's hot-key dispatch
and consumes the event itself. Both fire — Flash's mapping (e.g.
`cmd+tab → app_next`) runs **and** the system switcher appears.

The only standard-API workaround is for the user to disable the system
shortcut in **System Settings → Keyboard → Keyboard Shortcuts → Mission
Control → "Move focus to next window"** (or the variant on their macOS
release). After that, Flash's Carbon binding is the only handler. We
don't auto-disable it on the user's behalf; the default `cmd+tab` mapping
stays in the normal-mode map for users who've opted in.

## Common pitfalls

- **AX `AXUIElementPerformAction` requires Accessibility permission.** Without it, the call returns `.notImplemented` or `.cannotComplete` silently; the user sees nothing happen. `--doctor`-equivalent diagnostics live in `Permissions/PermissionCheck.swift` (currently only AX check; extend if adding more required perms).
- **`AXObserver` callbacks run on the main run loop.** Don't do AX work inside them — schedule onto `refreshQueue`.
- **`NSPanel(.nonactivatingPanel)` can become key without activating the app.** That is intentional: the overlay needs to receive keys without stealing the target app's frontmost status. `commit` reactivates the owning app before dispatching its host mouse event.
- **`CGEventSource` `.combinedSessionState`** is the right choice for synthesizing input; it sees the current modifier state, so e.g. shift held during commit doesn't poison the click.
- **New keyboard-owned interaction surfaces are hints sub-states, not `OverlayInputMode` cases.** Follow the `--adjust` / `--search` / pointer-mode pattern: a panel flag routes `.hints` keys to a pure, unit-tested interpreter and one coordinator callback, with sub-state fields living in `HintSession` so the single-assignment reset covers them. Adding an `OverlayInputMode` case instead ripples through the mode projection, `shouldSwallow`, and capture policy for no benefit.
- **The deny-default seatbelt profile cannot host networked CLIs.** TLS needs trustd mach allowances and credential reads hit the hard-coded secrets deny list (verified empirically with `gh`, whose token lives in the keychain). Wrappers around such tools use the unsandboxed `subprocess` shape like tmux; do not try to widen the profile instead.
- **Seatbelt counts unix-domain-socket connects as `network-outbound`.** A sandboxed plugin that talks to a local socket (kitty remote control) must declare the `network` capability or every connect is silently denied.
- **Stage commits with explicit paths, never `git add -A`.** The maintainer edits this checkout concurrently; a blanket add sweeps their in-flight work into your commit.

## When in doubt

Add a one-line `print` (it goes to stderr → log file in production via the launched bundle) before guessing. Real AX traces win arguments fast.
  flash-native-fixture/              # AppKit fixture app for native integration tests.
  flash-native-oracle/               # Signed CLI oracle that drives the native fixture through AX.
  flash-electron-oracle/             # Signed CLI oracle for the pinned Electron fixture.
