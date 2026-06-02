# AGENTS.md — guide for AI agents working on Flash

This document orients an agent (Claude, etc.) editing the Flash codebase. Read this before touching anything beyond a trivial change.

## What Flash is

A headless, resident macOS app that, when triggered by `open -g flash://activate`, overlays vimium-style hint labels on the focused app's clickable elements and clicks one when the user types its hint. No menu bar, no Dock icon, no global keyboard hooks, no CLI client, no autostart.

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
Sources/
  FlashCore/                         # Public SPI (provider protocol + value types)
    AppContext.swift                 # Front-app context: bundle, pid, window frame
    JumpTarget.swift                 # A clickable thing with a screen rect + optional activate closure
    JumpAction.swift                 # .leftClick | .rightClick
    JumpProvider.swift               # The protocol; `supports/discover` API
  FlashProviders/                    # Built-in providers (depend on FlashCore + AppKit)
    Accessibility/AccessibilityProvider.swift   # Generic AX walk. Open class — subclassed by per-app providers.
    Browser/{BrowserScriptProvider,Safari,Chrome,Firefox}.swift
    Apps/{Messages,Notes,Reminders,Postico,WhatsApp,Linear,Slack}.swift
  flash/                             # The executable target
    main.swift                       # NSApplication boot
    App/
      AppDelegate.swift              # Orchestrator + OverlayCoordinator
      URLEventHandler.swift          # Registers GetURL handler; the ONLY hot-path entry point
      AppMonitor.swift               # NSWorkspace + per-pid AXObserver, debounced precompute
      TargetCache.swift              # Per-pid LRU (currently a dict; warm-up only, not read on activation)
      OverlayPanel.swift             # Reusable transparent NSPanel, CALayer pool, animations disabled
      OverlayInput.swift             # NSPanel.keyDown — the ONLY keyboard code in the project
      HintAssigner.swift             # Vimium prefix-free label generator
      ActionDispatcher.swift         # AXPress preferred; CGEvent click fallback
      ProviderRegistry.swift         # Built-in provider list; chain resolution by priority
    Config/
      Config.swift                   # Decoded model
      ConfigLoader.swift             # Hand-rolled TOML subset parser + DispatchSource fs-watch hot-reload
      Alphabet.swift                 # <colemak>/<qwerty>/<dvorak>/literal resolution
    Permissions/PermissionCheck.swift  # AXIsProcessTrusted() — read-only, no UI prompt
Tests/FlashTests/                    # XCTest: Alphabet, ConfigLoader, HintAssigner
Resources/Info.plist                 # LSUIElement, flash:// URL scheme, usage descriptions
Scripts/bundle.sh                    # Release build → staging .app → /Applications/Flash.app, ad-hoc codesigned
README.md                            # User-facing
AGENTS.md                            # This file
```

## Activation flow (read this before editing the hot path)

1. External tool runs `open -g flash://activate[?right=1]`.
2. macOS Launch Services routes to the running instance via `kAEGetURL` Apple Event.
3. `URLEventHandler` parses the URL host/query and invokes the AppDelegate handler.
4. `AppDelegate.activate(rightClick:)` captures `NSWorkspace.shared.frontmostApplication`'s pid via `AppMonitor.currentContext()`.
5. `AppMonitor.discover(now:)` runs `runChain` **fresh** every time (no cache read — see "Determinism" below).
6. `runChain` walks providers in descending priority. For each: call `discover(in:deadline:)`, dedupe overlapping rects (`> 70%` of smaller rect).
7. `HintAssigner.assign` produces prefix-free labels using the configured alphabet.
8. `OverlayPanel.display(hints:)` wraps all layer mutations in `CATransaction.setDisableActions(true)` → no implicit animation; chips appear in place.
9. Panel becomes key (without activating Flash as app, because it's a `.nonactivatingPanel`).
10. `OverlayPanel.keyDown(with:)` matches typed prefix against assigned labels; on a unique match, `AppDelegate.commit` runs `ActionDispatcher.perform`.
11. `ActionDispatcher` prefers `AXUIElementPerformAction(_, kAXPressAction)` (or `kAXShowMenuAction` for right-click) — no cursor movement, more reliable. Falls back to synthesized `CGEvent` click that restores cursor position after.
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

`discover(now:)` is on the activation hot path and **must return the same result for the same UI state**. The previous bug: pressing ctrl+space twice returned different hint sets because the cache held a deadline-truncated snapshot from a background precompute, and reads could land on either the cached snapshot or a fresh run.

Current contract:

- **Cache is write-only on the activation path.** `discover(now:)` always runs `runChain` fresh. The cache + AXObserver-driven precompute exists only to warm AX state (the first AX query into an app pays a one-time cost). If you re-introduce a cache read, you must also guarantee cache entries are *complete* (not deadline-truncated), and you must not write the cache from precompute and read from activation in a way that creates a race.
- **The deadline must be generous enough that walks complete on real apps.** `deadline_ms_cold = 300` (used on activation) is calibrated for current built-in providers; if you raise the role allow-list significantly, re-test that walks finish within budget.
- **Provider ordering is by priority desc.** Within a provider, AX child traversal is in AX-determined order (deterministic).

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
3. If you need a per-app `AccessibilityProvider` variant, subclass it and set roles / `supportedBundles` / depth caps in `init`. Electron apps (WhatsApp, Linear, Slack) need broader role lists (e.g. `AXGroup`, `AXList`, `AXListItem`, sometimes `AXStaticText`) and bigger depth/target caps because Chromium fans out wide.
4. Register in `Sources/flash/App/ProviderRegistry.swift`'s built-in list. Pick a priority — higher wins on overlapping rects. Existing scale:
   - 30: browser/script-bridge (Safari, Chrome) and Electron AX subclasses (WhatsApp, Linear, Slack)
   - 25: Firefox (AX-tuned, walks `AXWebArea` for in-page hints)
   - 20: per-app native AX subclasses (Messages, Notes, Reminders, Postico)
   - 10: generic `AccessibilityProvider` fallback
5. Add a smoke test in the per-app matrix and update README.

A `JumpTarget.activate` closure overrides the default action. Use it when the underlying API has a cheaper / more reliable way to "click" than synthesizing a `CGEvent` (e.g. browsers can dispatch `.click()` in JS; AX can call `kAXPressAction`).

## Configuration

`~/.config/flash/config.toml`. Hot-reloaded via `DispatchSource.makeFileSystemObjectSource`. The TOML parser in `Sources/flash/Config/ConfigLoader.swift` is hand-rolled and covers: `[table]`, `[table.sub]`, `[table."quoted.key"]`, `key = "string"`, `key = 42`, `key = true`, `key = ["a","b"]`, `#` line comments, trailing inline `#` comments. It does **not** support multi-line strings, dotted keys outside tables, or inline tables. Add support only if you actually need it.

Keys:

| Key                                            | Type           | Default              |
| ---------------------------------------------- | -------------- | -------------------- |
| `hints.keys`                                   | string         | `"<qwerty>"`         |
| `hints.min_length`                             | int            | `1`                  |
| `overlay.font_size`                            | double         | `14`                 |
| `overlay.hint_bg` / `hint_fg`                  | hex string     | `"#FFD400"` / `"#1B1B1B"` |
| `overlay.dim_background`                       | bool           | `true`               |
| `overlay.exit_key`                             | string         | `"escape"`           |
| `providers.disabled`                           | array<string>  | `[]`                 |
| `providers.deadline_ms_hot` / `deadline_ms_cold` | int          | `80` / `300`         |
| `per_app."<bundle>".roles`                     | array<string>  | —                    |

`hints.keys` accepts either a literal alphabet (`"asdfghjkl"`, ASCII letters only, deduped) or a preset token `<qwerty>` (default) / `<colemak>` / `<dvorak>`. Resolution lives in `Alphabet.resolve(_:)`.

## Permissions

Required:

- **Accessibility** — required for AX walks and `AXUIElementPerformAction`. Granted in *System Settings → Privacy & Security → Accessibility*. The bundle identifier is `com.flash.app`; the path must be `/Applications/Flash.app`.

Optional:

- **Automation → Safari / Chrome** — required only for the browser DOM bridge. Prompted on first use of `do JavaScript`.
- **Input Monitoring** — **NOT** required and **NOT** requested. If you find yourself wanting to request it, you're violating rule (2) above.
- **Screen Recording** — **NOT** required and **NOT** requested. See rule (7) above. The plist no longer declares `NSScreenCaptureUsageDescription`.

### TCC and rebuilds

TCC grants for ad-hoc-signed apps are keyed by the binary's cdhash. Every `./Scripts/bundle.sh` produces a new cdhash and therefore invalidates the previous grant. The user will see "Accessibility / Screen Recording" prompts again after rebuilding. This is a known limitation of ad-hoc development signing. The bundling script `lsregister -f`s the new bundle to refresh URL-scheme routing, but there is no API to migrate TCC grants. Document the re-grant step in user-facing changes that touch the signing/install flow.

## Build / install / verify

```bash
# Build only (debug)
swift build

# Tests
swift test

# Build release, install to /Applications/Flash.app, relaunch
./Scripts/bundle.sh
```

`bundle.sh`:

1. `swift build -c release`
2. Assembles `build/Flash.app` from the binary + `Resources/Info.plist`
3. Ad-hoc codesigns the staging bundle
4. Quits any running Flash (`osascript`, `flash://quit`, `pkill` fallback)
5. Replaces `/Applications/Flash.app`
6. Codesigns the installed copy
7. `lsregister -f` to refresh URL-scheme routing
8. `open` the installed app so it's resident again

After install, verify:

- `pgrep -fl '/Applications/Flash.app/Contents/MacOS/flash'` shows one PID.
- `open -g flash://cancel` triggers no visible side effect (overlay was already hidden).
- `open -g flash://quit` exits the process; relaunch with `open /Applications/Flash.app`.

Karabiner-Elements binding lives in `~/.config/karabiner/karabiner.json` under `profiles[<active>].complex_modifications.rules`. Current binding: `control + spacebar → open -g flash://activate`.

## Testing UI behavior

Tests in `Tests/FlashTests/` cover deterministic units (HintAssigner prefix-free, Alphabet resolution, ConfigLoader parsing). Anything that requires AppKit / AX / Vision is **manually verified**: run `./Scripts/bundle.sh`, grant permissions if needed, then exercise the app in real target apps.

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
