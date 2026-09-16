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
