# AGENTS.md — guide for AI agents working on Flash

This document orients an agent (Claude, etc.) editing the Flash codebase. Read this before touching anything beyond a trivial change.

## What Flash is

A headless, resident macOS app that, when triggered by `flash mouse_target` from the CLI or a configured mapping, overlays hint labels on clickable elements in the focused app and clicks or moves to one when the user types its hint. It also supports normal/insert/command modes, a persistent top status bar when advanced mode is enabled, managed stdio plugins, `mouse_grid` screen-position targeting, `alert_show message=...` / `alert_dismiss` for a temporary centered toast, and `help_show` / `plugins` modal views. No menu bar, no Dock icon, no preferences window.

Activation comes either through the `flash` CLI (which AppleEvents the verb to the resident over a custom event class) or through Flash's `[mode.all.mappings]` / `[mode.normal.mappings]` / `[mode.insert.mappings]` Carbon registry. Mapping values are always argv arrays. Arrays whose head is `"flash"` resolve through the in-process verb table (the same one the AppleEvent handler consults); any other head is launched as argv with `~` and env expansion on each element. There is no `flash://` URL scheme and no separate `flashctl` binary — the `flash` Mach-O does both jobs.

## Hard rules (do not violate)

1. **No UI surface** beyond the transparent hint overlay, the advanced-mode status bar / command-line cell, the help and open-app overlays, and explicit `alert_show` toast. No menu bar item, no `NSStatusItem`, no `NSDockTile`, no `NSAlert`, no preferences window. Logging is stderr / `~/Library/Logs/Flash/`.
2. **No arbitrary global key capture.** `RegisterEventHotKey` is allowed only for explicit modified-key entries in `[mode.all.mappings]`, `[mode.normal.mappings]`, or `[mode.insert.mappings]`. Do not add `CGEventTap`, global key monitors, keyloggers, or Input Monitoring. Hint, normal-mode, command-line, help, and open-app typing still belongs only in `NSPanel.keyDown` on the overlay panel itself.
3. **Autolaunch is install-script-owned.** `Scripts/install.sh` may install the user LaunchAgent that opens `/Applications/Flash.app` at login. Do not add login-item UI, background helpers, or additional autostart mechanisms elsewhere.
4. **No unowned resident helpers / no custom external IPC.** External activation is `NSAppleEventManager` receiving the custom `Flsh`/`Cmd ` event class from the `flash` CLI; native mappings dispatch pre-resolved `MappingAction` values in the resident app. Flash-managed plugin children are allowed only through length-prefixed MessagePack over stdin/stdout with stderr reserved for unexpected errors; Flash owns their lifecycle, heartbeat, reload, and shutdown. Do not add Unix sockets, mach services, background helpers, daemonized clients, or any always-running client outside `PluginManager`. Do not re-introduce a `flash://` URL scheme; the only allowed external entry point is the custom AppleEvent sent by the `flash` CLI sibling.
5. **Single resident process.** Code assumes one `NSApplication` instance; bundle identifier `com.flash.app`.
6. **Hand-rolled infrastructure inventory — do not "fix" by adding a dependency.** Several pieces of plumbing in this repo are intentionally hand-rolled to keep the dep graph minimal and the wire formats / parsers under our own version control. Before reaching for a library, check this list first; if your change needs to touch one of these surfaces, extend the hand-roll rather than swap it out. The list (file → what it is → why the hand-roll stays):
   - `Sources/FlashCore/MessagePack.swift` — thin Foundation-to-`MessagePackValue` shim over `a2/MessagePack.swift`. The wire format itself (length-prefixed MessagePack value, 4-byte big-endian length + payload) is frozen, but the codec is library-driven; rmp-serde on the Rust side decodes whatever width the library emits.
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
10. **Dev deploys go through `./Scripts/install.sh --dev`.** It owns the optimized current-arch build → codesign with the stable `Flash Dev` identity → kill running instances → reinstall to `/Applications/Flash.app` → launch flow. **Do not** hand-roll `cp build/flash /Applications/Flash.app/Contents/MacOS/flash && codesign … && pkill && open …` in agent sessions — TCC/permissions, plugin install stamps, and the launch agent all depend on the script's exact ordering. If you need a one-step "build and verify", run `./Scripts/install.sh --dev` (incremental, current-arch). Bare `./Scripts/install.sh` defaults to `--release`: a full, clean, universal build — slower, and its ad-hoc signature re-triggers the TCC grant, so reserve it for shipping.

If a request would violate any of the above, surface it to the user instead of silently complying.

## Project layout

```
Package.swift                        # SwiftPM, macOS 14+, swift 5 mode
config.default.toml                  # Canonical user-facing config reference
Sources/
  FlashCore/                         # Public SPI (source protocol + value types)
    AppContext.swift                 # Front-app context: bundle, pid, window frame
    JumpTarget.swift                 # A clickable thing with a screen rect + optional activate closure
    JumpAction.swift                 # .leftClick | .rightClick | .doubleClick
    FlashSource.swift                # FlashSource protocol + readiness/activation policy + capability set
    TargetFinalizer.swift            # Shared visible-region filter + smaller-frame-wins dedup before label assignment
  FlashProviders/                    # Built-in jump-target sources (depend on FlashCore + AppKit)
    Accessibility/AccessibilityProvider.swift   # Generic AX walk. Open class.
    Accessibility/AXClick.swift                 # AX-level click utilities (tryActions, setFocus, hasPressAction, clickAtPoint). Shared by AccessibilityProvider and ActionDispatcher.
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
      ActionDispatcher.swift         # AXPress preferred; CGEvent click fallback
      SourceRegistry.swift           # Built-in source descriptors; activation-gated source loading + priority chain
      PluginSystem.swift             # manifest.json, MessagePack plugin process lifecycle, plugin source adapter
      DebugServer.swift              # loopback-only dense HTTP/SSE debug page
      CandidateFinder.swift                # Shared :open candidate preparation and app merge helpers
      ApplicationSource.swift        # Running/installed app source and `app_open` verb resolver
      BrowserTabSources.swift        # Shared helpers for :open browser tabs (bundle IDs, AX/AppleScript utilities)
      FirefoxTabsSource.swift        # FirefoxTabsSource — AX-driven, enabled only while Firefox is running
      SafariTabsSource.swift         # SafariTabsSource — AppleScript with AX fallback, enabled only while Safari is running
      ChromiumTabsSource.swift       # ChromiumTabsSource — AppleScript-driven, enabled only while a Chromium-family browser is running
      SlackSource.swift              # :open Slack channels, enabled only while Slack runs
    Config/
      Config.swift                   # Decoded model — defaults here MUST match config.default.toml
      ConfigLoader.swift             # TOMLKit-backed TOML loading + DispatchSource fs-watch hot-reload
      Alphabet.swift                 # layout selector / literal hints.keys resolution
    Permissions/PermissionCheck.swift  # AXIsProcessTrusted() — read-only, no UI prompt
Tests/FlashTests/                    # XCTest: Alphabet, ConfigLoader, HintAssigner, TargetFinalizer, WindowSnapshot, plugin system, source candidates, browser fixture catalog, shared integration support.
Tests/BrowserSnapshots/              # Browser integration manifest + 100 offline HTML snapshots used by Scripts/test-integration-browser.sh.
Tests/ElectronFixture/               # Pinned minimal Electron app used by Scripts/test-integration-electron.sh.
Plugins/                             # Official bundled Rust plugins, members of the Plugins/Cargo.toml workspace, symlinked into the dev app
Plugins/_rust_flash_plugin/          # Shared Rust plugin SDK crate (package flash_plugin); no Flash business concepts
Resources/Info.plist                 # LSUIElement, AppleEvent usage description
Scripts/build-plugins.sh                     # cargo build [dev|release] every Plugins/*/ crate → flash-plugin-<id> binary beside its manifest (dev = optimized current arch; release = universal lipo)
Scripts/_common.sh                           # Shared constants + helpers (signing identity, login agent, app assembly) sourced by build.sh / install.sh
Scripts/build.sh                             # Build Flash.app into build/ without installing. Default --release = clean universal optimized + zip; --dev = fast incremental optimized current-arch
Scripts/install.sh                           # build.sh then install to /Applications/Flash.app + restart. Default --release = clean universal; --dev = stable dev-signed, plugin symlinks
Scripts/test-integration-native.sh           # Build/sign/run native AppKit integration fixture + oracle
Scripts/test-integration-electron.sh         # Install pinned Electron fixture deps, build/sign/run Electron oracle
Scripts/check-guardrails.sh                  # CI hard-rule scanner for banned production APIs / stale config references
README.md                            # User-facing
AGENTS.md                            # This file
```

## Activation flow (read this before editing the hot path)

1. The `flash` CLI runs (`flash mouse_target [secondary=1|double=1|move=1]`, `flash mouse_grid [secondary=1|double=1|move=1]`), or a configured `[mode.*]` mapping fires a pre-resolved `MappingAction`. The CLI sends a custom AppleEvent (class `Flsh`, ID `Cmd `); mappings dispatch the same `URLCommand` value directly.
2. URL-scheme activation routes via Launch Services to the running instance as a `kAEGetURL` Apple Event; native mappings dispatch a pre-resolved action inside the resident process.
3. `URLEventHandler` parses URL host/query for AppleEvents and provides the shared parser used by mapping config loading.
4. `AppDelegate.activate(action:)` captures `NSWorkspace.shared.frontmostApplication`'s pid via `AppMonitor.currentContext()`, then takes an activation generation token.
5. `AppMonitor.discoverAsync` first tries the AX-event-driven prepared model (see *Prepared model contract* below). On hit, native AX-backed `[AssignedHint]` values are delivered to main without an activation-time AX walk. The tmux plugin remains activation-only because its output is volatile.
6. On the AX queue, `AppMonitor` runs the selected provider chain in descending priority against the focused app only, filters candidates by the focused pid's WindowServer-derived visible region (occluded pixels excluded), then dedupes overlapping rects via spatial-hash with a **smaller-frame-wins** policy (`> 70%` overlap → smaller rect survives). Inside `AccessibilityProvider`, the focused window's direct children are fanned out across concurrent walkers, and action-name IPCs for tentative web-area / AXImage targets are resolved in a parallel post-pass.
7. `HintAssigner.assign` produces prefix-free labels using the configured alphabet — pre-uppercased as `AssignedHint.display`, memoised by `(alphabet, leftHand, length)`.
8. Bounces back to main; if the activation generation still matches (no cancel / app switch / commit in flight), `OverlayPanel.display(hints:)` wraps all layer mutations in `CATransaction.setDisableActions(true)` → no implicit animation; chips appear in place.
9. Panel becomes key (without activating Flash as app, because it's a `.nonactivatingPanel`).
10. `OverlayPanel.keyDown(with:)` matches typed prefix against assigned labels; on a unique match, `AppDelegate.commit` reactivates the focused pid (via `hint.target.pid`) and runs `ActionDispatcher.perform` after a 20 ms delay. The activation gate stays closed across that delay so a rapid second ctrl+space can't race.
11. `ActionDispatcher` runs the click through a three-step pipeline. (1) Call the provider-owned `target.activate` closure — AX targets try AXPress/AXOpen/AXConfirm (or focus-set for text inputs), and right click tries AXShowMenu. (2) On failure, AX-hit-test at the click point via `AXClick.clickAtPoint`, then try the press-style actions on that element + its ancestors. Cursor doesn't move and this often recovers inert-wrapper / handler-on-descendant cases (Firefox tab strip, React `role="tab"` widgets). (3) Final fallback: synthesized `CGEvent` click, including double-click — cursor warps to the point hidden, clicks, warps back, unhides. The dispatcher is the only place mouse synthesis lives; the providers themselves never synthesize.
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

An earlier cache attempt got this wrong by serving deadline-truncated snapshots, and by falling back to a fresh walk on cache miss — so two presses in the same UI state could land on either a partial snapshot or a complete fresh walk, producing different hint sets. That broken cache was deleted.

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
- Any of these AX notifications on the focused pid: `kAXFocusedUIElementChanged`, `kAXFocusedWindowChanged`, `kAXMainWindowChanged`, `kAXLayoutChanged`, `kAXSelectedChildrenChanged`, `kAXSelectedRowsChanged`, `kAXValueChanged`, `kAXWindowResized`, `kAXWindowMoved`, `kAXTitleChanged`, `kAXCreated`, `kAXUIElementDestroyed`, `kAXRowExpanded`, `kAXRowCollapsed`.

**Walk life-cycle:**

1. `scheduleModelRefresh(for: pid)` — 80-ms debounced. Multiple bumps coalesce.
2. On debounce fire, capture `startToken = dirtyTokens[pid]` and `configRevision` on main, dispatch a continuous-provider walk on `axQueue`.
3. Walk runs to completion (never truncated).
4. Result hops back to main. If token and config revision still match AND pid is still frontmost → write a `PreparedModel` with targets, assigned hints, token, config revision, and timestamp. Else discard.
5. A maintenance refresh is scheduled before the freshness ceiling so a quiet focused app stays warm.

**Activation lookup** (`lookupPreparedModel`):

- Model hit iff `model.dirtyToken == dirtyTokens[pid]` AND `model.configRevision == configRevision` AND `now - model.computedAt < modelFreshnessMs`.
- On miss, activation waits for a model build and stores it if still valid; if the build also returns nothing (e.g. focused-window changed mid-build) activation falls back to a synchronous full provider walk.
- Volatile providers (`readinessPolicy == .volatile`, e.g. `TmuxProvider`) skip prepared-model lookup and writes entirely; activation runs the full provider chain on demand.

If you add new AX events that mutate UI state, add them to `AppMonitor.observedNotifications` in the same commit — otherwise the model can silently serve stale hints when those events fire. The freshness ceiling is a safety belt for events we forgot to subscribe to; don't lean on it as a primary mechanism.

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

A source conforms to `FlashSource` in `FlashCore`. A source can contribute jump targets, `:open` items, document URL resolution, app activation, or any combination through `capabilities`:

```swift
public protocol FlashSource: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var priority: Int { get }
    var capabilities: FlashSourceCapabilities { get }
    var activationPolicy: FlashSourceActivationPolicy { get }
    var readinessPolicy: FlashSourceReadinessPolicy { get }
    var candidateSourceLabels: [String] { get }
    var candidateSourceDescriptors: [CandidateSourceDescriptor] { get }
    func supports(_ context: AppContext) -> Bool
    func discover(in context: AppContext) throws -> [JumpTarget]
    func candidates(in environment: FlashSourceEnvironment, scope: CandidateScope) -> [Candidate]
    func queryCandidates(in environment: FlashSourceEnvironment, request: CandidateQuery, completion: @escaping ([Candidate]) -> Void)
    func resolveCandidate(_ item: Candidate, in environment: FlashSourceEnvironment, completion: @escaping (CandidateResolution) -> Void)
    func tabSelect(at index: Int, in context: AppContext, environment: FlashSourceEnvironment, completion: @escaping (SourceActionResult) -> Void)
    func tabNext(in context: AppContext, environment: FlashSourceEnvironment, completion: @escaping (SourceActionResult) -> Void)
    func tabPrev(in context: AppContext, environment: FlashSourceEnvironment, completion: @escaping (SourceActionResult) -> Void)
    func tabNew(in context: AppContext, environment: FlashSourceEnvironment, completion: @escaping (SourceActionResult) -> Void)
    func tabClose(in context: AppContext, environment: FlashSourceEnvironment, completion: @escaping (SourceActionResult) -> Void)
}
```

Most source methods are optional in practice through default protocol-extension implementations that return no candidates, no document URL, or `.unhandled`. Implement only the capabilities the source actually owns.

Steps:

1. Create the source in `Sources/FlashProviders/<Group>/` when it is reusable jump-target logic, or under `Sources/flash/App/` when it is app-owned `:open` / command-resolution glue.
2. Implement the protocol. For jump targets, return a complete deterministic `[JumpTarget]` set with **global NSScreen coordinates** (bottom-left origin of primary screen). Do not deadline-truncate output.
3. For `:open` / `:flashlight` items, return `Candidate` values using the canonical `{ source, name, url }` contract. `source` is a short stable label, `name` is the primary title, and `url` should be openable whenever present. App candidates must use an absolute `file://` URL to the `.app` bundle; browser tabs and external resources should use their canonical openable URL. Omit `url` only when the source must resolve through source-specific payload or AX state. Use the shared `FlashPriority` / plugin SDK `Priority` enum (`low`, `normal`, `high`, `important`, `urgent`) for candidate row salience; do not invent plugin-domain source kinds for ranking.
4. Pick an activation policy. Use `.always` only for cheap universal sources, `.bundleIDs(...)` for app-scoped sources like Slack/browser tabs, and `.terminalBundles` for terminal-backed sources. `SourceRegistry` instantiates non-`.always` sources only while a matching app is running.
5. Register a `SourceDescriptor` in `Sources/flash/App/SourceRegistry.swift`. Pick a numeric provider priority for overlapping jump-target providers — higher wins. Candidate source descriptors separately declare generalized source priority with `CandidateSourceDescriptor(name:kind:priority:)` or plugin manifest `sources[].priority`; keep those source priorities semantic (`low` … `urgent`) rather than plugin-specific.
   Existing jump-target provider scale:
   - 20: the bundled `tmux` plugin (terminals with a tmux client in the process subtree)
   - 10: generic `AccessibilityProvider` (universal AX walker; also handles browser in-page DOM via `AXWebArea` descendants)
6. Add focused tests. At minimum cover source activation gating in `SourceRegistryTests` or the source's parsing/resolution helpers, then update README when user-facing behavior changes.

Flash deliberately uses **only two jump-target sources**: `AccessibilityProvider` as the universal default, and the bundled `tmux` plugin's hints provider for terminals whose visible content macOS Accessibility cannot see. App-specific sources may contribute `:open` items or custom resolution when that data does not belong in the AX walker. There is no DOM bridge / `do JavaScript` provider — browser page content reaches us through `AXWebArea` descendants the same way every other web area does. If you find yourself reaching for AppleScript-based discovery, surface that to the user instead of adding it.

A `JumpTarget.activate` closure overrides the default action. Use it when the underlying API has a cheaper / more reliable way to "click" than synthesizing a `CGEvent` (e.g. AX can call `kAXPressAction`).

## Configuration

`~/.config/flash/flash.toml`. Hot-reloaded via `DispatchSource.makeFileSystemObjectSource`. `$XDG_CONFIG_HOME/flash/flash.toml` takes precedence when `XDG_CONFIG_HOME` is set. There is no legacy `~/.flash.toml` fallback. TOML syntax is parsed with the Swift package `TOMLKit`; `Sources/flash/Config/ConfigLoader.swift` owns only Flash's typed schema, validation, source-location indexing for known values, and command-path resolution.

The user-facing top-level sections are exactly `[hints]`, `[open]`, `[plugins]`, `[statusbar]`, `[flashlight]`, `[flashlight.aliases]`, `[flashlight.precedence]`, `[mode]`, `[mode.all.mappings]`, `[mode.normal]`, `[mode.normal.mappings]`, `[mode.insert.mappings]`, and `[debug]`, in that order in `config.default.toml`.

**`config.default.toml` at the repo root is the canonical user-facing reference.** When you change a default or add a mapping/action, update `Config.swift`, `ConfigLoader.swift`, `URLEventHandler.swift` when needed, `config.default.toml`, `README.md`, this section, and tests in the same commit.

Keys:

| Key                                | Type           | Default              |
| ---------------------------------- | -------------- | -------------------- |
| `hints.keys`                       | string         | `"<qwerty_homerow+qwerty_toprow>"` |
| `hints.min_length`                 | int            | `1`                  |
| `hints.magic_modifiers`            | string array   | `["cmd", "ctrl", "alt", "shift"]` |
| `hints.mouse_grid_steps`           | int (2..6)     | `3`                  |
| `hints.mouse_grid_opacity`         | float (0..1)   | `0.5`                |
| `open.ignored_apps`                | string array   | `[]`                 |
| `plugins.disabled`                 | string array   | `[]`                 |
| `plugins.third_party`              | string array   | `[]`                 |
| `plugins.watching_enabled`         | bool           | `true`               |
| `statusbar.template`               | string         | `"#[align=left]#{mode}#[align=right]#{date}"` |
| `flashlight.suggestion_count`      | int            | `10`                 |
| `flashlight.precedence_alive_bonus` | int            | `10`                 |
| `[flashlight.aliases]` entries     | string         | none                 |
| `[flashlight.precedence]` entries  | int            | source-kind override |
| `mode.labels`                      | inline string table | `{ normal = "NORMAL", insert = "INSERT", command = "COMMAND" }` |
| `mode.sequence_timeout_ms`         | int (ms)       | `1000`               |
| `[mode.all.mappings]` entries      | argv array mapping (`["flash", "<verb>"...]` or `[<argv>...]`) | none             |
| `mode.normal.leader`               | string         | `"\\"`             |
| `[mode.normal.mappings]` entries   | argv array mapping              | built-in normal map |
| `[mode.insert.mappings]` entries   | argv array mapping              | none             |
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

`open.ignored_apps` excludes app results from `:open` and
the `app_open name=...` verb. Entries match an app's display name, bundle
identifier, full bundle path, `.app` filename, or filename without `.app`,
case-insensitively.

Logs are newline-delimited JSON written to stderr and
`~/Library/Logs/Flash/flash.log`. Every log line has a `source` field:
`core:<file>.<function>` for Flash code, or `plugin:<id>` for plugin logs.
`debug.log_level = "trace"` includes AX tree dumps. Accepted levels are
`trace`, `debug`, `info`, `warn`, `error`, and `fatal`.

`plugins.third_party` accepts only `github:user/project@<commit-sha>` and `file:<path>`. The `@<commit-sha>` pin is mandatory for `github:` references — it must be a full 40-character lowercase hex commit SHA, and the loader rejects anything else (branch names, tags, short SHAs). Third-party `install` / `start` scripts run as the user with full host privileges, so trusting a moving upstream ref would let a compromised plugin author drop arbitrary code on every config reload; the materializer fetches *exactly* the pinned commit and refuses to start a plugin whose checked-out HEAD doesn't match. Plugin manifests may also declare a `capabilities` array listing the sensitive host surfaces they need (currently `"clipboard"` is the only gated capability); events such as `core:clipboard.changed` are filtered out for any plugin that hasn't opted in.
Official bundled plugins under `Contents/Resources/Plugins` are enabled unless
their id is listed in `plugins.disabled`; use `["defaults"]` for a raw host-only
experience without built-in plugin-layer defaults. In the checkout they live under root
`Plugins/` so `Scripts/install.sh --dev` can symlink them into the installed app. Every plugin root must contain
`manifest.json` with `id`, `name`, `version`, `description`, `install`, `start`,
optional `listen` event patterns, root selectors such as `only_bundle_ids` /
`only_urls`, and provider registrations. Command providers expose one or more
subcommands; status providers expose named segments through `segments`.
There is no `manifest_version` field on master. The host rejects unknown
top-level manifest keys instead of accepting legacy aliases. `install` and `start` are
shell strings run from the plugin root; Flash passes
`FLASH_PLUGIN_ID`, `FLASH_PLUGIN_VERSION`, and `FLASH_PLUGIN_DATA_DIR`.
Plugins speak length-prefixed MessagePack over stdin/stdout: a 4-byte
big-endian payload length followed by a MessagePack value. Host input goes to
stdin, successful or failed protocol results go to stdout, and unexpected
errors go to stderr. Plugins can log through the Flash logger by sending
`flash.log` protocol notifications.
Official plugin installers must keep downloaded CLI binaries under their own
`FLASH_PLUGIN_DATA_DIR`; do not write into global shell paths.

`[statusbar]` configures the persistent top status bar format. `template`
is one tmux-style string; `#[align=left]`, `#[align=centre]` / `#[align=center]`,
and `#[align=right]` route following text into the left, centre, and right
regions. Separators are literal inline text inside the template. Supported
template variables are `#{mode}`, `#{active_app_name}`,
`#{active_bundle_identifier}`, `#{date}`, `#{plugin:loaded_count}`,
`#{plugin:ready_count}`, `#{plugin:error_count}`,
tmux-compatible variables (`#H`, `#h`, `#S`, `#{host}`, `#{hostname}`,
`#{host_short}`, `#{user}`, `#{uid}`, `#{pid}`, and other tmux status variables
that render as empty when Flash has no equivalent), `#{plugin:<plugin>.<segment>}`,
`#{script:<path>}`, and `#{command:<shell command>}`. For example, the bundled
system plugin exposes the battery segment as `#{plugin:system.battery}`.
Template newlines are ignored before rendering. Mode, focused-app, plugin
status, and date changes re-render from their own change sources. Command/script
sections are stale-while-refresh and are polled only when present: the previous
successful value stays visible until a replacement is ready.

**Bundled plugins are Rust, macOS-only, and ship as compiled binaries.**
Every official plugin under `Plugins/<id>/` is a member of the
`Plugins/Cargo.toml` virtual workspace and depends on the local `flash_plugin`
SDK crate (`flash_plugin = { path = "../_rust_flash_plugin" }`), which owns
all the generic MessagePack scaffolding (framing,
`initialize`/`heartbeat`/`shutdown`, structured logging, a sandboxed `run_cli`,
background tasks/timers, and the tokio runtime) and carries **no Flash
business concepts**. Shared dep versions (serde, tokio, rmp-serde, objc2,
…) live in `[workspace.dependencies]` and each crate inherits them via
`{ workspace = true }`, so every plugin resolves the same transitive graph
through a single `Plugins/Cargo.lock`. Per-crate Cargo.tomls keep only their
own plugin-specific deps (`fasteval2` in calculator, etc.) and no
`[profile.release]` — the size-optimized release profile lives once at the
workspace root. A plugin's `main.rs` implements the `Plugin`
trait; everything domain-specific lives there, never in the template. The crate
hardcodes `edition = "2021"` and `license = "MIT"`. Plugins may assume macOS and
must **not** use `unsafe` Rust (objc2 0.6 exposes the AppKit/Foundation calls we
need safely). `Scripts/build-plugins.sh [dev|release]` compiles every
`Plugins/*/Cargo.toml` into a shared `CARGO_TARGET_DIR` (`build/plugin-target`,
kept out of the watched plugin trees) and copies each `flash-plugin-<id>` binary
next to its `manifest.json`. `dev` is an optimized current-arch release build
(fast, incremental); `release` is an optimized universal binary (x86_64 + arm64)
joined with `lipo`. Candidate providers declare manifest root `sources` descriptors, keep
candidate snapshots warm in memory, refresh from light host events such as
`core:apps.snapshot`, `core:focus.changed`, and `core:ax.changed` when possible,
and poll only when the underlying source cannot be watched. The command-bar
path reads `candidates(...)` snapshots synchronously; `candidateQuery` is not
used to populate a visible flashlight list and should stay O(memory) unless a
separate host workflow explicitly needs it. The manifest's `start` is
`exec ./flash-plugin-<id>` and `install` is a no-op `true` — there is no cargo,
Python, or interpreter at runtime. `Scripts/build.sh` / `Scripts/install.sh`
invoke `build-plugins.sh` with the matching mode; dev symlinks the repo
`Plugins/` into the app, while release stages only `manifest.json` + the binary
per plugin (no sources). The compiled binaries and per-crate build output are
git-ignored.

**Plugin snapshot freshness contract (binding for every candidate provider).**
A candidate plugin's job is to keep its in-memory snapshot **in sync with its
underlying data source at all times** — not "polled and hope for the best",
not "refreshed on the way out of `candidate_query`." The host freezes one
already-warm snapshot when the flashlight surface opens, and the user expects
that visible list to be available within a single frame and stay immutable until
the surface closes.

  1. **Visible candidate reads must be O(memory).** The flashlight open/search
     path calls `SourceRegistry.candidates(scope:)`, which reads each source's
     current `candidates(...)` snapshot synchronously. It must not call
     `queryCandidates`, wait for plugin RPC, run subprocesses, run AppleScript,
     or do any I/O whose latency the user would feel. The default plugin
     `candidate_query` trait method returns `CandidateQueryResponse::snapshot()`;
     keep that default unless a non-visible host workflow explicitly needs a
     dynamic query.

  2. **Push the work to the background.** Refresh on host events that
     correlate with state change (`core:focus.changed`,
     `core:apps.launched`, `core:apps.terminated`, `core:flash.started`)
     and — when the underlying source has no push channel — run a
     `ctx.interval(...)` poll. The cadence has to be short enough that
     a change the user just made (a new tmux window, a renamed Slack
     channel) is in the snapshot by the time they next press `f`. 1 s
     is the working default for poll-only plugins; raise it only with a
     measurement that justifies the user-visible staleness.

  3. **Dedup before emitting.** Hash the candidate vector (title +
     subtitle + navigation_url + pid is usually sufficient) and skip
     `emit_snapshot` when nothing observable changed. Late snapshot updates do
     not mutate the currently visible flashlight list, but they do warm the
     next session and can still trigger host bookkeeping. The dedup gate makes
     "snapshot identical to last emit" a true no-op all the way down to the
     host.

  4. **Parallelise per-target I/O.** When the snapshot is sourced from
     N independent backends (tmux sockets, browser bundles, Slack
     workspaces, …), spawn the per-backend work concurrently
     (`tokio::spawn` + `JoinHandle::await`). Sequential fan-out makes
     the slowest backend dominate every refresh; with three sockets and
     a 2 s per-call timeout, a single hung server stretches a 50 ms
     operation into 6 s of background churn that can overlap the next
     poll.

  5. **Never nuke the cache on transient failure.** When `build_…`
     returns `None`, leave the previous snapshot in place and skip the
     emit. Emitting `[]` makes tmux windows / browser tabs visibly
     disappear from flashlight every time a single backend hiccups; the
     next successful poll repopulates them seconds later. The
     "stale-but-mostly-right" cache is strictly better than the "empty
     during failure" cache.

Tests should pin these invariants in place — see
`Plugins/tmux/src/main.rs` for the canonical pattern (`hash_candidates`,
`refresh_candidate_snapshot_for_path` with `last_snapshot_hash` dedup,
`run_tmux_aggregate` parallel fan-out, and the
`tmux_plugin_uses_default_candidate_query` regression guard).

Setting `debug.http_inspector_enabled = true` starts a loopback-only single-page
debug server with live logs, resolved config, focused app state, and plugin
state, bound to `debug.http_inspector_host` (`localhost` / `127.0.0.1` / `::1`)
and `debug.http_inspector_port`. Keep it dense and diagnostic-focused; do not
turn it into a preference UI.

Performance behaviours are **not configurable.** The prepared AX model,
the concurrent subtree walk, and the parallel deferred action-name
IPC pass are always on. Per-IPC AX messaging timeout is never set
(see *Prepared model contract* below).

There is intentionally **no** `per_app.*` table. The project's working assumption is to converge on universal rules before re-introducing per-bundle knobs — `Config.perAppRoles` and its TOML parser case were removed for this reason.

### Mode Mappings

`[mode] labels = { normal = "...", insert = "...", command = "..." }` controls the left-side status-bar text. `[mode.all.mappings]`, `[mode.normal.mappings]`, and `[mode.insert.mappings]` map `"key" = ["flash", "<verb>", "--key=value"]` (in-process verb) or `"key" = ["<executable>", "<arg>", …]` (argv exec). `[mode.normal] leader = "\\"` configures a normal-mode sequence prefix that can be referenced in `[mode.normal.mappings]` as `<leader>`.

- `[mode.all.mappings]` applies in insert and normal modes.
- `[mode.normal.mappings]` applies only while the overlay is capturing normal-mode input.
- `[mode.insert.mappings]` applies only in insert mode.

Values must be non-empty string arrays. Bare strings, URLs, and any other shape are deliberately unsupported. Arrays whose head is `"flash"` are interpreted as in-process verb dispatches and resolve through `URLEventHandler.parse(verb:args:)`; any other head is executed directly as argv (no shell wrap) with leading `~` expanded in each element. Relative path arguments containing `/` are resolved from the config file location at load time, so `["../../scripts/toggle"]` works for dotfiles-managed configs.

Native modified-key mappings are registered through Carbon when the key contains `"+"`; unmodified normal-mode mappings are read only while the overlay panel owns keyboard input. `[mode.normal.mappings]` entries extend the built-in normal map and override only matching keys, so unrelated defaults stay available unless that exact key is remapped.

When any `[mode.all.mappings]` mapping resolves to `["flash", "enter_normal_mode"]`, Flash enters advanced mode:

- starts in normal mode by default;
- always displays the status bar using configured `mode.labels`, including in the help view;
- extends the `help_show` modal with ACTION / NORMAL / INSERT columns.

The status bar is rendered from `FlashStatusBarTemplate`: one template string can read Flash SDK state (`mode`, `active_app_name`, `active_bundle_identifier`, `date`), tmux-compatible variables, plugin state (`PluginStatusSnapshot` counts and `status.updated` segment values), or command/script output. The default template shows the mode cell on the left and the date on the right. Command-backed sections are stale-while-refresh: keep the previous successful value until a replacement is available, and do not blank a section during refresh. The controller is source-driven where possible: mode, focused-app, plugin, and clock changes publish directly; command/script sections get their own poll only when the template contains them. The top bar content is inset from the screen edges for rounded display corners. When the Flash status bar is enabled, Flash keeps the macOS top-band reservation in place, uses each screen's native reserved top-band height, falls back to the measured native menu-bar reveal height when macOS reports no top-band reservation, stays below the native menu/status bar reveal, and the `window_move` verb computes slots/remaps inside that reserved usable frame. Reading `NSStatusBar.system.thickness` and temporarily measuring `NSMenu.menuBarHeight` are allowed only for this geometry fallback; do not create persistent `NSStatusItem`, menu extras, app menus, or any native menu/status UI.

`["flash", "enter_normal_mode"]` is the only accepted normal-mode entry. `[mode.normal.mappings]` and `[mode.insert.mappings]` mappings to it do not enable advanced mode by themselves. When no `[mode.all.mappings]` advanced-mode mapping is configured, the status bar is hidden and help stays simple while still listing the normal map.

### Verbs

Every action Flash takes must have a corresponding entry in `URLEventHandler.commands`. Keep `URLCommand`, parser wiring, `URLCommand.diagnosticDescription`, mapping help, README, default config examples, and tests in sync.

Normal-mode verbs currently include: `mouse_target [secondary=1|double=1|move=1]`, `mouse_grid [secondary=1|double=1|move=1]`, `enter_command_mode [input=<text> restore_mode=1]`, `scroll_left`, `scroll_down`, `scroll_up`, `scroll_right`, `scroll_half_page_down`, `scroll_half_page_up`, `scroll_top`, `scroll_bottom`, `app_reload [force=1]`, `app_undo`, `app_redo`, `window_close`, `app_find`, `app_open_finder [all=1]`, `url_copy`, `tab_next`, `tab_previous`, `tab_first`, `tab_last`, `tab_select index=<n>`, `tab_close`, `history_back`, `history_forward`, `movement_back`, `movement_forward`, `app_quit [force=1]`, `app_save`, `app_save_and_quit [force=1]`, `app_print`, `document_open`, `window_new`, `tab_new`, `clipboard_copy`, `clipboard_cut`, `clipboard_paste`, `clipboard_copy_all`, `plugins`, and `plugin_command command=<command> subcommand=<subcommand>`.

`:open <query>` and `:flashlight <query>` results render below the centered command line, ordered top-to-bottom with the best match closest to the prompt. App bundles are warmed and cached by `ApplicationSource`. Result titles include the source prefix, e.g. `[tmux] scratch gors`, `[firefox] Gmail (https://mail.google.com)`, `[slack] #general`. Plugin candidates should provide their own `source` / `title` labels.

**Flashlight loading sequence.** On panel open the host freezes exactly one synchronous candidate snapshot through `SourceRegistry.candidates(scope:)`. That snapshot includes apps from the warm `ApplicationSource` cache and plugin/browser/tmux rows from each source's in-memory `candidates(...)` snapshot. The visible candidate pool is immutable for the lifetime of the command-line / candidate-finder surface: typing, selection movement, plugin `snapshot.updated` notifications, `core:flashlight.opened` responses, app-cache prewarm completions, and background timers must not add, remove, reorder, or re-score against newly arrived rows. Do not call `queryCandidates` from the flashlight open/search/render path, do not reintroduce a pending dynamic buffer, and do not run a live refresh while the surface is open. Plugins are responsible for keeping their snapshots warm before the panel opens; updates that arrive after the snapshot can affect the next session only. This immutability is a UX contract, not an optimization detail.

**Candidate schema.** Every candidate is `{ title: String, url: URL?, metadata: [String: String] }`. `title` is the primary searchable string and the highest-precedence ranking field. `url` is the typed openable destination — apps point to their `.app` bundle file URL; browser tabs point to the page URL; sources without an openable destination omit it. `metadata` is fully opaque to FlashCore; sources stash whatever they want there, other plugins may read each other's keys by convention, and the matcher indexes the values at a low tier for fuzzy search. The bundled host uses these conventional keys for routing (defined in `Sources/flash/App/CandidateMetadata.swift` and mirrored as `candidate_metadata::*` constants in `Plugins/_rust_flash_plugin/src/lib.rs`): `source`, `source_id`, `kind`, `entity`, `pid`, `navigation_url`, `bundle_id`, `subtitle`, `payload`, `aliases`, `finishes_command`, `current_location`, `priority`. `priority` must be one shared enum value (`low`, `normal`, `high`, `important`, `urgent`), not a source-local number. The wire format between plugin and host carries `{ title, url, metadata }`.

**Flashlight source ordering.** `CandidateFinder.sortedMatches` ranks results in two bands. Registered `!<bang>` candidates form a strict top band — a typed bang always wins, because a bang signals explicit dispatch intent. All other candidates are ordered by match quality (the field-aware exact/prefix/word-prefix/substring/fuzzy ladder in `fieldScoreNormalized`); source tier is only consulted as a tiebreaker when scores match. Defaults come from native source descriptors and plugin manifest `sources[].kind` values (`locations` vs. `default`) plus the shared source `priority` enum, with `precedence_alive_bonus` nudging pid-backed candidates above inactive rows from the same source. Candidate row `priority` is an additional same-score tiebreaker below source weight. `[flashlight.precedence]` is an override layer for specific source labels or parent prefixes. The earlier strict-tier sort hid strong prefix matches on app names under weak fuzzy hits on browser tabs (`:flashlight safari` would surface random Firefox pages but not Safari.app) — match quality must lead.

**Flashlight bangs.** Registered plugin bangs are exclusively in scope when the user types `!`. With no `!` typed the candidate pool excludes bang candidates entirely; the moment the query starts with `!`, the pool is replaced with the bang registry alone (no app/tab/tmux noise), fuzzy-matched against the token text after `!`. Submitting a bang routes the remainder through `PluginManager.invokeShebang`; the catch-all `"*"` registration is reached through the same path when no exact token matches what the user typed. A bang manifest entry can declare a `candidate_source` — once the user confirms `!<token> ` (trailing space), the flashlight pool swaps to that source's live candidates so the user picks the target directly (e.g. `!kill ` → processes plugin's process list; selection routes through that source's `resolve_candidate`).

**Flashlight key bindings (unified contract).** App, browser-tab, and tmux-window rows are final destinations: selecting them with `<tab>` or `<cr>` submits the row, equivalent to `<cmd+cr>`. Synthetic source-filter rows insert `@<source> ` and are never finishers, including on `<cmd+cr>`. Bang rows insert `!<token> `, and non-final real source-owned rows insert `@<source> <name> `. `<cr>` otherwise uses the insert-first path unless the selected candidate is a source-owned finisher (`Candidate.finishesCommand`), an exact primary-title match, or a text-insertion candidate such as an emoji. `<cmd+cr>` is the explicit force-submit/open chord for real candidates. Cycling moves to arrow keys and `<shift-tab>`. Command-line *completions* (`:help <topic>`, `:plugins <sub>`, `:<plugin> <action>`) keep their separate contract: `<tab>` inserts the value without sending, while `<cr>` inserts and then submits only for terminal/plugin-subcommand completions; `acceptsArgs` completions leave the line open.

**Flashlight source narrowing.** `:flashlight @<source> <query>` restricts the pool to one source — `@<source>` is the only structured filter, no `@<field>:<pattern>` form. `NormalModeDispatcher.candidateFinderSourceFilter` parses the first `@<token>` in the query; `CandidateFinder.candidateMatchesSourceFilter` matches it against `candidate.source` by exact name or prefix on dotted labels (`@firefox` matches `firefox.tabs`). A confirmed `@<source> ` with no residual text lists every candidate from that source — `:flashlight @emojis.glyphs ` enumerates the whole emoji set, otherwise excluded from the default pool. The flag is ignored in `:emojis` mode.

App/system verbs include: `enter_normal_mode`, `enter_insert_mode`, `enter_command_mode`, `alert_show message=... [duration=seconds style=standard|error]`, `alert_dismiss`, `hints_dismiss`, `app_open name=...`, `window_move ...`, `help_show`, `plugins`, and `quit`. Plugin actions also become command-line commands through their registered `command` field, e.g. `:spotify pause`.

**Plugin commands can raise a window.** A plugin's `command.invoke` result may include `{ "ok": true, "target_pid": <pid> }`. When present, Flash activates that app (raising its window) after the command succeeds and records the jump into the movement history, so `ctrl-o` / `ctrl-i` replay it like any other navigation. This is how the tmux plugin's jump commands work: `:tmux session <name>` and `:tmux window <session:index>` run `switch-client` against the most-recently-active client and return the terminal pid hosting the target session. Bind them to a key with `["flash", "plugin_command", "--command=tmux", "--subcommand=window", "--args=main:1"]` (the `args` value is split on spaces). `target_pid` is optional — commands that don't move focus omit it.

**Command-line candidate contract.** Command and sub-command suggestions (`:help <topic>`, `:plugins <sub>`, `:<plugin> <subcommand>`, the top-level `:<tab>` list) are modelled by `CommandLineCompletion`. Every candidate has a **value** (`insertion`) and a **label** (`label`). The label is purely cosmetic — it is what shows in the suggestion list and never affects behaviour; when omitted, set it equal to the value so the value shows through. Selection semantics are uniform across built-in and plugin candidates: `<tab>` inserts the selected candidate's value into the buffer **without** sending the command (keep typing args), and `<CR>` inserts the value, then submits for terminal/plugin-subcommand completions or leaves the line open for `acceptsArgs`. Arrow keys (and `<shift-tab>`) cycle the selection. The candidate finder (`:open` / `:flashlight` / `:emojis`) is a separate live-results mechanism with canonical command insertions; app, browser-tab, and tmux-window rows are final destinations and submit on `<tab>`/`<CR>`, `<CR>` may also open when the row is a finisher or exact enough, `<cmd+cr>` force-opens real candidates, and synthetic `[source] @...` rows only insert their source token.

### Unified Action Contracts

Three normal-mode keys carry a single semantic meaning regardless of focused-app context. Plugins/sources own the context-specific dispatch; the host owns the uniform fallback. Adding a new source means deciding which of these you implement and which you let fall through.

**`f` — the `mouse_target` verb (click a hinted target).** A single highest-priority hint provider wins per focused app via `SourceRegistry.chain(for:).first`: built-in `AccessibilityProvider` (priority 10) is the universal default; a plugin opts in via a `hints` provider at higher priority (e.g., `Plugins/tmux` at 20). There is no additive merge. Individual hint targets may still carry the shared `priority` enum; `.important` and `.urgent` use the accent hint style without changing commit behavior. Targets travel through `ActionDispatcher.perform` with one uniform pipeline: any non-empty `ClickModifiers` (cmd/ctrl/alt/shift, gated by `hints.magic_modifiers`) bypasses the per-target `activate` closure and posts a real `CGEvent` mouse-down/up with the flags set — that is how a plugin's semantic activation (e.g. tmux's `select-pane`) is overridden by `shift+f` to deliver a raw click to the underlying app. Insert-mode entry after commit is driven solely by `JumpTarget.entersInsertMode`, which providers set per target.

**`t` — the `tab_new` verb (open a new tab/window in this context).** Routed through `SourceRegistry.tabNew` against every source advertising `.tabCreation`, in priority order. The first source whose disposition is not `.unhandled` wins; on `.failed` the host stops the chain (no keystroke fallback — see *Source action dispositions* below). On `.unhandled` from every source the host synthesizes a context-aware keystroke fallback via `AppDelegate.tabNewFallbackKey`: ⌘N for window-only terminal bundles (Alacritty), ⌘T elsewhere.

**`x` — the `window_close` verb (close current tab/window in this context).** Routed through `SourceRegistry.tabClose` against every source advertising `.tabClosing`. On `.unhandled` the fallback is ⌘W. Closing the last tab in a browser via the plugin's AppleScript path collapses to closing the window, matching the native ⌘W feel. The `tabClose` variant exists for the `tab_close` verb and uses the same dispatch.

**Source action dispositions.** `SourceActionResult.Disposition` is `.performed | .failed | .unhandled`. Use `.unhandled` only when the source doesn't apply to this context (wrong bundle, missing client, etc.); use `.failed` when the source owns this context but the underlying command failed or timed out — the host must NOT keystroke-fall-back after `.failed`, or a synthesized key can double-fire on top of a real (but late) effect. The Rust SDK exposes the same trichotomy as `SourceActionResponse::performed(pid)` / `failed(pid)` / `unhandled()`.

### Normal-Mode Audit Rule

Flash must never leave normal mode because focus changed on its own. Leaving normal mode must follow an auditable user-intent path, logged with a reason where practical. The **complete** set of valid insert transitions is:

- A normal-mode `i` keypress (or its verb twin `enter_insert_mode` invoked by the user).
- A user-driven normal-mode command that intentionally opens a typing surface, currently `/` (`app_find`) and `t` (`tab_new`).
- A physical pointer click while idle normal mode is capturing input; Flash enters insert mode and replays the click so it reaches the underlying app.
- A committed `f` (mouse_target) click on a target whose owning provider set `JumpTarget.entersInsertMode = true`. Only true text-input surfaces qualify: `AccessibilityProvider` sets it on `AXTextField` / `AXSearchField` / `AXTextArea` / `AXComboBox`. Terminal-like targets (e.g. tmux panes) are NOT inputs in this sense and stay normal; the user types `i` after focusing one if they want to type.
- A committed `F` (mouse_grid) click — **only** when a post-click AX query (`AppMonitor.focusedElementIsEditable`) reports the focused element under that click is a text-input role. Geometric clicks have no AX target up front, so the role check after the click is the only honest signal that the user landed on something typable. `mF` (cursor move) never enters insert.

Nothing else may auto-enter insert. Specifically: focused-element changes, app activation, and unrelated configured key sequences must leave the mode alone. Do not reintroduce passive focused-element observers that switch to insert merely because macOS reports an editable focus. While advanced normal mode is active, Flash must aggressively recapture the overlay after app activation, app launch, Space changes, and panel key-focus loss; this intentionally prioritizes keeping normal-mode keyboard capture over preserving native menus or popovers.

Insert mode is allowed to leave automatically when input focus is lost. Track the pid that owned INSERT entry; if the focused app changes away from that pid, transition back to normal mode even if generic editable focus-loss exit was never armed. For focus changes inside the same app, require arming first: on INSERT entry, run a short delayed `AppMonitor.focusedElementIsEditable` probe for the active app; if it is false, leave generic focus-loss exit unarmed so non-input contexts can stay in INSERT pass-through. Once armed, a focused-element or focused-window change for the active app should query `AppMonitor.focusedElementIsEditable`, and if it is false, transition back to normal mode. If a mouse button is currently pressed, defer that transition until release and re-check editability; otherwise click-drag text selection gets interrupted by the normal-mode overlay recapturing mid-drag. Do not run that exit probe for `kAXValueChangedNotification`, or typing in an editable element will pay an AX query per keystroke.

Browser `t` (`tab_new`) is a special insert exit: after opening a browser tab, Flash may poll the focused document URL on the AX queue and return to normal once it changes from the pre-tab baseline/internal new-tab URL to a committed `http` / `https` URL. This covers address-bar Return, where browsers often keep the location field as the focused editable AX element after navigation, so generic focus-loss detection never fires.

One structural exception: when a config reload removes the last `["flash", "enter_normal_mode"]` binding (advanced mode no longer wired), Flash forces `.insert` because there is no normal mode without that binding. Reason `.advancedModeDisabled`, `force: true`.

`hints.keys` accepts either a literal alphabet (`"asdfghjkl"`, ASCII letters only, deduped) or a layout selector token. Selector syntax is `<$layout[_$row][_$hand]+...>` where layout is `qwerty` / `colemak` / `dvorak`, row is `homerow` / `toprow` / `bottomrow`, and hand is `lefthand` / `righthand`. Examples: `<colemak>`, `<colemak_homerow+colemak_toprow>`, `<colemak_homerow_lefthand+colemak_toprow_righthand>`, `<colemak_lefthand>`. Selectors cannot mix layouts. Layout selectors are scored by the inferred layout's key scores; literal strings are scored by their written order. There is no `hints.layout` key. Resolution lives in `Alphabet.resolve(_:)`.

**Flash always walks the focused app only.** There is no `hints.scope` knob and no multi-app walk machinery — background apps and other monitors are ignored. `JumpTarget.pid` carries the focused app's pid so `commit` can re-activate it before dispatching the click. There is **no per-walk deadline** — walks always run to their `maxDepth`/`maxTargets` caps.

## Permissions

Required:

- **Accessibility** — required for AX walks and `AXUIElementPerformAction`. Granted in *System Settings → Privacy & Security → Accessibility*. The bundle identifier is `com.flash.app`; the path must be `/Applications/Flash.app`.

Declared / conditional:

- **Automation (`NSAppleEventsUsageDescription`)** — declared for the `app_open` verb's Launch Services calls (launch/reopen/focus another app) and so the `flash` CLI can AppleEvent into the resident. Flash still discovers browser page content through `AXWebArea` descendants in the AX tree, not via `do JavaScript`.

Not required:

- **Input Monitoring** — **NOT** required and **NOT** requested. If you find yourself wanting to request it, you're violating rule (2) above.
- **Screen Recording** — **NOT** required and **NOT** requested. See rule (7) above. The plist no longer declares `NSScreenCaptureUsageDescription`.

### TCC and rebuilds

`./Scripts/install.sh --dev` signs with the stable self-signed "Flash Dev" identity and installs a user LaunchAgent at `~/Library/LaunchAgents/com.flash.app.autolaunch.plist` so Flash starts at login. The first run with that identity resets Accessibility once so the next grant binds to the stable certificate; subsequent rebuilds should preserve the grant.

## Build / install / verify

**Every app-code change requires reinstalling** to see it in action. Flash is a resident background process launched out of `/Applications/Flash.app`; there is no app-code live-reload, dev server, or attached debugger flow. Plugin files can live-reload through `PluginManager` when bundled plugins are symlinked by `Scripts/install.sh --dev`. `swift build` produces a binary in `.build/` that the resident process is *not* using — only the copy under `/Applications/Flash.app/Contents/MacOS/flash` matters. So the developer loop is:

```bash
# Make code change → run install (NOT just `swift build`)
./Scripts/install.sh --dev

# Trigger and verify
flash mouse_target
```

`./Scripts/install.sh --dev` is what builds optimized current-arch products, codesigns, quits the running instance, replaces the bundle, symlinks bundled plugins for live reload, and relaunches. After any code edit (Swift, Info.plist, config defaults, scripts), re-run it. `swift build` / `swift test` are useful only for type-check and unit tests — they do **not** update the binary the system actually runs. `./Scripts/build.sh --dev` does the same build without installing; `--release` produces an optimized universal (Intel + Apple Silicon) `.app` + zip.

```bash
# Build only (debug; type-check + unit tests, NOT for behaviour verification)
swift build

# Tests
swift test

# Build optimized current-arch, install to /Applications/Flash.app, relaunch — required after every app-code change
./Scripts/install.sh --dev
```

`--dev` is the fast inner loop: an incremental optimized current-arch release build (Swift + every plugin), then reinstall + restart. Because dev installs symlink `Contents/Resources/Plugins` to the live `Plugins/` tree and `PluginProcess` watches each plugin directory, rebuilding a plugin binary (the `mv -f` swap in `build-plugins.sh` lands as a `rename`) triggers `scheduleFileReload()` and restarts only that plugin — the resident Flash process and every other plugin keep running. If the watcher doesn't pick up a new plugin binary (e.g. `[plugins] watching_enabled = false`), run `:plugins reload` in Flash's command-line cell. Any change to Swift code, `Resources/Info.plist`, `config.default.toml`, or the bundle / signing flow requires a full `./Scripts/install.sh --dev`.

`install.sh --dev`:

1. `swift build -c release --product flash` — the single Mach-O is both resident and CLI
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

## Testing UI behavior

Tests in `Tests/FlashTests/` are stratified by what they exercise:

- **Pure-unit** (`AlphabetTests`, `ConfigLoaderTests`, `HintAssignerTests`, `SourceCandidateTests`, …). Deterministic, run in milliseconds, no external state. Run on every `swift test`.
- **tmux logic** (link extraction, cell geometry, status-bar parsing, client/process-tree resolution) lives in the Rust `Plugins/tmux` crate — cover changes there with crate tests, not Swift tests.
- **Browser integration** (`Scripts/test-integration-browser.sh`). Provisions a Firefox profile template with a pinned reference extension, builds/codesigns the browser oracle runner, then runs the 100-file offline corpus from `Tests/BrowserSnapshots` through a parallel worker pool. Each worker gets its own Firefox profile and Marionette port. Per fixture, Marionette injects fiducials and captures reference marker DOM via WebDriver script execution; Flash walks Firefox's AX tree; the two sets are diffed under strict-ISO. Catches both undermatch and overmatch against the browser reference. Run order: build + sign once (`./Scripts/install.sh --dev` to create the `Flash Dev` identity), then `./Scripts/test-integration-browser.sh`. The script kills its oracle app and Firefox worker-profile processes on exit/interruption.
- **Native AppKit integration** (`Scripts/test-integration-native.sh`). Builds/codesigns `flash-native-fixture` and `flash-native-oracle`, launches a deterministic AppKit window, compares generic AX targets against expected controls, verifies AXPress mutates a fixture state file, and records the open-NSMenu limitation under the no-key-capture production rule. It covers buttons, image-backed buttons, duplicate labels, checkboxes, radio buttons, popups, search/text areas, tabs, rows, and negative controls such as disabled/hidden/decorative/slider elements. It does not add production global key capture or private APIs, and the script kills its test apps on exit/interruption.
- **Electron integration** (`Scripts/test-integration-electron.sh`). Runs `npm ci` for the pinned Electron fixture, builds/codesigns `flash-electron-oracle`, launches Electron with a deterministic DOM fixture, reads expected target JSON emitted by the fixture, compares it against Flash's generic AX provider output, and verifies AX activation mutates fixture state. The script kills its oracle app and fixture Electron process on exit/interruption.

Run order:

```bash
swift test                                           # unit
./Scripts/install.sh --dev                           # one-time: creates the Flash Dev signing identity
./Scripts/test-integration-browser.sh                # builds + signs + runs the browser corpus
./Scripts/test-integration-native.sh                 # builds + signs + runs native AppKit fixture
./Scripts/test-integration-electron.sh               # installs pinned Electron fixture and runs oracle
```

Anything that requires the full overlay / commit pipeline (chip rendering, key handling, AXPress against a live focused app) is still **manually verified**: run `./Scripts/install.sh --dev`, grant permissions if needed, then exercise the app in real target apps.

Do not claim UI-level changes "work" based on the type-checker alone. State explicitly when you couldn't verify visually.

## Known limitations

### Open menus dismiss when Flash activates

When any non-menu window becomes the system's key window, AppKit's menu
tracking session cancels and the menu closes. Flash's overlay panel becomes
key in order to receive the user's hint keystrokes via `NSPanel.keyDown`,
which trips this dismissal — so triggering Flash on top of an open
`NSMenu` / `NSPopover` / popup-button menu collapses it.

There are two ways around this and both are off the table:
1. **Global event tap (`CGEventTap` / `addGlobalMonitorForEvents`)** would
   let us read keystrokes without taking key window, so the menu would
   stay open. Banned by hard rule (2): no arbitrary global key capture.
2. **Render through a CGS / WindowServer-level window** below the menu
   plane. This uses private SkyLight APIs that aren't part of the public
   AppKit surface. Out of scope.

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

Workaround for users: dismiss the menu, trigger Flash on the menu's parent
button (which is hinted), commit, then read the menu.

## Common pitfalls

- **AX `AXUIElementPerformAction` requires Accessibility permission.** Without it, the call returns `.notImplemented` or `.cannotComplete` silently; the user sees nothing happen. `--doctor`-equivalent diagnostics live in `Permissions/PermissionCheck.swift` (currently only AX check; extend if adding more required perms).
- **`AXObserver` callbacks run on the main run loop.** Don't do AX work inside them — schedule onto `refreshQueue`.
- **`NSPanel(.nonactivatingPanel)` can become key without activating the app.** That is intentional: the overlay needs to receive keys, but stealing focus from the target app would break `AXPressAction` (the action must run *against* the original app, which is why we call `app.activate()` in `commit` before dispatching).
- **`CGEventSource` `.combinedSessionState`** is the right choice for synthesizing input; it sees the current modifier state, so e.g. shift held during commit doesn't poison the click.

## When in doubt

Add a one-line `print` (it goes to stderr → log file in production via the launched bundle) before guessing. Real AX traces win arguments fast.
  flash-native-fixture/              # AppKit fixture app for native integration tests.
  flash-native-oracle/               # Signed CLI oracle that drives the native fixture through AX.
  flash-electron-oracle/             # Signed CLI oracle for the pinned Electron fixture.
