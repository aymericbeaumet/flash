# Runtime ownership and determinism

Flash is one resident macOS application. Its executable also implements the CLI:
arguments are the words typed after `:` in the command line, sent with the
shell's directory as a `request` over the resident's Unix domain socket
(`IPCServer`, [IPC protocol](ipc-protocol.md)); no arguments start the
resident. The resident resolves them with the command line's resolver and
inventory and runs them through its one runner (`AppDelegate.runInvocation`),
then replies with the result as JSON: output, status (the CLI's exit code)
and message. `flash config check` spelled out never leaves the CLI, and an
abbreviated one comes back from the resident to run there; `flash events
watch` subscribes on the same connection. With no resident running, the CLI
opens the app bundle it lives in through Launch Services and waits for the
socket (`ResidentConnector`). Configured mappings resolve exact words through
the same command definitions and dispatch in-process. Other mapping
executables receive an argv array.

## What starts at launch

Configuration owns the surfaces: a hotkey registers only the chord it names
(`ShortcutsCoordinator`), the status bar, widgets, monitors and their polling
exist only with `[statusbar] enabled`, a `[widgets.<name>]` table or an enabled
`[monitors.<name>]` (the bundled file declares five), a popup's PTY starts
on its first showing, the inspector listens only on demand or with
`[debug] http_inspector_enabled`, the [OTLP receiver](telemetry.md) only
with `[telemetry.receiver] enabled` and the exporter only with an
`[telemetry.exporter] endpoint`, `[startup] run`'s commands run once after
the first configuration load and only when it lists some, and CoreAudio is
touched per request. A
plugin whose manifest declares only `status` runs while a visible surface
reads one of its segments; a plugin with only commands starts on its first
`perform`; a manifest without `exec` never spawns. A mapping that runs a
plugin command asks for that plugin: ten seconds after each reconcile it is
spawned if still idle, and it outlives its status surfaces
([warm plugins](plugin-performance.md#process-creation-and-warm-plugins)).

The rest starts with the process, whatever the configuration says:

| Component | Why it is eager | Cost |
| --- | --- | --- |
| `AppMonitor` AX observer and prepared model for the focused app | Hints must show without a walk on the key path (see the prepared-model guide) | One AXObserver per focused app, a complete walk per focus change, maintenance walks while the user is active |
| `KeyboardCaptureTap` | The swallow decision must exist before the first mapped key; the no-tap fallback is slower | A session tap on main, plus the 2 s secure-input probe |
| `IPCServer` socket | `flash <command>` and scripts must reach the resident without starting anything | One Unix domain socket and an accept source, idle until a client connects; no timer |
| Resident plugins: every manifest with `sources`, `query` or `hints`, or with `listen` and no `status`; a status plugin while a surface shows its segments | Catalogs and hint providers are kept warm so the flashlight and terminal hints are complete on first open | One child process each (eight bundled plugins by default, plus each status plugin a surface shows), three queues and a root-directory watcher per plugin, `core:ax.changed` fan-out to the listeners |
| Dock view observer (`SystemSurfaceController`) | `missioncontrol hide` must know a view that opened before it ran, which only an observer installed before that has seen; `f` labels Mission Control and NORMAL lets its unmapped keys reach the Dock from the same reports | One AXObserver on the Dock for four notifications it posts only as Mission Control, App Exposé or Show Desktop opens or closes |
| Window navigation catalog (`WindowMover`) | Directional focus reads a prepared catalog rather than walking on the key path | `kAXWindows` per regular app at launch and on app launch/terminate |
| Window switcher catalog (`WindowSwitcherCatalog`) | `window switch` draws from memory within a frame of its chord | `kAXWindows` plus one batched read per window, per regular app at launch and on each Space change; one app again after its window events settle (250 ms) or when an unknown window of it gains focus; app names and icons once per app |
| Clipboard, network, volume and power monitors | A bundled manifest listens for them | A 500 ms pasteboard poll, one SCDynamicStore session, notification observers |
| `ApplicationSource`, frecency and command history | Flashlight catalogs and ranking | An installed-apps scan with kqueue watchers, two files read on main |
| `AppleCatalogs` (Notes, Reminders, Contacts) | A scoped query reads the last good rows from memory, never the app | One listing per running app Flash may already read, at launch and on that app's launch, its loss of focus and a flashlight open once a minute; nothing before access is granted |
| Built-in monitors (`battery`, `disk`, `memory`, `plugin_errors`, `plugin_spawn`) | A full disk, a low battery or a crash-looping plugin should alert without configuration | The status controller; the `sysinfo` plugin's power domain (event-driven) and disks domain (a 3 s I/O sample) the battery and disk monitors observe; one `sysctl` a minute for memory pressure. `enabled = false` drops each |

Making the resident plugins and the window catalog configuration-driven (spawn
a catalog plugin on the first flashlight open from its persisted catalog, a
scoped plugin when a matching app is focused, a listener only while its host
monitor has a running consumer) is the planned next step; each item trades
first-use latency for idle cost and is listed with its risk in the launch
inventory of the resumption notes. Until then the README claims only what the
table above supports.

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
| `AppleCatalogs` / `AppleCatalogSource` | `@notes`, `@reminders`, `@contacts`: last good rows, the running-app gate, event-driven relists on one serial queue per catalog, and macOS access asked only when a query or a refresh command uses the catalog |
| `CalendarEvents` | `#{flash.calendar.next…}`, `calendar join` and `calendar next`: EventKit reads on one serial queue while the status controller reports a surface reading a value (and for each command), re-read on `EKEventStoreChanged` and once a look-ahead has passed, published for the controller, which computes the values at the instant it shows them and wakes when they change; macOS access asked only by that use |
| `AppleScriptRunner` | The resident's AppleScript, in process: one serialized OSA lifetime from component open through compile, execute, display, disposal, close and autorelease-pool drain. At most eight background workers wait or run; admission and Apple Events share the caller's deadline. Results must arrive before that deadline, even if a late semaphore signal is already buffered when the caller resumes. A timed-out caller never releases a component that is still alive; callers stay off main |
| `ClipboardHistoryStore` / `ClipboardFlashlight` | Clipboard history on one serial queue (pins never trimmed, image sizes read from file headers); its listing, published after every change, becomes `!clip`/`@clipboard` rows prepared once per entry on the flashlight catalog's queue, so a query reads them from memory; register rows are built on main when pulled |
| `FileSearchSource` / `SpotlightNameSearch` | `!f` and `@files`: one in-process Spotlight name query at a time on its own run-loop thread, superseded by the next request, stopped at 200 results or the live-query deadline |
| `SystemSurfaceController` | `desktop`, `missioncontrol`, `appwindows`, `launchpad`, `notificationcenter`, `controlcenter` and the gestures and Hyper+3 that toggle them: one serial queue running one request at a time, the Dock's view from its own reports, the only `CoreDockSendNotification` caller |
| `WindowSwitcherCatalog` | Window recency from focus events and every regular app's windows, read on the window-navigation build queue; `window switch` draws them as a hint-session phase and raises its choice on the window layout AX queue |
| `ActionDispatcher` | Host mouse synthesis and completion of every owned gesture; the one held mouse button behind HOLD (`mouse button`, pointer mode's `v`) and smooth-scroll steps |
| `PluginManager` / `PluginProcess` | Manifest reconciliation, owned child generations, transport and RPC |
| `FlashStatusBarController` | Evaluation of the bar, every desktop widget and every monitor, each memoized on the inputs it read; reconciled source/job records for their union, kernel-value reads and the next necessary wakeup |
| `MonitorTracker` | One monitor's pure alert state machine: `unknown`/`ok`/`warning`/`error`, an alert only on a rise, a per-level cooldown; the controller hands its alerts to `StatusAlert` on main |
| `WidgetController` / `WidgetWindow` | One click-through desktop-level window per enabled widget per display, placed in the Flash-usable frame; occlusion reported back so a covered widget stops refreshing |
| `IPCServer` / `IPCEventHub` | The resident's Unix domain socket: the CLI's requests into `runInvocation`, and the host events its subscribers asked for ([IPC protocol](ipc-protocol.md)) |
| `IPCClient` / `ResidentConnector` | The CLI's end: connect, start the bundle through Launch Services when no resident runs, wait for the socket on a directory kqueue |
| `DebugServer` | The help and inspector HTTP server: one loopback listener, on demand or with `[debug] http_inspector_enabled` |
| `OTLPReceiver` / `TelemetryStore` | The one other listener besides the socket: opt-in OTLP/HTTP bound to 127.0.0.1, decoding off main into bounded in-memory series, log records and spans that `#{flash.otel…}` values and the telemetry page read ([telemetry](telemetry.md)) |
| `UpdateController` | `[app] updates` and the `updates` commands: the GitHub release check, the download verified against GitHub's SHA-256 digest and the bundle's code signature, the staged bundle under `Updates/`, and the one `RENAME_SWAP` that installs it, on its own serial queue; the resident relaunches into a process that waits for the resident lock ([updates](updates.md)) |
| `StartupRunner` | [`[startup] run`](config:startup.run): once per launch after the first configuration load, and on `startup run`; its commands in order on its own serial queue, each through the monitors' executor (`MonitorProcess`, or a Flash command on main), the next one even after a failure, one run at a time ([startup commands](startup.md)) |
| `TelemetryRecorder` / `TelemetryExporter` | Flash's own metrics, logs and spans (`FlashTelemetry`), aggregated under one lock and sent to the configured OTLP/HTTP endpoint from the exporter's queue |

An asynchronous operation captures an ownership token before dispatch. Completion
must validate that token before mutating shared state, and again after additional
asynchronous preparation. Cancellation invalidates ownership before cancelling
resources. Resource completion and permission to apply an outcome are distinct:
an obsolete gesture must still post its mouse-up even though its outcome is ignored.
Ownership is a lifetime, not a PID or reused object: prepared-model walks carry
rebuild tickets, queued AX events retain revocable observer contexts, host RPC
queue hops carry the requesting child transport's scope, and terminal
publications carry their process generation. Validate before consuming a waiter,
changing host state or notifying a subscriber. Within one terminal run, a queued
frame must also be at least as new as the snapshot already displayed.

## Trust boundaries

Flash holds Accessibility, a session keyboard tap and, through the
`screenshot` plugin, Screen Recording, so anything that can steer it borrows
those grants. [SECURITY.md](https://github.com/aymericbeaumet/flash/blob/main/SECURITY.md)
states the policy; this table is where each boundary is enforced. Code that
adds a listener, an opener or a new way for outside text to reach a command
joins it.

| Who | Reaches Flash through | Enforced by |
| --- | --- | --- |
| A program running as you | The IPC socket, `~/.config/flash`, the help token file | Nothing, by design: it already has your account |
| A sandboxed plugin | The IPC socket, which would run commands outside its sandbox | `PluginSandbox.residentSocketDeny`: every plugin and install profile denies connecting into the socket's directory, after every allow |
| Another account or a system daemon | The IPC socket and the loopback listeners | `IPCServer` refuses every peer whose `getpeereid` uid is not the resident's, in a `0700` directory it refuses when it is a link or another account's; `DebugServer` answers its data endpoints only with `HelpAccess`'s token, from a `0600` file it refuses to trust when it is not private; `OTLPReceiver` refuses senders without `[telemetry.receiver] token` once one is set, and `Doctor.telemetryReceiverCheck` warns when it runs without one while a monitor runs commands from a received metric (`Config.monitorsRunOnReceivedMetrics`) |
| A web page | The help server, via fetch, DNS rebinding or framing | The `Host` check (own host and port only), the cross-site change refusal, the access token, `Cross-Origin-Resource-Policy` and frame headers |
| A plugin | NDJSON stdio requests, its manifest | Capabilities and the seatbelt profile; `host.open` and row `open` effects never take a `file:` URL, so a plugin cannot have LaunchServices run what it wrote outside its sandbox |
| Text another app controls (titles, app names, AX values, clipboard, feeds, tmux output) | Status values, rows, popups, alerts | Values are escaped (`ProcessStatusFormat.escaped`) before they reach a format, so they never become a style, a range or a link; every `#[link]` a plugin, source or program did write leaves through the overlay's one `StatusLinkOpener`, which `StatusLinkPolicy` limits to `http`, `https`, `mailto` and `[statusbar] link_schemes` (a refusal logs the scheme alone and reaches `resident doctor`); terminal popups read only `http`/`https` hyperlinks, through the same opener, and ignore clipboard writes (OSC 52); concealed and transient pasteboard types never enter clipboard history |
| A network attacker | Update checks, feeds, plugin downloads | HTTPS, the GitHub digest and code-signature checks of `UpdateController`, full pinned commits for third-party plugins, bounded fetches |

Loopback is not a boundary: every account on the Mac shares it, so a
listener must authenticate its callers. Browser-only signals (`Origin`,
`Sec-Fetch-Site`) stop pages but not local clients. A listener also bounds
what an unauthenticated peer can hold: the help server closes a connection
that has not finished its request within 10 seconds and accepts at most 32
such connections at once. The IPC socket needs no token, because the kernel
names its peer: it holds at most 32 connections, closes one that has not
said `hello` within 5 seconds, and bounds each connection's line length,
requests in flight and unread events ([limits](ipc-protocol.md#limits-and-timeouts)).

## Hint activation

Discovery captures focused-app context and a generation. Provider ordering is
priority descending, with stable identity tie-breaking. A provider may fall through
on empty output only when its policy explicitly permits it; sources are not merged.
Accessibility is the universal provider; the terminals plugin is the volatile
terminal provider (tmux panes; `hints` with `fallback_on_empty`).

Tmux keeps its window catalog and status segments warm from tmux's own
control-mode notifications, through one output-free control client per local
server a user's client is attached to, never from a timer
([plugin performance](plugin-performance.md)). The same client carries the
plugin's local commands, so commands and hint captures never wait on an exec;
only a server without one gets a spawned client.

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
Letter search in a terminal with no accessibility text asks the same hint
providers for a `text_grid`: tmux answers with this same client grid,
including the status line and each pane-border title, from the same layout
read and captures, and the host lays it on the same window rectangle. The
request is asynchronous; its reply returns to the AX queue and is dropped
unless the search's generation is still current. `f` and `cf` label that
grid's panes, links, window tabs and pane titles; they also label the same
status-bar spans.

### Terminal snapshots

The terminals plugin captures only each visible pane's current grid with
`capture-pane -p -e`. It recognizes HTTP(S) OSC 8 links even when their labels
are ordinary words, preserves the destination separately from the label, and
keeps regex URL/path hints outside those spans. Wrapped OSC 8 labels yield one
target per visible row. SGR and OSC metadata never enter the text-search grid;
OSC 52 is ignored and no captured control sequence is executed. Captures are
bounded to 1 MiB per pane, retained link destinations to 1 MiB, control sequences
to 8 KiB and grid dimensions to 16,384 cells. Malformed controls, tabs whose cell
widths are unknown, ambiguous script ligatures and grids exceeding the captured
pane size reject the read. Unicode display-cell widths place wide and combining text.
Layout is read again after all panes: a changed server, session, window, pane
geometry or client grid cancels discovery. Commit repeats discovery off the
main thread and matches both the displayed label and actual destination.
Copy-mode panes and zoomed tmux windows decline discovery because the base
capture and ordinary pane layout do not describe their visible grid.

Alacritty geometry uses the attached tmux client's reported cell pixels and the
captured display scale. The supported window is undecorated
(`window.decorations = "None"`) with `window.dynamic_padding = true`; padding
is centered in physical pixels. Font metrics are not guessed. Configuration
reads are bounded to 256 KiB. A focused process's unambiguous absolute
`--config-file` path is honored; otherwise its ordinary launch uses Flash's
HOME default configuration search paths. Imports, ambiguous paths containing
spaces, unsupported launch overrides, alternate `XDG_CONFIG_HOME`, missing
cell metrics and unsupported window layouts decline Alacritty discovery.
Launching the GUI with a different unreported environment is outside this
default-HOME contract; use an explicit configuration path. Other terminals
retain their existing window/grid geometry. No terminal output stream is
monitored, and no scrollback history is captured.
Window title arguments are allowed; arguments after `-e`/`--command` belong to
the child command and are never interpreted as Alacritty configuration.

A walk resolves the window it covers once: the frame step keeps the focused
window element (`AppContext.walkedWindow`) and the walk starts there instead
of asking the app for its focused window again. Per node, the batched
attribute array is read in place by type id (`AXBatchValues`); strings are
bridged only for a node the role gate admits, and the extension-document
test is a scheme prefix check, not a `URL` parse. An activation reads the
window list once for the frontmost app's top window and the dialog covering
it. Label lists are memoized per layout and target count, and the overlay
keeps one attributed string per label, prefix length and accent.

Prepared models contain a complete finalized target set and assigned labels.
Reads require matching PID, dirty token, configuration revision, freshness and
the window's visible region.
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
it does not poll continuously or retain a frame when the focused window
disappears, and an activation's checks end at the first that finds the window
where the stroke already is.
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
(typing a search letter, typing labels, searching, adjusting, steering the pointer) is one enum; the
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
lands, for the bar, desktop widgets and monitors alike. `PollDeadline` wraps one
re-armable deadline for a queue-confined owner: a trailing debounce re-arms it
per event, a backoff per attempt, and a fire already on its way is dropped once
it is re-armed or cancelled. It releases only the registration it armed, so a
successor under the same id keeps its wake-up. Plugins register over the wire with `poll` —
cadences and deadlines, each at its own priority — and are ticked with a
`core:poll:<name>` event.

Flash listens on three sockets at most. The IPC socket (`IPCServer`) is a
Unix domain socket in `~/Library/Application Support/Flash/run/`, never a
TCP port, for the user's own processes only. The other two are bound to the
loopback address itself and check each request's `Host`: the help server
(`DebugServer`) and, when `[telemetry.receiver] enabled`, the OTLP/HTTP
receiver (`OTLPReceiver`, 127.0.0.1:4318 by default). Plugins talk NDJSON
over stdio; there is no other socket, Mach service, Apple Event handler or
URL scheme.

The IPC socket's I/O is event-driven on its own `.userInitiated` queue
(the CLI waits on it): one read source accepts, one per connection reads,
and a connection's write source runs only while the socket has not taken
everything it is owed. A request hops to main to run and its result hops
back; a subscription updates `IPCEventHub`, the main-thread mirror that
`emitHostEvent` and `hostEventHasSubscriber` consult, so with no subscriber
nothing is encoded and no OS source runs on a client's account. The hub
encodes an event once, numbers it, and hands it to the server for every
subscriber, whose bounded queue coalesces state signals and disconnects a
reader that still falls behind.

Everything that re-arms itself rides the clock: the update check (`core:updates`, `low`: a minute after launch, then daily), prepared-model debounce,
readiness and maintenance wakes, the activation readiness ladder, Mission
Control's readiness reads, a click chain's refresh after its app changed, the yank's
pasteboard wait, AX observer registration retries, plugin and popup restart
backoffs, the config, plugin-file, plugin-state, application-directory and
ambient-location debounces, the network and volume change coalescers, the
catalog notify throttle, the inspector's publish window, a covered widget's
grace, the latched hyper key, the window switcher's burst of window events,
a panel press's confirmation reads (`core:surface_confirm`), the telemetry
export flush and its retry backoff, and a received series going quiet. A plain one-shot `asyncAfter` remains only where no clock is involved:
a timeout bounding one operation (request and perform deadlines, the kill
escalation of a stopped child, the first-paint budget, a focus hand-off, the
OTLP receiver's per-connection request timeout, the IPC socket's handshake
deadline and its closing connection's grace, a system-surface command's
wait for the Dock's report, a monitor run's timeout and its kill
escalation, a startup command's backstop), the
fixed timing of an interaction in progress (synthesized key, scroll and click
spacing, sequence and hover-dwell timeouts, recapture and caret re-arm turns,
toast and click-feedback expiry, a popup's first frame, terminal frame pacing)
and a bounded fan-out of settle passes after one event (screen-change
recovery, window-border reconciliation, the Accessibility-grant re-check,
the held button's catch-up after a scroll in HOLD).
The guardrails (`mise run guardrails`) reject any other timer source, and blocking
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

Priority is only the wake-up's slack: the handler runs on the queue it was
registered with, at that queue's quality of service, and the clock itself
(`flash.poll`, `.userInitiated`) only plans and dispatches. A queue's QoS
follows who waits on it. Work a keypress, a plugin reply or a `system` or
`high` wake-up waits on runs `.userInitiated` — the plugin lifecycle, reader,
writer and deadline queues, the AX broker, the reveal probe, the process
table; `.utility` is for work nobody waits on — catalog decode, logs,
persistence, telemetry, materialization — and a serial queue never mixes the
two, because under CPU load the kernel starves utility-class threads first:
a `system` probe planned from one fired at 150–1,800 ms gaps, and the same
catalog decode took nine times longer. The guardrails reject a `system` or
`high` registration whose handler queue is `.utility`.

| Owner · registration | Cadence or deadline | Priority | Why |
| --- | --- | --- | --- |
| Status controller · `core:status_bar` | Next clock boundary or carousel rotation | high | The change on screen is the deadline |
| Status controller · `core:status_bar` | Job or source re-run, placeholder, throttled publish | normal | Output lands when the command ends; tightened to high when a clock deadline falls inside its slack |
| Status controller · `core:status_bar` | A job or source only monitors read; a kernel value (`flash.memory_pressure`) on the reading surfaces' interval | low (normal when the bar or a widget reads it) | Nobody watches a monitor's value land; a monitor never ticks the clock |
| Status controller · `core:status_bar` | The next change of a `#{flash.calendar.next…}` value: the countdown's next minute, an event starting, ending or leaving its first ten minutes | high (low when only monitors read one) | The change on screen is the deadline; a monitor's alert tolerates a second |
| Calendar · `core:calendar_changed` | 500 ms after `EKEventStoreChanged`, while a value is read | normal | A sync posts bursts of changes; one read follows |
| Calendar · `core:calendar_horizon` | One look-ahead after a read (5 min after a failed one), while a value is read | low | The look-ahead moving on brings in events hours away |
| Menu-bar reveal probe · `core:menu_bar_reveal` | 80 ms while the pointer is in the band | system | Lowering the bar late hides the native menu |
| Activation repair · `core:activation_repair:<n>` | Readiness ladder 50–750 ms, or one 150 ms retry | system | The user is waiting on the hints |
| Mission Control readiness · `core:mission_control_ready` | 50–400 ms steps, about 750 ms in all, while `f` waits on a Mission Control tree the Dock is still building | high | The user is looking at the view and waiting on its labels |
| Click chain refresh · `core:click_chain_refresh` | 120 ms after the chain's app last reported a change, while a `--multi` chain waits for its next pick | high | The labels on screen follow the change |
| Yank · `core:pasteboard_wait:<n>` | 15 ms probes, at most 20 | system | The yank waits on each probe |
| Popup restart · `core:popup_restart:<id>` | 0.1 s first step, then 1–30 s | high, then low | A quit popup is on screen; a crash loop is not |
| Prepared model · `core:prepared_model_refresh:<pid>`, `…_readiness:<pid>` | 80 ms debounce; readiness ladder | normal | Warms a model ahead of an activation nobody asked for yet |
| Prepared model · `core:prepared_model_maintenance` | Before the 1.5–30 s freshness ceiling | normal | Slack stays inside the 250 ms lead |
| Clipboard watcher · `core:clipboard` | 0.5 s for the life of the resident | normal | No pasteboard notification; a late copy reaches the core clipboard history late |
| Process tables · `core:process_top` | 2 s while a surface reads `flash.top_cpu` or `flash.top_mem` | high | A table someone has open |
| Focused-app figures · `core:process_focused` | 10 s while a surface reads `flash.focused_app_details` | normal | CPU has no change event; a tenth of a second is invisible at ten seconds |
| Focused-app settle · `core:process_focus_settle` | 300 ms after a focus change, while read | high | The placeholder on screen waits on it |
| Secure input · `core:secure-input` | 2 s for the life of the resident | low | The tap receives no keys while the flag is on, so this poll is what sees a stuck hold |
| Secure input release · `core:secure-input-fix` | 0.2–0.7 s steps of one release | normal | Spacing an activate, blur or restore already in progress |
| AX observer retry · `core:ax_observer_retry:<pid>` | 60 ms–3 s ladder | normal | Events go unobserved until it lands |
| Dock observer retry · `core:dock_observer_retry` | 60 ms–3 s ladder, while a launching Dock refused a registration | normal | Its view reports go unseen until it lands |
| Debounces · `core:config_reload`, `core:plugin_state_refresh`, `core:app_directories`, `core:ambient_location`, `core:plugin_reload:<id>:<n>` | 100–750 ms after the last event | normal | Someone is about to look, nobody is watching the instant |
| Change coalescers · `core:network_changed`, `core:volumes_changed` | 500 ms window | normal | Plugins re-read what changed |
| Catalog notify · `core:catalog_notify:<id>` | At most once a second | normal | An open flashlight re-reads the store on it |
| Inspector publish · `core:inspector_publish:<id>` | 100 ms window while a stream is open | normal | A diagnostic page |
| Telemetry export · `core:telemetry_export` | `[telemetry.exporter] interval` after the first record since the last send; 1 s while more than one batch is queued | low | Nothing is sent while nothing changed; a backend reading a minute late is invisible |
| Telemetry retry · `core:telemetry_retry:<signal>` | 1 s doubling to 5 min, or the server's `Retry-After`, at most six attempts | low | Retries and backoffs are background upkeep |
| Received series quiet · `core:telemetry_stale:<id>` | When the next series a surface or monitor reads goes quiet (2.5 reporting intervals) | low | Its `rate` drops to 0; armed only while a surface reads a received metric |
| Plugin restart · `core:plugin_restart:<id>:<n>` | 1–30 s backoff | low | Catalogs survive a restart |
| Plugin prewarm · `core:plugin_prewarm` | 10 s after each plugin reconcile | low | A perform that comes first spawns its plugin itself |
| Plugin status grace · `core:plugin_status_grace:<id>:<n>` | 10 s after a planned reload | low | A stale label blanking late is not watched |
| Liveness sweep · `core:plugin_liveness` | 30 s while a plugin runs | low | Background upkeep |
| Covered widget · `core:widget_hidden:<name>` | 30 s grace | low | Nobody can see a covered widget |
| Tiling drag settle · `core:tiling_settle` | 200 ms after a tiled window's last move or resize, re-armed while the left button is down, armed only by a hand move of a window Flash tiles | high | Once the drag ends the window swaps with the tile it was dropped on, joins another display's workspace, keeps the edge it was resized to, or snaps back to its tile |
| Keep-awake · `core:caffeinate` | A bounded `caffeinate on` hold's `--minutes`, armed only while it lasts | low | powerd ends the assertions at the bound itself; the tick releases them and clears `#{flash.caffeinate}` |
| Plugin cadences and deadlines · `plugin:<id>:<name>` | Plugin-chosen | Plugin-chosen: high, normal or low | See the [status plugins](status-plugins.md#scheduling) table |

Registrations are also scoped to when they can observe anything at all: the
process samplers only while the bar, one of its text popups, a visible
widget or a monitor reads a [process value](status-format.md#process-values),
kernel values only while a surface or a monitor reads them, a received
metric's quiet deadline only while a surface or a monitor reads that metric,
the telemetry export flush only while something new is queued, and the
menu-bar reveal probe only while the pointer is in the band. Secure
input is the exception that stays registered: the tap receives nothing while
the flag is on, so `core:secure-input` is how a stuck hold is noticed at all.
Main-thread
stalls and hitches need no poll at all: the run loop reports each busy stretch
itself, and the HTTP inspector pushes its state on the changes it shows.

The active-window stroke reads the window list on main (see
`scheduleActiveWindowBorderRead`), so it reads only when a window may have
changed: every border-relevant AX notification, activation, quit, Space and
display change bumps `activeWindowBorderEventEpoch`, each read records the
epoch it saw, and a mode change repaints the cached frame without reading
while the two agree.

Visible regions subtract every higher window from the active one, except fully
transparent windows. The frontmost app's window can sit under another app's
normal-level window only while the window list lags an activation, so when that
leaves it fully covered the regions are recomputed without those windows
(`[discover] frontmost_window_covered`); floating layers still cover it. A
system dialog that never becomes the frontmost app — Gatekeeper's card
(`CoreServicesUIAgent`), an authentication panel — is still the surface `f`
and EasyMotion walk: an elevated dialog-sized window, or a normal-level
window of a non-regular process, in front of the focused app. Picture in
Picture, Stage Manager, menu-bar status strips, and another regular app's
ordinary window are not that surface. The walk hints a window's close button
when it has one, and a dialog's default, cancel, and help buttons. A click on
an agent that cannot become frontmost is posted immediately. A walk
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
role there is a typing surface (`JumpTarget.isTextInput`) only when its focus
is settable, which excludes read-only message bubbles.

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
or navigation effects. A commit whose target is not frontmost raises it and
waits for that app's activation before posting; the commit carries that pid as
its handoff, so the activation it waits for, Flash resigning key and the Space
change the raise can cause are the handoff, not a cancellation, before and
during the gesture alike. Activating any other app still cancels, and the
handoff timeout still posts. Pointer-session reset consumes a held-button release once.
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

Flash uses three private interfaces, each looked up at run time, so a macOS
without one only loses what needs it: the window server's
`CGSSetConnectionProperty` on `CGSMainConnectionID` (`BackgroundCursor`),
the undocumented gesture fields of `CGEvent` (`TrackpadGesture`) and the
Dock's `CoreDockSendNotification` (`SystemSurfaceController`). It also reads
a few undocumented Accessibility attributes and notifications of macOS's own
processes, named below. No SIP change, no injected code, no scripting
addition.

Hint labels hide the pointer with `NSCursor.setHiddenUntilMouseMoves`, which
AppKit ignores from a background app, and Flash stays in the background while
the session tap reads keys. At launch `BackgroundCursor` sets the window
server's private `SetsCursorInBackground` connection property, resolved at
run time, so a macOS without it only leaves the pointer visible.

`TrackpadGesture` emulates trackpad gestures the same way, through private
interfaces resolved at run time. Zoom, rotate and smart zoom post gesture
CGEvents with the undocumented gesture fields set (event type 29, the gesture
subtype, magnification, rotation and phase); a macOS that drops them only
makes those gestures do nothing.

`SystemSurfaceController` asks the Dock for Show Desktop, Mission Control,
App Exposé and Launchpad (the Apps view on macOS 26) through the private
`CoreDockSendNotification`, looked up with `dlsym` once; it is the one
caller, for the commands, their gestures and Hyper+3 alike. Each request
toggles, and one made while a Dock view shows returns to the windows rather
than switching, so `show` and `hide` plan from the Dock's view: the
undocumented `AXExposeShowAllWindows`, `AXExposeShowFrontWindows`,
`AXExposeShowDesktop` and `AXExposeExit` notifications the Dock posts on its
application element, observed from launch and again whenever another Dock
process reports or a command finds one (a relaunch). A request waits for the
report confirming it before the next one plans, bounded by a 1.5 s timeout
that fails a `show` or `hide` and leaves the Dock silent (its view unknown,
`toggle` blind) until it reports again. Notification Center and Control Center are pressed
through Control Center's undocumented `AXExtrasMenuBar` items, found by
`AXIdentifier`; their panels and Spotlight's are read as `AXSystemDialog`
windows of their processes. A macOS without the symbol fails the Dock
commands; one whose Dock posts no reports leaves its first request
unconfirmed and then runs only `toggle`.

The same reports tell the resident which view is up (`dockViewChanged`, on
main). While it is Mission Control or App Exposé, every `mouse target`
activation reads that view's group of the Dock's Accessibility tree on the AX
queue instead of walking the focused app (`MissionControlSurface`): `mc` →
`mc.display` → `mc.windows` (thumbnails) and `mc.spaces` (`mc.spaces.list`,
`mc.spaces.add`), or `appexpose`. The Dock builds those elements as the view's
animation ends, so a tree whose Spaces bar is missing is read again on
`core:mission_control_ready` and never served partially. Targets carry no
pid (the Dock never becomes the frontmost app), are validated against the
live element before the click like any captured target, and are clicked at
their centre by `ActionDispatcher`. The tap decision takes the view too:
over NORMAL it swallows only the keys a mapping claims, and never the one
mapped to `app cancel`, so Mission Control reads Escape. A view change ends a target session drawn for
the other side of it.

### Coordinate spaces

Targets use global NSScreen coordinates: primary-screen bottom-left origin,
positive Y upward. Accessibility and CGEvent use the primary-screen top-left
origin, positive Y downward. Convert with the primary screen's height, never the
maximum screen extent. Screen unions start at `CGRect.null`, preserving negative
origins on displays to the left or below the primary display.

`FlashCore` carries the space in the type: `ScreenPoint<Space>` and
`ScreenRect<Space>`, with `AXSpace` (Accessibility attributes, `CGEvent`
locations, the window list's bounds, cursor warps) and `NSSpace` (`NSScreen`,
the overlays, `JumpTarget.frame`, `AppContext.frontWindowFrame`, the mouse
grid, the plugin wire). The only way between them is `toAX(primaryHeight:)` /
`toNS(primaryHeight:)`, and the only Y arithmetic is `ScreenSpace.flip`
behind those. The raw flip is file-private; guardrails reject direct calls
and inline flips elsewhere. Window moves, hint discovery and validation,
Mission Control, notification surfaces, and scrolling all use these boundaries.
A plain `CGPoint` / `CGRect` lives inside the wrappers and at the AppKit,
CoreGraphics or AX call that produces or consumes one (`.cgPoint`,
`.cgRect`); a value read from such a call is wrapped in its space at once,
so a point cannot be flipped twice or not at all. The height is
`ScreenSpace.primaryHeight`, read on main and cached, which callers read
before hopping to a queue; `WindowMover.primaryHeight(in:)` derives the same
from a screen layout.

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
by level and bounds from WindowServer's main-menu window, and `window move`
slots reserve the same band: both take it from one screen snapshot
(`ScreenSnapshot.statusBarHeight`), never from a live visible frame, which
moves as soon as Flash auto-hides the native menu bar. The click windows cover
exactly the painted bands, and the focus border outlines a window only below
any band it runs under, so its stroke is never drawn beneath the bar.
AppKit's app-wide `menuBarHeight` follows whichever
display last hosted the active menu bar, so it is only the last resort. The
heights are re-read on display changes and before every recovery pass after
one, never on a Space switch or wake, so a restored window lands exactly where
the next `window move` would put it. Restores and moves accept a placement only
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
INSERT has one way in, `mode insert` (`InsertEntry`); every other transition
that lands there restores a surface or layer opened from INSERT. No click
changes the mode, so a click asks Accessibility nothing about its point.
`mode insert` takes no argument and runs nothing before INSERT, so the
session tap never holds keys: it swallows or passes each one as it comes
([clicks keep the mode](input-internals.md#clicks-keep-the-mode)).
See [input capture](input-internals.md) for the input latency contracts and
[INSERT](insert-mode.md#enter-insert) for the mode transitions.

## Tiling

`[tiling]` ([tiling](tiling.md)) adds no process, catalog or clock of its
own. `TilingEngine` lives on `WindowLayoutManager`'s serial queue, beside
layout tracking and display recovery, and reads the same navigation catalog
directional focus does; nothing it does runs on the main keyboard loop or
reads the window list.

- **Values.** `TilingTree` (an arena of containers, normalized after every
  transition), `TilingSolver` (tree and usable frame to frames, rounded on
  cumulative edges so neighbors share a pixel edge) and `TilingWorkspaces`
  (the workspace pool, which display shows what, each workspace's home
  display by UUID) are pure values, tested without a window.
- **Writes.** The engine keeps the frame it last set per window and writes
  only differences, through `TilingWindowDriver`: `WindowMover.apply` for a
  tile (the same shrink-before-move ordering, read-back and Gecko handling
  as `window move`), one AX position write to park a hidden window, an AX
  raise and `RunningApplicationActivation` to focus, as the window switcher
  does. Each write marks the window
  self-authored for the 300 ms grace, so its echo is not read as the
  user's.
- **Events.** Catalog installs adopt new windows, and the focused-window
  event adopts a new window before its catalog refresh; destroyed and
  minimized notifications and app termination forget them; the
  focused-window event focuses the tree and shows a parked window's
  workspace; frame changes of managed windows outside the grace arm
  `core:tiling_settle`, a `PollScheduler` deadline that re-arms while the
  left button is down, so a drag is judged once where it ends: the frame
  is read from the AX element that fired and the pointer once, and
  `TilingSolver.dropTarget` picks the tile under the pointer among the
  frames the engine last applied (a swap), else another display's
  workspace, else the window's own tile. A drag with a resized notification
  in it is a resize: each edge that moved against the last applied frame
  pulls the split it sits on (`TilingTree.resizeEdge`, the two sides across
  the edge trading weight) and the window keeps that edge; display
  recovery passes hand the engine the displays they read.
- **Ownership.** A window tiling manages leaves `WindowLayoutIntent`
  tracking and the stranded-window rescue, and placement rules do not run
  while tiling is on: one owner per window frame. Parked windows are not
  directional-focus candidates.
- **Teardown.** Turning `[tiling]` off, or quitting (`applicationWillTerminate`
  waits on the layout queue for at most 2 s, which never reads the window
  list), writes every parked window back on screen before the engine goes.

Workspace state reaches main through one callback: the status controller's
`#{flash.workspace}` and `#{flash.workspaces}`, and `core:workspace.changed`
when the focused workspace changes.

## Other lifecycles

The finder warms catalog snapshots independently of query-specific work. A live
search result belongs to its session, query generation and source; a timeout or
late preparation from an older query cannot replace current rows. Rendering a
new query starts from the catalog plus only the current live result set.

Waiting for a child process always ends on its kernel exit event
(`ProcessExit`, a `kqueue` `NOTE_EXIT` or a process dispatch source), never a
sleep loop: plugin stops, status-job shutdown and deferred terminal reaping
return the moment the process is gone, and deadlines only bound one that is
not. Plugins, status jobs and persistent popups start once the login
environment resolves, since a child keeps the environment it spawned with; a
resolution that fails keeps the seeded one. Status jobs retain their running process and value when effective definitions
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
