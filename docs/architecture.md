# Runtime ownership and determinism

Flash is one resident macOS application. Its executable also implements the CLI:
arguments invoke a verb by custom AppleEvent (`Flsh` / `Cmd `); no arguments start
the resident. `flash status` and `flash doctor` travel the same event and read
JSON from its reply; `flash config_check` never leaves the CLI. Configured mappings resolve through the same command definitions
and dispatch in-process. Other mapping executables receive an argv array.

## Boundaries

| Owner | Responsibility |
| --- | --- |
| `FlashCore` | Source/evaluator protocols, immutable target/candidate values, visible-region finalization |
| `FlashProviders` | Accessibility discovery, never target activation |
| `AppMonitor` | Focus observation, provider selection, complete prepared models and refresh scheduling |
| `ModeStore` / `ModeReducer` | Serialized mode transitions and ordered effects |
| `ActivationLifecycle` | Discovery, delayed commit, active gesture and replacement ownership |
| `HintSession` | Hint/search/pointer interaction state and reset; the mouse grid's pure `MouseGrid.Navigation` (display, step and undo history), key shape and drag anchor; the session's capture path and latency probe |
| `KeyboardLayoutMonitor` | `[app] keyboard_layout`'s reference table, rebuilt on input-source changes and config loads |
| `CandidateFinderSession` | Catalog, query, source context and selection for one finder session |
| `CandidateLiveQuery` | Generation-scoped live results, separate from warmed catalog rows |
| `ActionDispatcher` | Host mouse synthesis and completion of every owned gesture; the one held mouse button (`mouse_button`, pointer mode's `v`) and smooth-scroll steps |
| `PluginManager` / `PluginProcess` | Manifest reconciliation, owned child generations, transport and RPC |
| `FlashStatusBarController` | Evaluation of the bar and every desktop widget, each memoized on the inputs it read; reconciled source/job records for their union and the next necessary wakeup |
| `WidgetController` / `WidgetWindow` | One click-through desktop-level window per enabled widget per display, placed in the Flash-usable frame; occlusion reported back so a covered widget stops refreshing |

An asynchronous operation captures an ownership token before dispatch. Completion
must validate that token before mutating shared state, and again after additional
asynchronous preparation. Cancellation invalidates ownership before cancelling
resources. Resource completion and permission to apply an outcome are distinct:
an obsolete gesture must still post its mouse-up even though its outcome is ignored.

## Hint activation

Discovery captures focused-app context and a generation. Provider ordering is
priority descending, with stable identity tie-breaking. A provider may fall through
on empty output only when its policy explicitly permits it; sources are not merged.
Accessibility is the universal provider; tmux is the volatile terminal provider and
vscode is the bundle-scoped AX-enhancer provider (`hints` with `fallback_on_empty`).

Tmux keeps its window catalog and status segments warm from tmux's own
control-mode notifications, through one output-free control client per local
server a user's client is attached to, never from a timer
([plugin performance](plugin-performance.md)).

Tmux discovers pane anchors and every identified link in the visible pane grids;
there is no per-pane link cap. Its executable is resolved once, including mise
shims, so version-manager startup never consumes each hint query's deadline.
Client metadata and pane geometry are queried concurrently and must agree on the
server, session and window identity. Single-row, mouse-enabled status bars also
receive window-tab hints when their expanded format exposes numeric
`range=window|N` or `range=user|N` spans in a left-aligned row. These indices are
bound to live window IDs before publication. Scrolling lists, other alignments,
overflow and multi-row status layouts omit tab hints; pane and link hints remain
available. Tab selection uses the same host mouse-click path as pane selection.

Prepared models contain a complete finalized target set and assigned labels.
Reads require matching PID, dirty token, configuration revision and freshness.
AX notifications, focus, Space, display and configuration changes invalidate them.
Stale completed walks are discarded. Walks are never served as partial captures;
an activation miss obtains a complete walk. Model refresh timers have independent
ownership so a cancelled timer cannot consume a later request for the same PID.

AX event storms and slow speculative walks suspend background warming while
leaving explicit activation available. A degenerate background walk of an app
that has shown a healthy tree is owed a readiness re-walk, which neither
suspension withholds; an app whose volatile provider owns its hints and whose
own tree keeps walking empty stops being warmed at all (see
[prepared hint models](prepared-model.md)). Maintenance refreshes run before the
freshness ceiling and do not inherit the longer noisy-AX throttle. The active
window border has its own event-driven lifecycle and bounded recovery checks;
it does not poll continuously or retain a frame when the focused window disappears.
A move or resize names the window that changed, so its frame comes from one AX
read on that element and is applied with no settle tick — the border rides a
drag rather than trailing a WindowServer scan. Only events that change which
window is on top fall back to a window-list pass and schedule bounded recovery
checks. Those events update the border whenever they come from the active app,
judged by identity: a closed or minimized window leaves its app active with
another app's window on top, so matching the event against the window list
dropped it and left the stroke on a window that was gone. An app focused while
still launching refuses AX registrations (`kAXErrorCannotComplete`); they are
retried on a bounded ladder, or the app would stay unobserved for its life.

Overlay states that exclude one another are one value, never parallel flags.
The overlay owns the border's drawn frame and derives its stroke from the badge
style the status-bar pill is painted from, re-stroking when that style changes,
so the border and the pill cannot show different modes. A hint session's phase
(typing labels, searching, adjusting, steering the pointer) is one enum; the
overlay's key route is its projection, pushed on every session change together
with the border's visibility, which is hidden for the whole session. A toast is
its own layer above everything else: it never recycles hint chips or closes the
command line, and its expiry removes only itself. One resident runs per user; a
second one finds the resident lock held and exits.

What genuinely cannot be driven by an event goes through `PollScheduler`, the
one periodic clock in the process — there is no second timer. Core watchers and
plugins register there instead of arming their own, so twenty pollers cost one
wake-up rather than twenty; deadlines snap to a multiple of each interval so
clients sharing a period also share a tick, a client whose previous run has not
returned is skipped rather than queued, and the timer stops entirely when
nothing is registered. A registration is either a fixed cadence (`register`) or
a one-shot deadline (`scheduleOnce`), which is how a client whose wake-ups are
irregular still rides the shared clock: the status controller re-registers its
next deadline — the earliest of the user's per-source intervals, cycle
rotations, each status surface's clock and pending output — each time one
lands, for the bar and desktop widgets alike. `PollDeadline` wraps one
re-armable deadline for a queue-confined owner: a trailing debounce re-arms it
per event, a backoff per attempt, and a fire already on its way is dropped once
it is re-armed or cancelled. Plugins register over the wire with `poll` —
cadences and deadlines, each at its own priority — and are ticked with a
`core:poll:<name>` event.

Everything that re-arms itself rides the clock: prepared-model debounce,
readiness and maintenance wakes, the activation readiness ladder, the yank's
pasteboard wait, AX observer registration retries, plugin and popup restart
backoffs, the config, plugin-file, plugin-state, application-directory and
ambient-location debounces, the network and volume change coalescers, the
catalog notify throttle, the inspector's publish window and a covered widget's
grace. A plain one-shot `asyncAfter` remains only where no clock is involved:
a timeout bounding one operation (request and perform deadlines, the kill
escalation of a stopped child, the first-paint budget, a focus hand-off), the
fixed timing of an interaction in progress (synthesized key, scroll and click
spacing, sequence and hover-dwell timeouts, recapture and caret re-arm turns,
toast and click-feedback expiry, a popup's first frame, terminal frame pacing)
and a bounded fan-out of settle passes after one event (screen-change
recovery, window-border reconciliation, the Accessibility-grant re-check).
`Scripts/check-guardrails.sh` rejects any other timer source, and blocking
sleeps outside the three single operations it names.

Nothing a poll produces can be seen while the displays sleep, the session is
switched out, the login window (a locked screen) or screen saver is in front,
or the system is going to sleep, so the scheduler holds every registration —
plugin cadences, status jobs and clocks, the clipboard watcher — while any of
those holds (`PollScheduler.Gate`, fed by the same workspace notifications
that hide the window border). Registrations keep changing while held; the
last release runs each one that fell due meanwhile exactly once, then
repeating ones return to their grid. The scheduler's clock counts time spent
asleep (`CLOCK_MONOTONIC`), so a wake finds those deadlines overdue rather than
each waiting out its interval again. Clients never check the gate themselves.

Each registration carries a priority — there is no default — which sets how
much slack its wake-up allows: `system` (5 ms) for input-adjacent probes whose
lateness is visible, `high` (25 ms) for a value on screen that the user
watches change, `normal` (100 ms) for ordinary sampling, settles and
refreshes, `low` (1 s) for background upkeep, remote pulls, retries and
backoffs. Generous slack is what lets the kernel slide a tick onto an
interrupt it was already taking, and the tightest priority riding a wake-up
sets it, so a lax client can never loosen a demanding one. Plugins choose
among `high`, `normal` and `low`; `system` is core-only.

| Owner · registration | Cadence or deadline | Priority | Why |
| --- | --- | --- | --- |
| Status controller · `core:status_bar` | Next clock boundary or carousel rotation | high | The change on screen is the deadline |
| Status controller · `core:status_bar` | Job or source re-run, placeholder, throttled publish | normal | Output lands when the command ends; tightened to high when a clock deadline falls inside its slack |
| Menu-bar reveal probe · `core:menu_bar_reveal` | 80 ms while the pointer is in the band | system | Lowering the bar late hides the native menu |
| Activation repair · `core:activation_repair:<n>` | Readiness ladder 50–750 ms, or one 150 ms retry | system | The user is waiting on the hints |
| Yank · `core:pasteboard_wait:<n>` | 15 ms probes, at most 20 | system | The yank waits on each probe |
| Popup restart · `core:popup_restart:<id>` | 0.1 s first step, then 1–30 s | high, then low | A quit popup is on screen; a crash loop is not |
| Prepared model · `core:prepared_model_refresh:<pid>`, `…_readiness:<pid>` | 80 ms debounce; readiness ladder | normal | Warms a model ahead of an activation nobody asked for yet |
| Prepared model · `core:prepared_model_maintenance` | Before the 1.5–30 s freshness ceiling | normal | Slack stays inside the 250 ms lead |
| Clipboard watcher · `core:clipboard` | 0.5 s while a plugin subscribes | normal | No pasteboard notification; a late copy reaches history late |
| AX observer retry · `core:ax_observer_retry:<pid>` | 60 ms–3 s ladder | normal | Events go unobserved until it lands |
| Debounces · `core:config_reload`, `core:plugin_state_refresh`, `core:app_directories`, `core:ambient_location`, `core:plugin_reload:<id>:<n>` | 100–750 ms after the last event | normal | Someone is about to look, nobody is watching the instant |
| Change coalescers · `core:network_changed`, `core:volumes_changed` | 500 ms window | normal | Plugins re-read what changed |
| Catalog notify · `core:catalog_notify:<id>` | At most once a second | normal | An open flashlight re-reads the store on it |
| Inspector publish · `core:inspector_publish:<id>` | 100 ms window while a stream is open | normal | A diagnostic page |
| Plugin restart · `core:plugin_restart:<id>:<n>` | 1–30 s backoff | low | Catalogs survive a restart |
| Liveness sweep · `core:plugin_liveness` | 30 s while a plugin runs | low | Background upkeep |
| Covered widget · `core:widget_hidden:<name>` | 30 s grace | low | Nobody can see a covered widget |
| Plugin cadences and deadlines · `plugin:<id>:<name>` | Plugin-chosen | Plugin-chosen: high, normal or low | See the [status plugins](status-plugins.md#scheduling) table |

Registrations are also scoped to when they can observe anything at all: the
pasteboard watcher runs only while a plugin subscribes to `clipboard.changed`,
and the menu-bar reveal probe only while the pointer is in the band. Main-thread
stalls need no poll at all: the run loop reports each busy stretch itself, and
the HTTP inspector pushes its state on the changes it shows.

Visible regions subtract every higher window from the active one, except fully
transparent windows. The frontmost app's window can sit under another app's
normal-level window only while the window list lags an activation, so when that
leaves it fully covered the regions are recomputed without those windows
(`[discover] frontmost_window_covered`); floating layers still cover it. A walk
that leaves the window no visible region is never cached as a prepared model
(see [prepared models](prepared-model.md#windows-that-are-covered)). An
activation result that is empty, or collapsed below a tenth of the app's last
trusted count, is degenerate, and a cached model judged the same way is a miss.
A degenerate activation walk is walked once more and the fuller result is
served. An app that builds its tree on demand is re-walked after 150 ms. A
runtime that builds it asynchronously (Chromium, Flutter, Gecko) climbs a
readiness ladder instead: after 50, 100, 200 and 400 ms a bounded probe
(`AccessibilityReadiness`: a web area with content, or more than a
decorated window) decides whether the tree is there, and the one extra walk
runs as soon as it is, or after a final 750 ms. The waits are `system`
deadlines on the shared clock, never sleeps, and the activation going away
ends the climb.
When a volatile provider (tmux) declined and the app's own tree has never
produced targets, the empty walk is the answer and is not repeated. Empty
endings stay silent in the UI and are logged (`[latency] hints_empty`).

The core reasons about an app's traits, read once from its bundle
(`AppTraits`), never about its name: a web browser declares the `http` and
`https` URL schemes; Gecko ships `Contents/MacOS/XUL`; Chromium (browsers,
Electron and CEF apps) ships renderer helper apps, and a browser's installed
web app (PWA) is a shim whose executable is `app_mode_loader` or whose
Info.plist carries `CrAppModeShortcutID`; Flutter ships
`FlutterMacOS.framework`. App-specific knowledge — shortcuts, which apps are
terminal emulators — is plugin data. Browser pages keep a Vimium-style
semantic allowlist. Inside any other app's web view, a control-sized `AXGroup`
or `AXListItem` with a press action is a target too — the cards and rows those
apps build from clickable divs. Chromium and Flutter build their accessibility
tree only after an assistive client sets the enhanced-UI flags, so Flash sets
them at launch, on each focus change (the focus walk then waits for the
readiness probe) and on each walk; every other app builds its tree on demand
and never gets them.

Gecko turns its accessibility mode on when its tree is read; while the mode is
on, programmatic window moves become a slow, often incomplete animation, and
switching it off discards the tree, which the next read finds empty while it
is rebuilt. `GeckoAccessibility` owns the mode for every Flash AX client, under
one lock per process, and records which processes have it on because Flash
turned it on. That mode stays on after a walk, probe or commit while the app
is focused, so the next one reads a built tree. It is switched off, away from
the main thread, when another app is activated, on a Space change, and when
the monitor stops (at quit, which waits for it, bounded); it is forgotten when
the app quits; and `withWindowManagement` switches it off immediately before
every window geometry write, lingering or not, until the next tree operation
turns it on again. Without focus reports nothing lingers. A mode another assistive
client turned on (VoiceOver) is never switched off. A third-party window
manager moving a focused Gecko window meets the same flag Flash already leaves
on in every Chromium app, and VoiceOver in every app.

Inside UIKit content (the `iOSContentGroup` a Mac Catalyst or iPad app's
window hosts, as in Messages and WhatsApp), each conversation row or message
is one leaf `AXStaticText`, and every element there carries a press action; a
control-sized leaf is a target, ranked like a generic container. A text-input
role there enters INSERT only when its focus is settable, which excludes
read-only message bubbles.

Finalization rejects invalid geometry, filters visible regions and deduplicates
overlap with smaller frames winning, except that a semantic control always beats
a generic pressable container or UIKit text cell over the same area, and a
typing surface beats a same-size control laid over it (WhatsApp's search
field). Visual rows anchor their vertical tolerance to the row's topmost
target, then sort horizontally with stable tie-breakers.
A pairwise “within eight pixels” comparator is not transitive and must not be
used as a sorting predicate.

See [prepared hint models](prepared-model.md) for scheduling priorities,
maintenance deadlines and suppression thresholds.

Activation progresses through `idle`, `discovering`, `pendingCommit`, and
`committing`. Discovery and a not-yet-started commit may be replaced immediately.
An active gesture retains ownership until release; the latest replacement waits
behind it. Old completions neither clear a newer activation nor apply stale mode
or navigation effects. Pointer-session reset consumes a held-button release once.
Shutdown lets already-started finite mouse synthesis finish.

Hints retain the target captured by discovery. Before a commit, AX targets
re-read the retained element's identity, properties and geometry; scrolling can
move the click with that element, while a replaced, hidden or changed control
cancels the selection. The final hit must still belong to that element. Dock
items and scroll containers retain the same AX identity; native menu-bar items
retain their owner PID and WindowServer window ID as their positions change.
Plugin targets use a bounded fresh `hints` request and require one matching role,
label, URL and optional source `context_id` in the same captured application
window. Tmux supplies backend, client, server-lifetime, session, window and pane
identity, so another server's `%1` cannot replace the selected pane. Missing or
ambiguous matches cancel instead of falling back to the old coordinates.
Resolution runs off the main loop and its result belongs to the activation
generation. Configuration changes cancel existing hints before changing layout
or actions.

Every click sends a mouse-move event with the same modifiers before mouse-down
and mouse-up, even when the pointer is already at the target. Terminals use
this hover event to prepare their link action; Shift only on the button events
can arrive too late for Alacritty's cached link highlight.

Flash holds status-bar publications while status hints are visible and until a
selected host click finishes. A popup-only hint retains its captured content
and anchor until the pointer leaves it. The latest queued status model is then
applied. Live mode labels still bind to the current mode; a running terminal's
own output remains live. External targets still receive a real host mouse
event: Flash cannot freeze another application's state atomically with its
click, or distinguish objects that expose identical reused AX/plugin data.

## Coordinates and rendering

Targets use global NSScreen coordinates: primary-screen bottom-left origin,
positive Y upward. Accessibility and CGEvent use the primary-screen top-left
origin, positive Y downward. Convert with the primary screen's height, never the
maximum screen extent. Screen unions start at `CGRect.null`, preserving negative
origins on displays to the left or below the primary display.

All overlay layer mutations disable implicit Core Animation actions. Add new
animated properties to `OverlayPanel.noActions` as well as using disabled-action
transactions. An empty discovery result stays silent.

The persistent status bar draws in its own click-through `StatusBarWindow`,
which shares the overlay panel's union-of-screens frame and hosts only the bar
layers. It is ordered above the native menu bar and its extras, so a reveal
Flash did not ask for (a menu key equivalent flashing its title, Flash becoming
active, a wake) slides those windows in behind the bar instead of painting over
it for a second. The pointer is the exception: while the reveal probe sees the
native menu bar actually revealed under the pointer, the bar window drops below
it and the click windows turn click-through, so reaching for the top edge still
gets the real menu bar and its clicks. Hover goes with it: `StatusBarHoverState`
silences the wash, previews and pointing hand for as long as the reveal lasts,
and only then; the top point row, where a pointer thrown at the bar rests,
hovers like the rest of the band. Enabling the bar also asks macOS to
auto-hide the native menu bar, and disabling it restores only a menu bar Flash
itself hid. The overlay panel keeps the focus border at `.floating` and
transient surfaces at the screen-saver level, so status hints still render
above the bar and transient teardown never detaches it.

On each display the bar is as tall as that display's own native menu bar, read
by level and bounds from WindowServer's main-menu window, and `window_move`
slots reserve the same band: both take it from one screen snapshot
(`ScreenSnapshot.statusBarHeight`), never from a live visible frame, which
moves as soon as Flash auto-hides the native menu bar. The click windows cover
exactly the painted bands, and the focus border outlines a window only below
any band it runs under, so its stroke is never drawn beneath the bar.
AppKit's app-wide `menuBarHeight` follows whichever
display last hosted the active menu bar, so it is only the last resort. The
heights are re-read on display changes and before every recovery pass after
one, never on a Space switch or wake, so a restored window lands exactly where
the next `window_move` would put it. Restores and moves accept a placement only
within a point of its slot; the two-point tolerance recognises slots, it does
not accept placements. Accessibility cannot read or move windows while the
session is locked or asleep, which is when a wake reports new displays, so
restores wait for the session: a window counts as restored only once its frame
was read back in its slot, and one whose frame was unreadable stays pending
until the session resumes or the window is focused.

The overlay's AppKit-owned content view contains a layer-hosting drawing view
and the native command editor as siblings. Flash replaces only the drawing
view's `contentLayer.sublayers`; replacing the native container's sublayers
detaches AppKit's editor backing layers during transient cleanup. The drawing
view has no native subviews and resizes with the panel. This follows AppKit's
[layer-hosting ownership contract](https://developer.apple.com/documentation/appkit/nsview/wantslayer).

Mode projection describes render/input state without changing mode as a drawing
side effect. Reentrant effects enqueue events behind the current transition.
Transient surfaces preserve their return state and obey advanced-mode eligibility.
See [normal mode](normal-mode.md) for the input latency and transition contracts.

## Other lifecycles

The finder warms catalog snapshots independently of query-specific work. A live
search result belongs to its session, query generation and source; a timeout or
late preparation from an older query cannot replace current rows. Rendering a
new query starts from the catalog plus only the current live result set.

Waiting for a child process always ends on its kernel exit event
(`ProcessExit`, a `kqueue` `NOTE_EXIT` or a process dispatch source), never a
sleep loop: plugin stops, status-job shutdown and deferred terminal reaping
return the moment the process is gone, and deadlines only bound one that is
not. Status jobs retain their running process and value when effective definitions
are unchanged. Replacements invalidate tokens before stopping children in one
bounded batch. The scheduler arms only evaluated jobs, active cycles, the
next boundary of the finest time unit a visible surface shows, and pending
output publication. Inactive shell jobs and their output
are discarded; inactive named sources retain last-good values without wakeups.
See [status formats](status-format.md) and [popup ownership](popups.md#internals).

Plugin manifests are immutable runtime definitions. A changed manifest replaces
its process/adapter registration; a settings-only update reconciles the existing
definition. Host RPC replies are tied to the child generation that issued them.
Transport queues, encoded payloads and request admission are bounded. Details,
limits and the conformance suite live in the
[protocol](plugin-protocol.md) and [Rust SDK](plugin-rust-sdk.md) documents.
