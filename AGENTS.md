# Flash contributor guide

Flash is a resident macOS app for keyboard-driven hints, normal/insert/command
modes, a configurable status bar, popups and managed stdio plugins.
The `flash` executable is both CLI and resident. Read the relevant maintained
contracts before changing a subsystem:

- [Runtime ownership and determinism](docs/architecture.md).
- [Prepared hint models and refresh scheduling](docs/prepared-model.md).
- [Configuration and command boundaries](docs/configuration.md), with
  `config.default.toml` as the canonical reference.
- [Modes](docs/modes.md), one page each ([NORMAL](docs/normal-mode.md),
  [INSERT](docs/insert-mode.md), [COMMAND](docs/command-mode.md),
  [TERMINAL](docs/terminal-mode.md), [HYPER](docs/hyper-mode.md),
  [HOLD](docs/hold-mode.md), [layers](docs/layers.md)), and
  [input latency](docs/input-internals.md).
- [Plugin protocol](docs/plugin-protocol.md), [Rust SDK](docs/plugin-rust-sdk.md),
  [cookbook](docs/plugin-cookbook.md), [performance](docs/plugin-performance.md).
- [Status format](docs/status-format.md), [status plugins](docs/status-plugins.md),
  [popups](docs/popups.md), [desktop widgets](docs/widgets.md), [help](docs/help.md),
  [telemetry](docs/telemetry.md).
- [Privacy and permissions](docs/privacy.md).
- [Window navigation and placement](docs/windows.md), [tiling](docs/tiling.md),
  [audio devices](docs/audio.md).
- [Performance and latency benchmarks](docs/performance.md).
- [Releases, signing and notarization](docs/release.md); user-facing
  [getting started](docs/getting-started.md), [comparison and FAQ](docs/comparison.md),
  [alternatives](docs/alternatives/README.md) (one page per tool, with a
  migration section), [troubleshooting](docs/troubleshooting.md).
- `docs/*.md`, ordered by `docs/nav.json`, is the one source of the manual,
  rendered by the help's own docs view: the resident serves it from the app
  bundle at `/docs/<page>`, and `mise run build:site` prerenders the same
  view for <https://aymericbeaumet.github.io/flash/> (`.github/workflows/pages.yml`).
  Local links stay under `/docs`, published ones under `/flash/`; live help
  pages (`/mappings`) are links only in the resident. All help prose lives in
  `docs/` (plugins keep their manifest `help` topics): new pages join
  `docs/nav.json`, with `aliases` for `:help` short names, and the build fails
  on a broken link or anchor. See [building the documentation](docs/help-internals.md#building-the-documentation).

## Assemble great tools

Flash assembles the tools people already trust; it does not replace them.
Before building a dashboard, report or monitor, check whether a maintained CLI
or TUI already does the job (btop, newsboat, calcurse, tokscale). If one does,
show it in a terminal popup and document the configuration: installing and
configuring the tool belongs to the user's system and dotfiles, never to Flash,
its plugins or its installer. Flash adds only what no tool can: keyboard
access, hints, commands, compact status values for the bar, and the popups and
glue that tie the tools together. When a homemade surface duplicates such a
tool, remove it rather than maintain both.

## Hard constraints

1. UI is confined to hint/grid overlays, advanced-mode status/command surfaces,
   help/open-app views, explicit alerts, About, configured popups, native
   notifications posted through `UNUserNotificationCenter` by `notify` and
   monitors that ask for them (authorization asked on the first post, never at
   launch), and configured desktop widgets: a `[widgets.<name>]` status format drawn only in
   a click-through `WidgetWindow` at desktop level (above the wallpaper, below
   Finder icons and every app window), never key or main, with no mouse input,
   chrome or preferences UI.
   The sole `NSStatusItem` belongs to `StatusItemController.swift`, gated by
   `app.menu_bar_icon`, with exactly About / Open Configuration / Quit. No other
   status items, Dock tile, preferences window or `NSAlert`.
2. Global keyboard capture lives only in `KeyboardCaptureTap.swift` (session
   keyDown tap) and Carbon registrations for explicit modified-key mappings.
   The tap only decides whether a keypress is swallowed and routes swallowed keys;
   it never logs, persists or exfiltrates keys. Command/modal typing goes through
   `NSPanel.keyDown`; the key-window path also supplies the no-tap fallback.
   No additional event taps or global key monitors.
3. Autolaunch is configuration-owned `AutoLaunch.reconcile` using SMAppService.
   No LaunchAgents, helpers or login-item UI. The installer only cleans up the
   retired LaunchAgent.
4. One resident process, bundle identifier `com.flash.app`. External activation
   is the resident's IPC socket alone (`IPCServer`, [protocol](docs/ipc-protocol.md)):
   one Unix domain socket, never TCP, at
   `~/Library/Application Support/Flash/run/flash.sock` (directory `0700`,
   socket `0600`), answering only peers of the resident's uid (`getpeereid`),
   speaking versioned NDJSON with bounded lines, connections, in-flight
   requests and subscriber queues. A `request` runs its words exactly as
   `:<words>` (`runInvocation`); `subscribe` streams the host-event catalog
   minus plugin plumbing, never keys, typed text, clipboard content or titles.
   The `flash` CLI is the only client Flash ships; it starts the resident
   through Launch Services when none runs. Native mappings dispatch
   in-process. Plugin sandboxes deny the socket. Plugins are host-owned NDJSON stdio children,
   with stderr for diagnostics and stdin EOF for shutdown. Besides the socket
   and the loopback help server (`DebugServer`), exactly one listener exists:
   the opt-in OTLP/HTTP receiver (`OTLPReceiver`, `[telemetry.receiver]`, off
   by default, port 4318), bound to 127.0.0.1 itself with `Host` checks,
   refusing cross-origin requests, sending no CORS headers, and only
   ingesting telemetry. No other custom external IPC, sockets, Mach services,
   Apple Event command handlers, daemonized clients, `flash://` URL scheme,
   separate `flashctl` executable or client library (guardrail-enforced).
5. No Flash process ever reads screen content: no OCR, Vision,
   ScreenCaptureKit, `CGWindowListCreateImage`, `CGDisplayStream` or any other
   in-process pixel read. WindowServer metadata is allowed, for geometry,
   occlusion and window identity. Capture belongs to the `screenshot` plugin,
   which spawns Apple's `screencapture` to write straight to the clipboard —
   the one reason Flash holds Screen Recording, and no image data crosses a
   Flash process even then. Accessibility is the grant for AX and the keyboard
   tap; do not add Input Monitoring requests.
6. Empty target discovery stays silent. Never show a no-targets banner.
7. No backward-compatibility shims. Renames update code, bundled plugins,
   defaults, tests, docs and affected `~/.config/flash/flash.toml` entries together.
   Reject malformed input; do not add aliases, dual wire readers, old-name type
   aliases, deprecations or transitional accept-both paths.
8. Providers describe target geometry and semantics; `ActionDispatcher` owns
   every committed host mouse event. Hint providers are the generic
   Accessibility walk and the terminals plugin (tmux panes), the one bundled
   plugin declaring manifest `hints`. Browser content comes through AX web
   areas; do not add DOM bridges or AppleScript-based hint discovery.
   Held-button press, drag and release events clear inherited keyboard flags;
   a modified shortcut must not turn a primary press into a Control-click.
9. NORMAL is persistent. INSERT has exactly one entry (`InsertEntry`):
   bare `mode insert` (vim's `i`), or any mapping configured to run it. It
   takes no argument and runs nothing first: no placement, no change. No
   click, hint or grid commit enters INSERT: a physical click, `f` (`mouse
   target`), `F` (`mouse grid`) and a click chain keep the mode wherever they
   land, a text field, a password field or a terminal included. Every other
   mapping or command preserves NORMAL, `app find`, `tab new`, tab switching,
   `input focus`, the `input` and `move` moves, HOLD's and VISUAL's
   operators and the letter jump `s` included; never add editable-focus
   follow-up or mode changes on app activation. Hint targets carry no mode
   intent.
   Entering INSERT stays explicit: every other transition into it only
   restores a command line, popup or layer opened from INSERT
   (`ModeReducerTests` enumerates them).
   Unmapped NORMAL keys and chords are swallowed, except while a native
   context menu or the Dock's Mission Control or App Exposé owns the screen,
   where only mapped keys are, the one mapped to `app cancel` (Escape) aside;
   synthesized input must never become stray terminal text. See the mode guide.
10. Dev deployment must use `mise run install:dev`, which owns build,
    signing, replacement and restart order. Do not hand-copy/sign/kill the app.
    The dev bundle is `/Applications/Flash 🧪.app`; release is
    `/Applications/Flash.app`. `mise run install:release` is a clean universal
    release install and must not be used for development.
11. Flash never edits text: NORMAL/VISUAL navigate, select, copy and paste;
    editing belongs to the app (or kindaVim/SketchyVim). No command, default
    or bundled binding deletes, changes or cuts text (the app's own Cut
    included), and none inserts anything but a paste or a flashlight pick;
    `NoTextEditingTests` walks every default table and the command catalog.
    See `docs/vim.md` ("What Flash does not do with text").

Surface requests that would violate these constraints before implementing them.

## Change discipline

- Prefer explicit value state, pure transitions and one owner for each resource.
  Invalidate asynchronous ownership before teardown; never let an old callback
  mutate a replacement. Add meaningful failing regression tests for nontrivial
  behavior before implementing its fix.
- Mode entry preserves the focused external app. Mode events and base-mode
  effects carry no activation target; clicks and app commands own focus changes.
  A dismissed Flash surface yields activation only while Flash still owns it.
  A captured picker delivery belongs to the finder session generation, not
  the pending mapping sequence: returning focus refreshes mappings without
  cancelling the pick; closing or replacing the session still cancels it.
  Command dispatch resolves current app identity before a captured PID; CLI
  and Carbon entrypoints cannot depend on key-tap focus reconciliation.
- Which-key follows the effective interpreter, including built-in selectors and
  count/register interception. Keep complete next-key atoms readable and verify
  real font measurements on small screens; see [NORMAL](docs/normal-mode.md).
- Preserve deterministic complete discovery. AX events invalidate dirty tokens;
  configuration changes invalidate revisions. New UI-mutating notifications must
  join `AppMonitor.observedNotifications`. Do not deadline-truncate walks or serve
  partial captures. Keep refresh cancellation and maintenance generation-scoped.
  A background-walk cost budget is a fraction of the model's freshness window
  (`slowAutomaticModelRefreshFraction`), never an absolute number of
  milliseconds: the apps hints matter for (Electron, Gecko, Catalyst) walk in
  50–100 ms, and a slow walk lengthens the app's interval, never cancels it.
- Cross AX/CGEvent and NSScreen coordinates through FlashCore `ScreenPoint` /
  `ScreenRect` `toAX` / `toNS`, using the primary-screen height. Raw flips stay
  inside `ScreenSpace.swift`. Screen unions start at `.null`. Layer changes disable implicit animation and new layer
  properties join `OverlayPanel.noActions`.
- The status bar draws only in `StatusBarWindow`, ordered above the native menu
  bar and its extras and below transient overlays; never re-parent its layers
  into the overlay panel. It lowers for exactly one case, a reveal under the
  pointer, via the reveal probe. Enabling the bar auto-hides the native menu bar
  through `NativeMenuBarAutoHide`, which reverses only what Flash set; keep that
  ownership rule when touching any other global preference.
- The updater is in-process (`UpdateController`): it checks GitHub's latest
  stable release, verifies the asset against GitHub's SHA-256 digest and the
  bundle's code signature, swaps the bundle with one `RENAME_SWAP`, and
  relaunches into a process that waits for the resident lock. No helper,
  installer, Sparkle or launch agent. Only a Developer ID build installs on
  its own (same designated requirement, so TCC grants survive), and only at
  quit or while away and idle; an ad-hoc build asks; a development build
  never updates. Tests inject every network, file and signature seam.
- Flash writes no macOS preference but the menu bar's auto-hide
  (guardrail-enforced): setting the Mac up is the user's own commands in
  `[startup] run` (`defaults write`, `killall Dock`), run by `StartupRunner`
  once per launch after the first configuration load and on `startup run`,
  never on a reload. Its commands go through the monitors' executor
  (`MonitorProcess`, or a Flash command on main) from the runner's own
  queue, in order, every one even after a failure, one run at a time; no
  curated settings catalog, ledger or password prompt. Tests inject the
  executor and never run a user's list. See `docs/startup.md`.
- Desktop widgets draw only in `WidgetWindow` (one per widget per display,
  owned by `WidgetController`) and render stacked status lines through the
  shared `StatusRunRenderer`, not a document renderer. They evaluate inside
  `FlashStatusBarController` beside the bar, with one source/job registry and
  one `PollScheduler` deadline; no widget timers. An occluded widget drops out
  of the required sources, jobs and clock.
- Monitors (`[monitors.<name>]`) evaluate in that controller beside the bar, on
  the one clock at `low` priority, and alert only on transitions (a rise into
  warning or error, `MonitorTracker`) through `StatusAlert`; no monitor timers.
- A system window in front of the focused app (Notification Center's panel,
  Control Center, a menu extra's popover, Spotlight, a Dock stack, an agent's
  dialog) is what `f` walks (`AppMonitor.coveringInteractionWindow`); an
  authentication prompt (SecurityAgent, LocalAuthentication) refuses hints and
  is never walked or clicked, nor the window behind it.
- Hint commits validate captured target identity off the main thread. A missing,
  changed, or ambiguous target cancels; never fall back to its old coordinates.
- Hot paths never spawn a process where a persistent channel exists: an exec
  can stall for seconds while macOS's `syspolicyd` is busy. Local tmux
  commands go through the control-mode observer (`ControlObservers::run`),
  process trees through `flash_plugin::sys`, and fixed AppleScript operations
  through the host's `AppleScriptRunner`; a spawned
  client is the fallback. Keep OSA work inside the runner's lifetime gate through
  disposal, component close and autorelease-pool drain; a caller timeout never
  releases an active runtime.
- Resolve version-manager shims before caching executables used repeatedly on a
  hint hot path. Tmux status hints require exact supported format geometry; do
  not approximate unknown status layouts (see `docs/architecture.md`).
  Terminal link captures preserve OSC 8 destinations separately from display
  text; escape bytes never count as cells. Reject unsupported geometry or a
  layout that changes across capture instead of publishing misplaced hints.
- Every popup uses a real PTY session owned by `StatusTerminalRegistry`, one
  per name. Text popups use the shared terminal pager; do not add a separate
  native document renderer. Keep focused pager input and its snapshot stable
  until explicit refresh. Popup lifecycles are exactly `persistent` and `fresh`,
  with one restart backoff; presentation ends a showing once, through
  `hide`. See the popup guide.
  A focused terminal and a separate hover preview may coexist, with one
  presentation per popup name. Preview dismissal never closes or takes
  keyboard focus from the focused terminal; promotion transfers that ownership.
  Only a live hover preview contributes its popup's clock deadline; hidden
  popups and focused pager snapshots must not keep that clock ticking.
- Prefer events to polling. A window move or resize reads its frame from the AX
  element that fired, never a WindowServer scan, and schedules no settle tick.
- A source that switches tabs or windows replies with the `navigation_url` it
  landed on; the host records that stop per press. A catalog refresh settles
  after a burst and shows only its last state, so it never stands in for it,
  and the observation in flight still names the location just left: a
  performed switch leaves its key settling so that one is dropped, never a
  stop that reorders the run.
- The process-wide AX messaging timeout has one owner: the resident sets it once
  at launch (`AXApp.configureProcessMessagingTimeout`), every system-wide
  element comes from `AXApp.systemWide()`, and nothing else sets a timeout on
  one (guardrail-enforced); per-element bounds go on the element itself.
- Focused-window state commands use `WindowLayoutManager`'s serial AX queue and
  `WindowMover.resolveWindow`'s focused/main/window-list fallbacks; keep AX
  requests off the main keyboard loop. Native full screen uses `AXFullScreen`,
  while `window move --position=maximized` remains a usable-frame resize.
  Restore first uses the manager's most-recently minimized window because
  minimizing an app's last window can move focus to a different process.
- Directional window focus reads a prepared AX window catalog; catalog walks
  run on the separate navigation-build queue. Placement rules run once per AX
  window identity for each changed rule set so manual moves remain respected.
- Tiling's `TilingEngine` lives on `WindowLayoutManager`'s queue and reads
  the navigation catalog; it owns the frames of the windows it manages, so
  layout tracking, recovery and placement rules stand aside for them. Pure
  `TilingTree`/`TilingSolver`/`TilingWorkspaces` values decide; only changed
  frames are written. Disabling tiling or quitting brings every parked
  window back on screen.
  A semantic layout (`WindowLayoutIntent`) keeps its home display by UUID:
  display-change recovery only changes where the window sits, and returns it
  home when that display reconnects; only a placement moves home.
- App-scoped mappings select by the focused app's exact bundle ID. Refresh the
  effective mapping table on focus changes; defer Carbon registration work off
  the key event path. CoreAudio, now-playing Apple Events, the
  `caffeinate` power assertions and the Notes, Reminders, Contacts and
  Calendar reads run on their owners' serial queues (`MediaController`,
  `CaffeinateController`, `AppleCatalogs`, `CalendarEvents`), never on main.
  Those catalogs ask macOS for access only when a scoped query or refresh
  command uses them; Calendar only when a surface or monitor reads a
  `#{flash.calendar.next…}` value or a `calendar` command runs.
- `CGWindowListCopyWindowInfo` off the main thread deadlocks against a
  main-thread Core Animation commit for SkyLight's 500 ms timeout, freezing
  main too. Read the window list only through `WindowSnapshot.windowList`
  (guardrail-enforced), and never make main wait on a queue that calls it.
- Polling is a last resort and goes through `PollScheduler`, the one clock in
  the process; never arm a `DispatchSourceTimer`, a `tokio` sleep loop, or a
  `Timer` for a recurring job in core or plugin code. Use `register` for a fixed
  cadence and `scheduleOnce` (or `PollDeadline`) when the next wake-up is an
  irregular or re-arming deadline — debounces, retries and backoffs included.
  Plugins register over the wire with `poll` (the Rust SDK's `ctx.interval`,
  `ctx.after`, `ctx.wait` and `Settle`) and are ticked with `core:poll:<name>`;
  they never sleep to schedule work. Every registration names its priority —
  `system` (core input-adjacent probes only), `high`, `normal`, `low` — matching
  how visible lateness is: slack is what lets wake-ups coalesce. Scope every
  registration to when it can observe anything (a subscriber present, the
  pointer in the band, a browser listening, the hyper key while HYPER is
  latched), saying so where it is armed. The hyper hold watch
  (`core:hyper-hold`, priority `system`) is the backstop for a key-up the
  session tap dropped: two ticks of `CGEventSource.keyState(.hidSystemState)`
  reporting the chord up, and only while HYPER is latched. Combined session
  state can report a swallowed key as up; do not read it for this.
  Secure input (`core:secure-input`, priority `low`, every 2 s for the life of
  the resident) stays armed for the same reason: while the flag is on the
  session tap gets no keys, so only this poll can see a hold that outlived the
  password field. An off tick reads the flag alone: nothing else it
  gathers decides anything then. `SecureInputRelease` leaves a focused secure field, and a
  text field in the holding app, alone. One release attempt per episode; no
  dialog and no lock screen.
  Polls pause while displays sleep or the session is locked; the scheduler
  owns that gate and resumes with one catch-up tick, so clients never check it.
  Use `CLOCK_MONOTONIC_RAW` for sleep-inclusive deadlines; compare readings
  of the same clock in tests, as macOS clock epochs may differ.
  The guardrail script enforces both sides; see `docs/architecture.md` for the
  one-shots that may stay plain `asyncAfter`.
- A queue's QoS follows who waits on it, and a registration's priority and
  its handler queue's QoS must match: work a keypress, a plugin reply or a
  `system`/`high` wake-up waits on runs `.userInitiated` (the clock, the
  plugin lifecycle/read/write/deadline queues, the AX broker, the reveal
  probe); `.utility` is only for work nobody waits on (catalog decode, logs,
  persistence, telemetry); a serial queue never mixes the two. The guardrail
  rejects a `system`/`high` registration on a `.utility` queue.
- Keep native controls outside the custom layer-hosting drawing view. AppKit owns
  their backing layers; transient recycling may replace only Flash's subtree.
- Keep the main-loop keypress/recapture path free of AX/WindowServer IPC, sleeps,
  subprocesses, filesystem I/O, full layout and Carbon registration churn. With
  a live tap, recapture only restores NORMAL routing. Scope-only changes call
  `MappingsCoordinator.apply(scope:)`; full registry rebuilds require changed
  effective mappings. Build command completion inventory once per session.
- Reuse `FlashSource` capabilities, activation/readiness policies and semantic
  `FlashPriority`. Per-input computation belongs to `FlashQueryEvaluator`, not
  catalog sources. Sources return global NSScreen coordinates and canonical
  openable URLs when available. `.failed` owns a failed command and prevents a
  duplicate fallback; `.unhandled` permits the next source or host fallback.
- Every command is `flash <topic> <action> [--name=value ...]`: exactly two
  words of `[a-z][a-z0-9_]*`, the topic (what is acted on) first. An action
  keeps `_` only when it is a compound (`scroll half_page_down`); `_` never
  joins topic and action. The CLI, mappings (`["flash", "tab", "next"]`), the
  command line (`:tab next`, completed topic then action), the queries
  (`resident status`, `config check`) and plugin commands share the shape and
  one topic namespace. `flash <words>` and `:<words>` are one grammar: one
  resolver (`resolveCommandWords`) and one runner (`runInvocation`), so
  prefixes, ex names and built-ins work in both; only mappings and config
  files require exact words. A plugin command is `flash <command> <subcommand>` with
  both words required (`flash screenshot window`); `*` is the wildcard
  subcommand. Manifest `commands[]` rejects an empty or malformed word,
  manifest `verbs` (one word) is an unknown key, and a name another plugin's
  own command uses fails the load. An own command never takes a topic word: a
  `commands[]` entry under one of Flash's topics declares a core command the
  plugin performs in its context and must name one Flash asks of the focused
  app (`URLEventHandler.sourceCommandNames`); it never registers for dispatch
  or completion. A new command adds its `"<topic> <action>"` entry to
  `URLEventHandler`'s table, `docs/commands.md` and the inspector's
  `topicCategories`; one that asks the focused app for something marks
  `URLCommand.sourceCommand`, whose words are its argv tail. `CommandGrammarTests`
  and the guardrail enforce this.
- Plugin Apple Events use typed `host.applescript` operations with fixed host
  templates and escaped literal data. Never accept plugin script source or
  treat lexical source inspection as a sandbox boundary. Check each operation's
  actual app target against its declared `apple_events_targets`.
- Validate plugin wire changes across Swift and Rust. The wire contract lives in
  `Plugins/_flash_plugin_rust`: `protocol.json` pins the constants, the
  `wire`/`runtime` suites and the `probe` workspace member pin the behaviour. A
  wire bug gets a failing test there before its fix; domain behaviour gets a
  unit test in `Plugins/<id>`.
- Keep plugin stdout protocol-only and bound encoded bytes, queue admission,
  requests and shutdown. A publish is proportional to the change: volatile
  and static rows are separate sources, each published alone
  (`publish_source`); the host counts catalog bytes from the frame it holds
  and decodes catalogs on a per-plugin queue carrying no replies. Third-party
  GitHub refs require a full pinned commit.
  Capabilities default-deny sensitive surfaces; explicit plugin settings carry
  credentials, never inherited ambient secrets or inspector-visible values.
  Packaged official plugins come only from the app bundle, never the working
  directory. Required sandboxes fail closed. Host fetches validate every
  redirect and bound bytes while receiving, not after buffering the response.
- Clipboard history belongs to core `ClipboardHistoryStore`; text registers
  belong to `RegisterStore`; app marks belong to `MarkStore`. Keep their
  command, help and privacy surfaces in sync, and migrate stored data when
  changing its path.
- Seatbelt denies cannot be reopened by later allows. Carve permitted children
  out of the deny, canonicalize symlinked paths, and retain secret-read denies.
  Local socket connections require network capability. Do not widen the sandbox
  to host credentialed network CLIs that require the subprocess shape.
  Sandboxed HTTPS clients verify against bundled roots (reqwest
  `tls_certs_only` over `webpki-root-certs`): the platform verifier needs the
  trust service and keychains the sandbox denies. After a TLS dependency bump,
  confirm a live fetch under the sandbox, not only unit tests.
- Standards (docs/standards.md): what Flash defines uses exactly one modern
  standard (TOML, Flash's key syntax, CSS hex colors, OTLP); what it consumes
  from other tools is accepted as they write it (SwiftBar/i3blocks/waybar
  output, tmux formats). Never add a parallel format or second spelling of a
  Flash setting; record a new decision there. Config keys feed
  `ConfigSchema`: run `mise run build:schema` after changing keys or defaults.
- Config validation is shared by all layers; preserve authored values and derive
  only after overrides. Only executable/working-directory fields receive path
  resolution; argv tails stay opaque. Update whole-section default parity tests.
- `[app] keyboard_layout` is the input source that reads a keypress (`auto` or
  `com.apple.keylayout.*`). `[keyboard] layout` is the logical layout (default
  `qwerty`; `colemak`, `dvorak`, `bepo`) for hint positions, the mouse grid,
  bisect, pointer movement and derived HYPER arrows. With `hints.keys` still
  the bundled default, a non-QWERTY layout's hint alphabet is that layout's
  letters (`<colemak>`), so the file does not also set `hints.keys`. HYPER arrows are the
  physical QWERTY ESDF positions (up, left, down, right). F is the home-row
  index-finger mark. They are spelled as the letters that layout types
  (Colemak `f` `r` `s` `t`). A shifted letter arrow is `shift+` that letter.
  A non-letter uses the character Shift types (Dvorak's period on E is `>`).
  Do not merge the two layouts.
- NORMAL defaults and bundled plugin mappings bind keys to commands, never to
  raw chords: none uses `key send`, which stays a user escape hatch (a test
  enforces it). A command that asks the focused app for something resolves in
  its context: a source that performs it (a plugin's core `commands[]`
  entries, the AX tab strip), else the winning plugin `bindings` entry, keyed
  by the command line (`"tab new"`, `"app reload --force"`: chord, sequence,
  menu item or `false`), else nothing; terminals never receive a chord they
  would type. App knowledge — conventions included — is plugin `bindings`
  data (`defaults` carries the macOS ones), never host chords or
  conditionals; a guardrail rejects `kVK_` chord synthesis outside the
  binding dispatcher and the retired action vocabulary anywhere. `move`
  (NORMAL's `h` `j` `k` `l`, half pages, pages, `gg` `G`) resolves by the
  cached `FocusRegion` (`FocusRegionTracker`, re-read off the main loop on
  each focus change, never AX on the keypress): the `input` arrows in
  the engaged field, its own binding (the arrows) in a collection and for
  `h` `j` `k` `l` in a page or a field not engaged, `scroll` for the page
  keys and edges there, and `scroll` for every `move` in a terminal. Editable focus alone never makes text:
  `TextScope` (`isActive(for:pid:element:)`, the one text-or-page
  predicate) is an engaged element identity, set only by leaving INSERT in
  a field, `gi`, a primary click or an `f` on a text input whose focus
  settles on editable text, and `v` / `V`; it ends when the focus settles
  on another element or app, on Escape (the text table's `mode leave`) and
  on any mode change but the INSERT, VISUAL, command-line and HYPER round
  trips. NORMAL's table
  follows the engagement only, never a focus reading, so focus noise never
  drops a pending sequence. While engaged,
  `[mode.text.mappings]` is read before NORMAL's: Vim's `cursor` motions,
  computed from the AX text off the main loop and set through
  `AXSelectedTextRange`, the app's binding only where it gives no text.
  Flash never writes text through AX (`AXSelectedText`, `AXValue`): it
  sets the caret or the selection, reads it back, then uses the app's own
  keys. VISUAL (`v`, `V`, `VisualSession`) sets the selection the same way,
  from an anchor the motions never move, and its operators are the app's
  Copy and paste (and `o`, swap ends); a named register is written by
  Flash from the text it read. It ends in NORMAL, and whenever the focused
  field or app changes or a click lands. Vertical scrolls send configurable
  line-based wheel events system-wide, without AX fallback. Keep guides in
  sync.
- Every centred alert is one `StatusAlert` drawn by `displayAlert`: a message,
  a title over a value, or a confirmation. A destructive command asks through
  it — `alert confirm` wraps a command line, and a core command a plugin
  performs destructively declares `confirm` on its `commands[]` entry — as a
  hint-session phase that owns the keyboard in every mode. Plugins never post their own
  prompt: NORMAL capture would swallow the answer.
- Telemetry: the receiver decodes off main into the bounded, memory-only
  `TelemetryStore`; `#{flash.otel…}` values wake only the surfaces reading that
  metric. Instrument through `FlashTelemetry` (a lock and an append, content-free
  attributes: never keys, bundle ids, titles or typed text); exports ride
  `PollScheduler`, carry explicit-only headers and never target the receiver.
- Every host event goes out once through `AppDelegate.emitHostEvent`, to the
  plugins whose `listen` admits it, the `[monitors]` whose `event` does and
  the socket clients subscribed to it (`IPCEventHub`): one catalog
  (`PluginProtocol.hostEvents`, `protocol.json`, the Rust SDK's
  `host_events`, `docs/schema/ipc/event.schema.json`) and one fan-out. A new
  event joins all four (`HostEvent.isStreamed` says whether clients get it);
  an OS source runs only while `hostEventHasSubscriber` says something
  listens. IPC wire changes update `IPCProtocol`, the schemas and
  `docs/ipc-protocol.md` together, with `IPCSchemaTests` validating real
  encoded messages; a breaking one bumps `IPCProtocol.version`, no shims.
- NORMAL's `.` and macros (`MacroState`) record dispatched commands, a
  natively fired chord included, and submitted command lines, never keys. `:!` and `:normal` are grammar resolutions, so the CLI runs them too.
- Log events as `[area] event` with values in `fields`, at the level
  `docs/observability.md` defines: `error` for failures that are not the
  user's input, `warn` for handled degradation, `info` for rare state changes
  and rejected input, `debug` per user command, `trace` per key, frame or
  plugin request. No warn or error storms from a persisting condition.
- Log diagnostics through the serial log writer. XCTest disk logging uses only
  temporary destinations. Never capture a handle that rotation can invalidate.
- Test windows never cover the user's screen or take their keyboard:
  `TestWindowHygiene` makes every window the suite orders in transparent,
  refuses `makeKey`, and fails a test that leaves one drawn or makes one key
  (a key test window steals typing from the user's frontmost app). Test the
  logic a key window would run, never `becomeKey()` itself.
- A test run never takes the keyboard: Flash activates itself and changes its
  activation policy only through `AppActivation`, inert under XCTest
  (guardrail-enforced). An `xctest` that activates sends the user's keys to
  its transparent windows.
  Fake-display recovery tests inject application discovery; they must never
  enumerate or move the user's real windows.
- Keep this guide actionable and concise; explanations belong in `docs/`.
  Browser help routes, runtime data, and the single-file UI build are documented
  in `docs/help-internals.md`; rebuild the committed inspector resource after frontend
  edits (`mise run build:inspector`).
  Resumption notes belong in transient `.handouts/`, never external memory.
  Static unused-code reports need caller/protocol/dynamic-dispatch review before
  deletion; app-layer declarations can still have runtime consumers.
- `docs/privacy.md` is the public inventory of permission prompts, network
  destinations, stored data, and unsandboxed plugins. Update it in the same
  change that alters any of them, and keep README privacy claims true.
- Browser fixture-collector captures (`Tests/BrowserSnapshots/**/collected-*`)
  are real browsing sessions: keep them local and gitignored. Guardrails reject
  tracked ones.

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
  Flash's key DSL and `<topic> <action>` argv grammar.

A dependency exception needs a concrete unsupported requirement; surface it
before replacing these implementations. Approved exception: `apple/swift-protobuf`
with OTLP types generated from a pinned opentelemetry-proto release into
`Sources/FlashOTLP` by `mise run generate:otlp` (never hand-edited), because
OTLP/HTTP requires protobuf, a versioned binary schema Foundation cannot decode.

## Build, verify and deploy

Keep exact tool pins and the cross-platform `mise.lock` together. Rust target
installation belongs in `mise.toml`; application builds must retain frozen
lockfile flags. Xcode and browser GUI fixtures are the system prerequisites.

Run inside the current bonsai worktree. Prefix shell commands with `rtk`.
mise is the single developer environment: `mise.toml` pins the tools, sets the
shared environment and defines every entry point as a described task, and
`mise run <task>` runs it with the pinned tools first on PATH. Call tasks, not
the `Scripts/` implementations or the toolchain commands they wrap. No
Makefile, justfile, Taskfile or wrapper script: a new entry point is a task in
`mise.toml` (the guardrails enforce this).
`mise tasks ls` lists the tasks; [development](docs/development.md#tasks)
describes each one.
Release plugins stage under `build/plugin-release`; never replace binaries in
the live dev plugin tree while building a release. Release assembly copies
declared outputs and validates the complete bundle, including dependency
notices. See [release validation](docs/release.md).
A fresh checkout runs `mise run setup` (the pinned tools, then libghostty-vt);
the build, install, test and integration tasks bootstrap Ghostty themselves.

Required checks for relevant changes:

```sh
rtk proxy mise run check
```

It runs, in order, `fmt` (swift format in place), `lint` (strict swift-format
lint), `guardrails`, `test:plugins` (every plugin lane) and `test` (the Swift
suite against real plugin binaries). Changes to `docs/` or `Inspector/` also
run `rtk proxy mise run build:site` (the published manual and its link check)
and `rtk proxy mise run test:inspector`.

The plugin gate (`mise run test:plugins`) has three lanes over the SDK
workspace — including its `probe` member — and every plugin crate: `lint`
(`cargo fmt --check` + clippy `-D warnings`), `units` (the plugin-publication
test plus per-crate `cargo test --locked`) and `build` (a dev build of every
executable plugin). Use targeted lanes during development
(`mise run test:plugins -- --lane units`); run every lane before finishing.
Status-language changes also run `mise run test:status-format` against the
pinned tmux baseline.

Every verified app-code iteration ends with `mise run install:dev`, commit
and push. The installed resident does not use `.build` directly. Use the commit
and push skills, re-inspect state between stages, and stage explicit paths only;
never `git add -A` because the maintainer may edit concurrently. Do not add any
agent/tool attribution. Branches created for work use `ab/<kebab-case-slug>`.
Bonsai alone manages worktree lifecycle.

After installation, verify one resident under `/Applications/Flash 🧪.app` and
that `flash hints dismiss` dispatches. `flash resident quit` quits it. Changes to
hint discovery/commit should run the signed native, browser and Electron fixtures:

```sh
rtk proxy mise run test:integration   # native, browser, then Electron
```

The integration tasks own their fixture processes and cleanup. Native/Electron
oracles verify real host clicks; the browser oracle compares AX targets with
reference DOM markers. The no-tap key-window fallback may dismiss native menus.
Resident native probes require `debug.http_inspector_enabled = true`; restore
the original setting after verification.
GUI probes require an unlocked console session. Check session state before
sending test input and after unexpected delivery failures. While locked,
Workspace lookups may be empty and AX window references may resolve to the app;
neither those results nor missing input events establish an application bug.
Type-checking and pure tests do not verify the visible overlay: report any
remaining manual verification honestly.
