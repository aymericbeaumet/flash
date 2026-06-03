# AGENTS.md — guide for AI agents working on Flash

This document orients an agent (Claude, etc.) editing the Flash codebase. Read this before touching anything beyond a trivial change.

## What Flash is

A headless, resident macOS app that, when triggered by `open -g flash://show_hints`, overlays vimium-style hint labels on the focused app's clickable elements and clicks one when the user types its hint. No menu bar, no Dock icon, no global keyboard hooks, no CLI client, no autostart.

Activation is exclusively via the `flash://` URL scheme — bound to a hotkey by the user's choice of external tool (Karabiner, skhd, Hammerspoon).

## Hard rules (do not violate)

1. **No UI surface** beyond the transparent hint overlay. No menu bar item, no `NSStatusItem`, no `NSDockTile`, no `NSAlert`, no preferences window. Logging is stderr / `~/Library/Logs/Flash/`.
2. **No global keyboard logic.** No `RegisterEventHotKey`, no `CGEventTap`, no `NSEvent.addGlobalMonitorForEvents`. The only keyboard handling allowed is `NSPanel.keyDown` on the overlay panel itself, which receives keys only while the overlay is the key window.
3. **No autostart.** No launchd agents, no login items, no writes to `~/Library/LaunchAgents`.
4. **No second process / no IPC protocol.** Activation is always `NSAppleEventManager` receiving the URL scheme. Don't add Unix sockets, mach services, or a CLI client.
5. **Single resident process.** Code assumes one `NSApplication` instance; bundle identifier `com.flash.app`.
6. **TOML parser is hand-rolled** (small subset). Don't add `TOMLKit` / `Toml` / other deps unless we outgrow what we can hand-roll cleanly.
7. **No OCR / no Screen Recording.** Don't reintroduce `VisionProvider`, `ScreenCaptureKit`, `CGWindowList*`, or anything that touches the screen recording permission. The user explicitly removed it; if a request requires capturing pixels, surface it instead of silently adding it back.
8. **Silent on no-targets.** If the discovery pipeline returns no `JumpTarget`s, `activate(rightClick:)` returns without rendering anything. No "no targets" banner, no error chip. The only banners the user should ever see are the Accessibility-permission walkthrough.

If a request would violate any of the above, surface it to the user instead of silently complying.

## Project layout

```
Package.swift                        # SwiftPM, macOS 14+, swift 5 mode
config.default.toml                  # Canonical default config (MUST mirror Config.swift defaults)
Sources/
  FlashCore/                         # Public SPI (provider protocol + value types)
    AppContext.swift                 # Front-app context: bundle, pid, window frame
    JumpTarget.swift                 # A clickable thing with a screen rect + optional activate closure
    JumpAction.swift                 # .leftClick | .rightClick
    JumpProvider.swift               # The protocol; `supports/discover` API
  FlashProviders/                    # Built-in providers (depend on FlashCore + AppKit)
    Accessibility/AccessibilityProvider.swift   # Generic AX walk. Open class.
    Browser/BrowserScriptProvider.swift         # Vimium-style DOM bridge + Safari/Chrome subclasses
  flash/                             # The executable target
    main.swift                       # NSApplication boot
    App/
      AppDelegate.swift              # Orchestrator + OverlayCoordinator
      URLEventHandler.swift          # Registers GetURL handler; the ONLY hot-path entry point
      AppMonitor.swift               # Focused-app prepared model + AX walk dispatcher (serial AX queue)
      OverlayPanel.swift             # Reusable transparent NSPanel, CALayer pool, animations disabled
      OverlayInput.swift             # NSPanel.keyDown — the ONLY keyboard code in the project
      HintAssigner.swift             # Vimium prefix-free label generator + memoised candidate cache
      ActionDispatcher.swift         # AXPress preferred; CGEvent click fallback
      ProviderRegistry.swift         # Built-in provider list; chain resolution by priority
    Config/
      Config.swift                   # Decoded model — defaults here MUST match config.default.toml
      ConfigLoader.swift             # Hand-rolled TOML subset parser + DispatchSource fs-watch hot-reload
      Alphabet.swift                 # <colemak>/<qwerty>/<dvorak>/literal resolution
    Permissions/PermissionCheck.swift  # AXIsProcessTrusted() — read-only, no UI prompt
Tests/FlashTests/                    # XCTest: Alphabet, ConfigLoader, HintAssigner, TmuxProvider, plus live integration suites (TmuxIntegrationTests against an isolated tmux server; FirefoxIntegrationTests, opt-in via FLASH_FIREFOX_E2E=1)
Resources/Info.plist                 # LSUIElement, flash:// URL scheme, usage descriptions
Scripts/install.sh                   # Release build → staging .app → /Applications/Flash.app, ad-hoc codesigned
README.md                            # User-facing
AGENTS.md                            # This file
```

## Activation flow (read this before editing the hot path)

1. External tool runs `open -g flash://show_hints[?right=1]`.
2. macOS Launch Services routes to the running instance via `kAEGetURL` Apple Event.
3. `URLEventHandler` parses the URL host/query and invokes the AppDelegate handler.
4. `AppDelegate.activate(rightClick:)` captures `NSWorkspace.shared.frontmostApplication`'s pid via `AppMonitor.currentContext()`, then takes an activation generation token.
5. `AppMonitor.discoverAsync` first tries the AX-event-driven prepared model (see *Prepared model contract* below). On hit, native AX-backed `[AssignedHint]` values are delivered to main without an activation-time AX walk. Safari/Chrome still run the DOM bridge on activation and merge it with the prepared AX chrome model; tmux remains activation-only because its output is volatile.
6. On the AX queue, `AppMonitor` runs the selected provider chain in descending priority against the focused app only, filters candidates by the focused pid's WindowServer-derived visible region (occluded pixels excluded), then dedupes overlapping rects via spatial-hash with a **smaller-frame-wins** policy (`> 70%` overlap → smaller rect survives). Inside `AccessibilityProvider`, the focused window's direct children are fanned out across concurrent walkers, and action-name IPCs for tentative web-area / AXImage targets are resolved in a parallel post-pass.
7. `HintAssigner.assign` produces prefix-free labels using the configured alphabet — pre-uppercased as `AssignedHint.display`, memoised by `(alphabet, leftHand, length)`.
8. Bounces back to main; if the activation generation still matches (no cancel / app switch / commit in flight), `OverlayPanel.display(hints:)` wraps all layer mutations in `CATransaction.setDisableActions(true)` → no implicit animation; chips appear in place.
9. Panel becomes key (without activating Flash as app, because it's a `.nonactivatingPanel`).
10. `OverlayPanel.keyDown(with:)` matches typed prefix against assigned labels; on a unique match, `AppDelegate.commit` reactivates the focused pid (via `hint.target.pid`) and runs `ActionDispatcher.perform` after a 20 ms delay. The activation gate stays closed across that delay so a rapid second ctrl+space can't race.
11. `ActionDispatcher` prefers `AXUIElementPerformAction(_, kAXPressAction)` (or `kAXShowMenuAction` for right-click) for AX targets — no cursor movement, more reliable. For browser DOM targets it dispatches `.click()` / focus+select / synthetic `contextmenu` in-page via AppleScript `do JavaScript`. Falls back to synthesized `CGEvent` click that restores cursor position after.
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
- **Provider ordering is by priority desc.** Within a provider, traversal order is deterministic (AX child order for `AccessibilityProvider`, DOM order for `BrowserScriptProvider`). Concurrent walking fans out subtree workers but the dedup + sort passes after merging are deterministic, so the final hint order is independent of worker scheduling.

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
3. Walk runs to completion (never truncated). For Safari/Chrome, the continuous AX model deliberately skips `AXWebArea` descendants because the DOM bridge runs on activation.
4. Result hops back to main. If token and config revision still match AND pid is still frontmost → write a `PreparedModel` with targets, assigned hints, token, config revision, and timestamp. Else discard.
5. A maintenance refresh is scheduled before the freshness ceiling so a quiet focused app stays warm.

**Activation lookup** (`lookupPreparedModel`):

- Model hit iff `model.dirtyToken == dirtyTokens[pid]` AND `model.configRevision == configRevision` AND `now - model.computedAt < modelFreshnessMs`.
- On miss for pure continuous providers, activation waits for a model build and stores it if still valid.
- On miss for activation-only providers, activation runs the full provider chain. Safari/Chrome can still hit the prepared AX chrome model and merge activation-time DOM results into it.
- Volatile providers (`readinessPolicy == .volatile`, e.g. `TmuxProvider`) skip prepared-model lookup and writes.

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

## Adding a new provider

A provider conforms to `JumpProvider` in `FlashCore`:

```swift
public protocol JumpProvider: AnyObject {
    var identifier: String { get }
    var priority: Int { get }
    func supports(_ context: AppContext) -> Bool
    func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget]
}
```

Steps:

1. Create `Sources/FlashProviders/<Group>/YourProvider.swift`.
2. Implement the protocol. Return `JumpTarget`s with **global NSScreen coordinates** (bottom-left origin of primary screen). Honour `deadline` inside any recursive walk.
3. **Do not introduce per-app providers**. The project's working assumption is that generic rules are good enough. If a specific app misbehaves, fix the universal walker (roles/depth/etc.) — don't subclass per bundle id. The previous Messages/Notes/WhatsApp/Linear/Slack subclasses were collapsed for this reason; reintroduce them only if a generic-rule change for the same problem hurts other apps.
4. Register in `Sources/flash/App/ProviderRegistry.swift`'s built-in list. Pick a priority — higher wins on overlapping rects. Existing scale:
   - 30: `BrowserScriptProvider` (Safari, Chrome and Chromium variants — Vimium-style DOM discovery via `do JavaScript`)
   - 10: generic `AccessibilityProvider` (universal AX walker; also handles Firefox's in-page DOM via `AXWebArea` descendants)
5. Add a smoke test and update README.

A `JumpTarget.activate` closure overrides the default action. Use it when the underlying API has a cheaper / more reliable way to "click" than synthesizing a `CGEvent` (e.g. browsers can dispatch `.click()` in JS; AX can call `kAXPressAction`).

## Browser DOM bridge (Vimium sync rule)

`Sources/FlashProviders/Browser/BrowserScriptProvider.swift` contains a JavaScript discovery routine that is a **direct port of Vimium's clickable-element detection**. The user's expectation is that "what Vimium hints" and "what Flash hints" stay observably identical inside Safari and Chromium-family browsers.

Source files in the upstream repo (https://github.com/philc/vimium):

| Upstream file                       | What we port                                               |
| ----------------------------------- | ---------------------------------------------------------- |
| `content_scripts/link_hints.js`     | `LocalHints.getLocalHintsForElement` — the clickability rules. `LocalHints.getLocalHints` — the collect → reverse → false-positive → overlap-via-elementFromPoint pipeline. `LocalHints.getElementFromPoint` — shadow-DOM-aware hit test. |
| `lib/dom_utils.js`                  | `DomUtils.getVisibleClientRect`, `DomUtils.cropRectToVisible`, `DomUtils.isSelectable`. |

The Swift file pins the upstream commit SHA it was last reconciled against, in a block comment above `discoveryJS`. Update procedure when changing the JS:

1. Diff the upstream files against the SHA recorded in the comment block.
2. Mirror any change inside `discoveryJS` line-by-line where possible. Section markers in the JS (`// ----- LocalHints.getElementFromPoint -----` etc.) name the upstream function each block corresponds to — keep them.
3. Bump the SHA in the comment block to the new upstream commit.
4. If a predicate changes category (e.g. a new tag becomes clickable, a role is added, a role drops), update the table below.
5. If a new feature in Vimium has no Flash equivalent (e.g. their Frame./Scroll. body hints) **document the deviation in the "Pieces deliberately omitted" comment in `discoveryJS`** — do not silently drop it.

Currently omitted from the port (be aware before extending):

- Image-map `<area>` hint expansion (rare on the modern web).
- `<body>`-as-frame and scrollable-container hints (Vimium uses these for frame focus + scroll commands; Flash has no equivalent semantic).
- AngularJS `ng-click` attribute family (legacy framework; trivial to re-add).
- Cross-frame walking (Vimium injects per-frame as a content script; Flash only reaches the top window via `do JavaScript`).

Things that match Vimium today: shadow-DOM walk, `aria-disabled`, `onclick` attr/property, the role allowlist (`button, tab, link, checkbox, menuitem, menuitemcheckbox, menuitemradio, radio, textbox`), `contentEditable`, `jsaction` attribute (Google framework, used by Gmail/Drive/Calendar), native tags (`a, button, select, textarea, input, object, embed, label, img[cursor=zoom-*], details`), the `button`/`btn` class heuristic with false-positive marking, the `<span>` false-positive marker, `tabindex` second-class citizens, the `getClientRects()` + viewport-crop + `visibility:visible` filter, the DOM-order reversal + 6-back/3-up false-positive descendant filter, and the `elementFromPoint` overlap filter at centre + four corners.

## Configuration

`~/.config/flash/config.toml`. Hot-reloaded via `DispatchSource.makeFileSystemObjectSource`. The TOML parser in `Sources/flash/Config/ConfigLoader.swift` is hand-rolled and covers: `[table]`, `[table.sub]`, `[table."quoted.key"]`, `key = "string"`, `key = 42`, `key = true`, `key = ["a","b"]`, `#` line comments, trailing inline `#` comments. It does **not** support multi-line strings, dotted keys outside tables, or inline tables. Add support only if you actually need it.

**`config.default.toml` at the repo root is the canonical reference for every key Flash accepts, with its built-in default value.** When you change a default in `Sources/flash/Config/Config.swift`, change `config.default.toml` in the same commit. When you add a new key, add it to the loader (`ConfigLoader.swift`), the struct (`Config.swift`), the default file, the table in this section, and the README — also in the same commit. The default file is what users diff against to see what they could be overriding; it drifts the moment you forget to update it.

Keys:

| Key                                | Type           | Default              |
| ---------------------------------- | -------------- | -------------------- |
| `hints.keys`                       | string         | `"<qwerty>"`         |
| `hints.min_length`                 | int            | `1`                  |
| `overlay.font_size`                | double         | `12`                 |
| `overlay.hint_fg`                  | hex string     | `"#302505"`          |
| `overlay.hint_bg_top` / `hint_bg_bottom` | hex string | `"#FFF785"` / `"#FFC542"` |
| `overlay.hint_border`              | hex string     | `"#E3BE23"`          |
| `overlay.exit_key`                 | string         | `"<escape>"`         |
| `debug.show_bounds`                | bool           | `false`              |
| `debug.bounds_bg` / `bounds_fg`    | hex string     | transparent / `"#FF3B9A"` |
| `debug.profile`                    | bool           | `false`              |
| `debug.slow_ms`                    | int            | `100`                |
| `debug.dump_ax`                    | bool           | `false`              |
| `debug.dump_logs`                  | bool           | `false`              |

Performance behaviours are **not configurable.** The prepared AX model,
the concurrent subtree walk, and the parallel deferred action-name
IPC pass are always on. Per-IPC AX messaging timeout is never set
(see *Prepared model contract* below).

There is intentionally **no** `per_app.*` table. The project's working assumption is to converge on universal rules before re-introducing per-bundle knobs — `Config.perAppRoles` and its TOML parser case were removed for this reason.

### CLI flag + environment-variable overrides (hard rule)

**Every key in `Config` MUST also be exposed via a command-line flag and an environment variable, in the same commit that introduces the field.** This is enforced by reading code review, not by macros — there is no `derive` magic. The four places that move together when you add a key:

1. `Sources/flash/Config/Config.swift` — struct field with the default.
2. `Sources/flash/Config/ConfigLoader.swift` — `apply(table:key:value:into:)` switch (TOML parser) **and** `applyOverride(key:value:into:)` switch (CLI/env parser).
3. `config.default.toml` — the user-visible reference.
4. The "Keys" table above + the README.

Naming convention:

| Surface       | Form                                  | Example                                     |
| ------------- | ------------------------------------- | ------------------------------------------- |
| TOML          | `[section]` + `key = value`           | `[hints]\nmin_length = 2`                   |
| CLI           | `--<section>-<key>=<value>`           | `--hints-min-length=2`                      |
| Env var       | `FLASH_<SECTION>_<KEY>=<value>`       | `FLASH_HINTS_MIN_LENGTH=2`                  |
| Config path   | `--config=<path>` / `FLASH_CONFIG=…`  | `--config=/tmp/flash.toml`                  |

Precedence (high → low): **CLI flag > env var > TOML > built-in default.** Hot-reload re-applies env + CLI on top of the freshly-read TOML, so the overrides stay in effect across `config.toml` edits.

Bool fields accept `true|1|yes|on` and `false|0|no|off` (case-insensitive) in CLI/env. TOML still requires `true`/`false` per the parser.

Unknown flags and unrecognised `FLASH_*` env vars are silently ignored — this is deliberate so adding a new field to a downstream fork doesn't make upstream builds reject the command line. Malformed values (e.g. `--hints-min-length=hello`) are also silently dropped, matching the TOML loader's behaviour.

When you add a field, also add `applyOverrides` test coverage in `Tests/FlashTests/ConfigLoaderTests.swift`.

`hints.keys` accepts either a literal alphabet (`"asdfghjkl"`, ASCII letters only, deduped) or a preset token `<qwerty>` (default) / `<colemak>` / `<dvorak>`. Resolution lives in `Alphabet.resolve(_:)`.

**Flash always walks the focused app only.** There is no `hints.scope` knob and no multi-app walk machinery — background apps and other monitors are ignored. `JumpTarget.pid` carries the focused app's pid so `commit` can re-activate it before dispatching the click. There is **no per-walk deadline** — walks always run to their `maxDepth`/`maxTargets` caps.

`overlay.exit_key` follows Karabiner's angle-bracket convention for special keys: `<escape>`, `<return>`, `<tab>`, `<space>`, `<backspace>`, `<delete>`, `<arrow_up/down/left/right>`. A bare value (e.g. `"q"`) matches that literal character.

## Permissions

Required:

- **Accessibility** — required for AX walks and `AXUIElementPerformAction`. Granted in *System Settings → Privacy & Security → Accessibility*. The bundle identifier is `com.flash.app`; the path must be `/Applications/Flash.app`.

Optional:

- **Automation → Safari / Chrome** — required only for the browser DOM bridge. Prompted on first use of `do JavaScript`.
- **Input Monitoring** — **NOT** required and **NOT** requested. If you find yourself wanting to request it, you're violating rule (2) above.
- **Screen Recording** — **NOT** required and **NOT** requested. See rule (7) above. The plist no longer declares `NSScreenCaptureUsageDescription`.

### TCC and rebuilds

TCC grants for ad-hoc-signed apps are keyed by the binary's cdhash. Every `./Scripts/install.sh` produces a new cdhash and therefore invalidates the previous grant. The user will see "Accessibility / Screen Recording" prompts again after rebuilding. This is a known limitation of ad-hoc development signing. The install script `lsregister -f`s the new bundle to refresh URL-scheme routing, but there is no API to migrate TCC grants. Document the re-grant step in user-facing changes that touch the signing/install flow.

## Build / install / verify

**Every change requires reinstalling** to see it in action. Flash is a resident background process launched out of `/Applications/Flash.app`; there is no live-reload, dev server, or attached debugger flow. `swift build` produces a binary in `.build/` that the resident process is *not* using — only the copy under `/Applications/Flash.app/Contents/MacOS/flash` matters. So the developer loop is:

```bash
# Make code change → run install (NOT just `swift build`)
./Scripts/install.sh

# Trigger and verify
open -g flash://show_hints
```

`./Scripts/install.sh` is what builds release, codesigns, quits the running instance, replaces the bundle, and relaunches. After any code edit (Swift, Info.plist, config defaults, scripts), re-run it. `swift build` / `swift test` are useful only for type-check and unit tests — they do **not** update the binary the system actually runs.

```bash
# Build only (debug; type-check + unit tests, NOT for behaviour verification)
swift build

# Tests
swift test

# Build release, install to /Applications/Flash.app, relaunch — required after every change
./Scripts/install.sh
```

`install.sh`:

1. `swift build -c release`
2. Assembles `build/Flash.app` from the binary + `Resources/Info.plist`
3. Ad-hoc codesigns the staging bundle
4. Quits any running Flash (`osascript`, `open -g flash://quit`, `pkill` fallback)
5. Replaces `/Applications/Flash.app`
6. Codesigns the installed copy
7. `lsregister -f` to refresh URL-scheme routing
8. `open` the installed app so it's resident again

After install, verify:

- `pgrep -fl '/Applications/Flash.app/Contents/MacOS/flash'` shows one PID.
- `open -g flash://dismiss_hints` triggers no visible side effect (overlay was already hidden).
- `open -g flash://quit` exits the process; relaunch with `open /Applications/Flash.app`.

Karabiner-Elements binding lives in `~/.config/karabiner/karabiner.json` under `profiles[<active>].complex_modifications.rules`. Current binding: `control + spacebar → open -g flash://show_hints`.

## Testing UI behavior

Tests in `Tests/FlashTests/` are stratified by what they exercise:

- **Pure-unit** (`AlphabetTests`, `ConfigLoaderTests`, `HintAssignerTests`, `TmuxProviderTests`). Deterministic, run in milliseconds, no external state. `TmuxProviderTests` covers the tokenization rules (`extractWords`), the cell-geometry math (`resolveGeometry`), the status-bar parser (`parseStatusInfo`), the TOML alacritty-config reader, and `parseTwoInts`. Run on every `swift test`.
- **Live tmux integration** (`TmuxIntegrationTests`). Boots an isolated tmux server under a per-test socket (`tmux -L flash-it-<uuid> -f /dev/null`) and asserts the binary's CLI contract Flash depends on: the `#{pane_*}` / `#{client_*}` / `#{status}` / `#{status-position}` format strings; that `capture-pane -p` returns the rendered grid; that horizontal + vertical splits yield the expected `pane_left` / `pane_top`. Catches breakage from tmux upgrades silently changing format-string semantics — the only realistic regression source for `TmuxProvider`. Skipped when no `tmux` binary is found on the probe paths. Runs in ~10 s.
- **Live Firefox AX integration**. The Firefox E2E exists in two forms; both run the same fixture + assertions:
  - **Recommended**: the standalone `flash-firefox-e2e` SPM executable (`Sources/flash-firefox-e2e/main.swift`). Built via `Scripts/build-firefox-e2e.sh`, which signs the binary with the same stable `Flash Dev` identity as the main Flash app. Grant the resulting `build/flash-firefox-e2e` Accessibility once and the TCC grant persists across rebuilds (the cert, not the cdhash, is in the designated requirement). Prints a colourised pass/fail report and exits non-zero on any failed assertion.
  - **Also available**: `FirefoxIntegrationTests` (opt-in via `FLASH_FIREFOX_E2E=1`). Same logic, runs under `swift test`. Skips with a pointer to the standalone runner when the test runner lacks Accessibility, because granting the SwiftPM xctest helper is fragile in practice.

  Both forms launch Firefox to a structured fixture page (data: URL) containing every clickable role we promise to hint plus a deliberate set of "must not hint" elements, and walk it through `AccessibilityProvider.discover`. The fixture exercises three regression modes simultaneously, with assertions targeted at each:
  - **Undermatch** — per-role lower bounds for `AXLink` (5 anchors + 3 img-wrapped), `AXButton` (5 + 1 submit), `AXTextField` (text/email/password/number/tel/url), `AXSearchField`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton` (select), `AXTextArea` (textarea + contenteditable). A regression that narrows the role set or drops a specific input-type mapping triggers a specific failure with the role and expected floor in the message.
  - **Overmatch** — forbidden roles (`AXHeading`, `AXStaticText`, `AXGroup`, `AXGenericElement`, `AXScrollArea`, `AXSplitter`, `AXWebArea`, `AXSection`, `AXParagraph`, `AXDocument`, `AXOutline`, `AXList`, `AXListItem`) must produce zero hints. `AXImage` inside the page area must also be zero, since every fixture image is either wrapped in an `<a>` (decorative under `clickableContainerRoles`) or has no click handler (filtered by the pending-action verifier). A regression in the img-as-decorative folding or the action-name verifier shows up as a non-zero `AXImage` count.
  - **Hidden-subtree exclusion** — disabled controls (5 buttons + 5 inputs), `aria-hidden` subtrees (5 buttons + 5 inputs), and `display:none` subtrees (5 buttons) are seeded into the fixture; they contribute 25 elements that *must not* be hinted. Upper-bound assertions on `AXButton` and `AXTextField` page-area counts catch any regression where the `enabled` filter, the `AXHidden` short-circuit, or DOM exclusion stops working.
  - **Invariants** — page-area targets carry Firefox's pid, frames are non-degenerate, frames intersect the primary screen (catches AX↔NSScreen coordinate-flip regressions), and ids are unique (OverlayPanel's layer pool keys by id).

  Page-area filtering: the test BFS-walks Firefox's AX tree to find the `AXWebArea` frame, then filters hint targets to that rect so the count assertions reason about page content alone (chrome buttons live outside the web area). On failure, the test prints the full role histogram of the page area for diagnostic context.

  Both forms skip when Firefox isn't installed at `/Applications/Firefox.app` OR when the runner lacks Accessibility permission.

Run order:

```bash
swift test                                           # unit + live tmux
./Scripts/install.sh                                 # one-time: creates the Flash Dev signing identity
./Scripts/build-firefox-e2e.sh                       # builds + signs the standalone E2E runner
./build/flash-firefox-e2e                            # runs the Firefox E2E (after granting it AX once)
```

Anything that requires the full overlay / commit pipeline (chip rendering, key handling, AXPress against a live focused app) is still **manually verified**: run `./Scripts/install.sh`, grant permissions if needed, then exercise the app in real target apps.

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
   stay open. Banned by hard rule (2): no global keyboard logic.
2. **Render through a CGS / WindowServer-level window** below the menu
   plane. This uses private SkyLight APIs that aren't part of the public
   AppKit surface. Out of scope.

Workaround for users: dismiss the menu, trigger Flash on the menu's parent
button (which is hinted), commit, then read the menu.

## Common pitfalls

- **AX `AXUIElementPerformAction` requires Accessibility permission.** Without it, the call returns `.notImplemented` or `.cannotComplete` silently; the user sees nothing happen. `--doctor`-equivalent diagnostics live in `Permissions/PermissionCheck.swift` (currently only AX check; extend if adding more required perms).
- **Browser DOM bridge requires Automation permission per-target-app.** A first run prompts; if the user denies, future runs silently return no targets.
- **`NSAppleScript.executeAndReturnError(_:)` returns a non-optional `NSAppleEventDescriptor`.** Don't `guard let` it. Inspect the error pointer instead.
- **`AXObserver` callbacks run on the main run loop.** Don't do AX work inside them — schedule onto `refreshQueue`.
- **`NSPanel(.nonactivatingPanel)` can become key without activating the app.** That is intentional: the overlay needs to receive keys, but stealing focus from the target app would break `AXPressAction` (the action must run *against* the original app, which is why we call `app.activate()` in `commit` before dispatching).
- **`CGEventSource` `.combinedSessionState`** is the right choice for synthesizing input; it sees the current modifier state, so e.g. shift held during commit doesn't poison the click.

## When in doubt

Add a one-line `print` (it goes to stderr → log file in production via the launched bundle) before guessing. Real AX traces win arguments fast.
