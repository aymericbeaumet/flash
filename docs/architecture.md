# Runtime ownership and determinism

Flash is one resident macOS application. Its executable also implements the CLI:
arguments invoke a verb by custom AppleEvent (`Flsh` / `Cmd `); no arguments start
the resident. Configured mappings resolve through the same command definitions
and dispatch in-process. Other mapping executables receive an argv array.

## Boundaries

| Owner | Responsibility |
| --- | --- |
| `FlashCore` | Source/evaluator protocols, immutable target/candidate values, visible-region finalization |
| `FlashProviders` | Accessibility discovery, never target activation |
| `AppMonitor` | Focus observation, provider selection, complete prepared models and refresh scheduling |
| `ModeStore` / `ModeReducer` | Serialized mode transitions and ordered effects |
| `ActivationLifecycle` | Discovery, delayed commit, active gesture and replacement ownership |
| `HintSession` | Hint/search/grid/pointer interaction state and reset |
| `CandidateFinderSession` | Catalog, query, source context and selection for one finder session |
| `CandidateLiveQuery` | Generation-scoped live results, separate from warmed catalog rows |
| `ActionDispatcher` | Host mouse synthesis and completion of every owned gesture |
| `PluginManager` / `PluginProcess` | Manifest reconciliation, owned child generations, transport and RPC |
| `FlashStatusBarController` | Reconciled source/job records and the next necessary wakeup |

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

Prepared models contain a complete finalized target set and assigned labels.
Reads require matching PID, dirty token, configuration revision and freshness.
AX notifications, focus, Space, display and configuration changes invalidate them.
Stale completed walks are discarded. Walks are never served as partial captures;
an activation miss obtains a complete walk. Model refresh timers have independent
ownership so a cancelled timer cannot consume a later request for the same PID.

AX event storms and slow speculative walks suspend background warming while
leaving explicit activation available. Maintenance refreshes run before the
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

What genuinely cannot be driven by an event goes through `PollScheduler`, the
one periodic clock in the process — there is no second timer. Core watchers and
plugins register there instead of arming their own, so twenty pollers cost one
wake-up rather than twenty; deadlines snap to a multiple of each interval so
clients sharing a period also share a tick, a client whose previous run has not
returned is skipped rather than queued, and the timer stops entirely when
nothing is registered. A registration is either a fixed cadence or a one-shot
deadline, which is how a client whose wake-ups are irregular still rides the
shared clock: the status bar re-registers its next deadline — the earliest of
the user's per-source intervals, cycle rotations and pending output — each time
one lands. Plugins register over the wire with `poll` and are ticked with a
`core:poll:<name>` event.

Each registration carries a priority, which sets how much slack its wake-up
allows: `system` for input-adjacent probes whose lateness is visible, `high`
for surfaces on screen, `normal` for ordinary sampling, `low` for background
upkeep. Generous slack is what lets the kernel slide a tick onto an interrupt
it was already taking, and the tightest priority riding a wake-up sets it, so a
lax client can never loosen a demanding one. Registrations are also scoped to
when they can observe anything at all: the pasteboard watcher runs only while a
plugin subscribes to `clipboard.changed`, the menu-bar reveal probe only while
the pointer is in the band, the watchdog only while its level is logged, and
the inspector broadcast only while a browser is listening.

Finalization rejects invalid geometry, filters visible regions and deduplicates
overlap with smaller frames winning. Visual rows anchor their vertical tolerance
to the row's topmost target, then sort horizontally with stable tie-breakers.
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
gets the real menu bar and its clicks. Enabling the bar also asks macOS to
auto-hide the native menu bar, and disabling it restores only a menu bar Flash
itself hid. The overlay panel keeps the focus border at `.floating` and
transient surfaces at the screen-saver level, so status hints still render above
the bar and transient teardown never detaches it.

On each display the bar is as tall as that display's own native menu bar, read
by level and bounds from WindowServer's main-menu window, and `window_move`
slots reserve the same band. AppKit's app-wide `menuBarHeight` follows whichever
display last hosted the active menu bar, so it is only the last resort. The
heights are re-read on display changes and before every recovery pass after
one, never on a Space switch or wake, so a restored window lands exactly where
the next `window_move` would put it. Restores and moves accept a placement only
within a point of its slot; the two-point tolerance recognises slots, it does
not accept placements.

Mode projection describes render/input state without changing mode as a drawing
side effect. Reentrant effects enqueue events behind the current transition.
Transient surfaces preserve their return state and obey advanced-mode eligibility.
See [normal mode](normal-mode.md) for the input latency and transition contracts.

## Other lifecycles

The finder warms catalog snapshots independently of query-specific work. A live
search result belongs to its session, query generation and source; a timeout or
late preparation from an older query cannot replace current rows. Rendering a
new query starts from the catalog plus only the current live result set.

Status jobs retain their running process and value when effective definitions
are unchanged. Replacements invalidate tokens before stopping children in one
bounded batch. The scheduler arms only evaluated jobs, active cycles, clock
expansion and pending output publication. Inactive shell jobs and their output
are discarded; inactive named sources retain last-good values without wakeups.
See [status formats](status-format.md) and [terminal ownership](terminal-popups.md).

Plugin manifests are immutable runtime definitions. A changed manifest replaces
its process/adapter registration; a settings-only update reconciles the existing
definition. Host RPC replies are tied to the child generation that issued them.
Transport queues, encoded payloads and request admission are bounded. Details,
limits and the conformance suite live in the
[protocol](plugin-protocol.md) and [Rust SDK](plugin-rust-sdk.md) documents.
