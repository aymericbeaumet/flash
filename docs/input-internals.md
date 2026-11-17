# Input capture and interaction ownership

How NORMAL, hints and the command line receive keys, what may run on the
input path, and which object owns an interaction while it runs. For using
normal mode, see [normal mode](normal-mode.md).

Normal mode captures keyboard input through Flash's sanctioned session tap,
with the overlay panel as its no-permission fallback. Configured modified
mappings use Carbon hotkeys. Unmapped keys and chords are swallowed; only
explicit mappings act, Escape's `app cancel` among them, which hands the
focused app its own Escape as a command. A native surface that owns the
keyboard — a context menu, or Mission Control and App Exposé, known from the
Dock's reports — takes the rest: the tap then swallows only the keys a
mapping claims, and lets the key mapped to `app cancel` through
(`NormalModeInterpreter.passesToNativeSurface`), so the surface closes on
its own Escape.

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

## Input capture and latency

NORMAL and hint input normally arrives through `KeyboardCaptureTap`, so the
overlay can remain non-key and the focused application keeps its active window
appearance. Command-line and modal surfaces still use the panel's key-window
path, as does the fallback when macOS refuses the Accessibility-backed tap.
Startup resolves tap availability before entering NORMAL or a capturing surface.
Starting the tap after NORMAL renders would activate Flash through the fallback
path and leave the previous app inactive until another app switch.

Each hint or grid session fixes its capture path when it starts
(`KeyboardCaptureTap.sessionCapture`). Under secure input (a focused password
field) macOS hides keys from every tap, so that session takes the key window
instead and typed labels reach Flash, never the password field. A commit hands
focus back by raising its target; a cancel yields activation to the covered
app. `#{flash.secure_input}` and `flash resident status` show the state. The tap
refreshes it when a key still reaches Flash. While the flag is on the tap
receives nothing, so `core:secure-input` polls it (low priority, every 2 s)
for the life of the resident; there is no banner. A focused secure field, and
a text field in the app that holds the flag, are left alone. Anything else is
a stuck hold, and Flash asks that app to release it once: a Chromium browser
blurs its focused element and, if the flag stays on, is sent to its address
bar; Firefox and Safari are sent to the address bar; any other holding app is
activated and the app you were in is restored. The first browser blur can ask
for Automation. Flash does not lock the screen and does not show a dialog.
One attempt per time the flag turns on. A password field that is focused when
the attempt would start is left alone; one that appears after the attempt has
started does not abort a release already in progress.

Interpreters read keys through `[app] keyboard_layout`'s reference table
(`KeyCharacters.read`, one lookup per key): labels, the grid, pointer and
adjustment keys and NORMAL mappings match by key position under a non-Latin
input source, while `--search` keeps the typed text. Which characters those
positions spell comes from `[keyboard] layout`, not from this input-source
table. The table is rebuilt on input-source changes and config loads, never
per key, and the swallow decision never reads it.

Handing activation back needs the cooperative API: `NSApp.yieldActivation(to:)`
then `app.activate(from: .current)`. `NSApp.deactivate()` and a bare
`activate(options:)` are ignored on current macOS, and they leave Flash active
with no key window: the next command-line open cannot make the panel key, so
AppKit draws no caret. Closing the command line without running anything hands
activation back this way; a submit that opens an app hands it over through that
app's own activation. The command line's caret is AppKit's insertion point, and
it is live only while the panel is key with the field editor as first responder.
An earlier INSERT handoff may finish after a rapid command open and take key
status back; the panel's key-resign event schedules a guarded recapture while
the command field is still visible and no other Flash window owns focus.

The tap source, Carbon callbacks, AX observer sources, and mode coordinator all
share the main run loop. Treat that loop as the input latency budget:

- The synchronous tap callback only makes the pure swallow decision and queues
  handling. AX IPC, `CGWindowListCopyWindowInfo`, subprocesses, filesystem I/O,
  sleeps, and full overlay layout belong off this path. The INSERT branch tests
  raw flags and the O(1) mapping table before anything else, and the frontmost
  reconcile
  does no work when the event's target pid already matches the observed
  frontmost app (`reconcileFrontmostApplication(forKeyTargetingPID:)`).
- The hyper key is prepared once per config load (`HyperKeyMatcher`: the
  atom's physical chord and the characters that can spell it). A key that
  cannot be it is settled from its key code or typed character before any
  key atom is built, and the tap drops every other swallowed release without
  an `NSEvent` or a main-thread hop. The HYPER hold watch reads that prepared
  chord; the leader atom is resolved once with it. Entering or leaving HYPER
  paints the border's cached frame instead of reading the window list.
- Arrow and function-key mapping commands carry prepared key codes, and every
  synthesized key, click, pointer move and wheel step uses the process's
  shared `CGEventSource`s (`SyntheticEventSources`); creating one per event
  was a WindowServer round trip.
- A recapture-only event calls `recaptureNormalModeKeyboardInput()`. With a live
  tap this restores `.normal` routing and stops; only the no-tap fallback needs
  key-window retries. Recapture must not rebuild the status bar or active-window
  border.
- Once the command surface is visible, edits repaint only the prompt and result
  layers. Plugin commands, subcommands, and help topics are snapshotted once per
  command session and discarded by `resetCommandLineState()`.
- Tab traversal and selection use `normalModeDispatchContext()`, which avoids an
  exact AX or WindowServer geometry lookup for an identity-only action. Current
  external app identity wins over the cached NORMAL target, including CLI and
  Carbon dispatch that did not pass through key-tap focus reconciliation.
  Geometry contexts also reject a capture from a different current app.
- Scope-only mode changes use `MappingsCoordinator.apply(scope:)`. All-scope
  Carbon registrations stay installed and resolve the current mode's winning
  action at dispatch; mode-specific registrations are reconciled by chord, so
  only the chords that differ between the two scopes are unregistered or
  registered. Each `ModeMapping` parses its native chord once at construction.
  Reconcile the registry only when the effective mappings change.
- A mode transition never takes a WindowServer snapshot synchronously: mode-entry
  bookkeeping resolves the app by identity without activating it, and
  the active-window border paints its cached frame at once. A window AX
  event then reads the window list on the next main-queue turn, coalescing a
  burst of updates into one read (about a millisecond). An app activation
  with a cached frame leaves the first read to its 80 ms settle pass, after
  the activation animation, during which the same read cost 5 ms (18 ms at
  p95, once 252 ms); the 250 and 750 ms passes run only while the 80 ms read
  still disagrees with the stroke. Without a cache the activation reads on
  the next turn, since nothing else would draw the stroke. That read must
  stay on main. `CGWindowListCopyWindowInfo` synchronizes with the
  process's pending Core Animation transaction while holding the WindowServer
  connection lock, so from another queue it deadlocks against a main-thread
  commit that carries WindowServer actions until SkyLight's 500 ms timeout,
  freezing the main thread with it. Every window-list read therefore goes
  through `WindowSnapshot.windowList`, which runs it on main (background
  callers hop with `DispatchQueue.main.sync`, so main must never wait
  synchronously on a queue that reads the window list); a guardrail rejects
  any other caller. AX work, LaunchServices lookups, catalog gathering and
  plugin event encoding stay off main: `tab select`, `y` and `:q` press or
  read through AX on background queues, minimized-window restores follow an
  activation instead of preceding it, app-name resolution and the running-app
  refresh run on their own queues, and plugin events are encoded on the plugin
  manager's event queue only when a plugin listens. Scroll commands resolve
  the wheel target frame on the AX queue and do not re-render the mode surface
  afterwards. `configureModeBadge` is memoized on its inputs
  (`ModeBadgeLayoutStamp`), so re-applying an unchanged mode surface skips the
  per-screen relayout.
- AX observer sources live on `AXObserverThread`, not the main loop. A burst of
  notifications (a browser render storm) costs main one drain
  (`AppMonitor.drainAXEvents`) that applies every event's dirty-token bump in
  order; nothing about the prepared-model contract changes.
- Config file events coalesce into one trailing reload per burst
  (`scheduleConfigReload`, 150 ms), a reload whose file bytes are unchanged is
  skipped, and `AutoLaunch.reconcile` runs only when `app.autostart` changes.
- A hint commit never probes minimized windows (the hinted window is on
  screen) and, when the target app is already frontmost, dispatches the click
  on the same turn instead of after the 20 ms activation delay. The registry's
  read paths use the event-driven running-app set instead of re-enumerating
  the workspace per query.
  Focusing a popup suspends every Carbon registration; leaving it restores the
  active scope.

`MainRunLoopStallObserver` records a `main_busy` warning, at any log level,
for every main run-loop busy stretch over 250 ms. It needs no timer: the run
loop reports each wake and each return to sleep. The warning carries
`last_activity_ms_ago`: the most recent coarse main-thread units of work
(`tap_key`, `mode_effects`, `mode_overlay`, `effective_mappings`,
`activation`, `hint_commit`, `config_reload`) with their age, so a stall names
what main was doing. Call `MainThreadActivity.note` at the top of any new
coarse main-thread unit of work. A
timeout-disabled event tap also logs before being re-enabled; either message is
evidence of main-thread work that needs moving or narrowing.

Two debug-level probes measure the path itself: `[latency] tap_to_route` is the
delay from the HID timestamp to the main-thread turn that routes a swallowed
key, and `[latency] normal_dispatch` is the synchronous cost of one normal-mode
action. At `info`, `[latency] hints_visible` times each hint activation from
its trigger to the Core Animation commit that shows it; see
[performance](performance.md). `mise run bench:footprint` samples the resident and its children
(CPU, idle wakeups, memory, descriptors) and summarises stalls and log volume
for a before/after comparison.

### Mode transitions and Carbon registries

Reentrant events wait until the
current mode effect batch finishes, preserving transition order.

The all-mode and scoped Carbon registries share an event dispatcher. Their
hotkey identities must be distinct, and a handler must decline events owned by
the other registry. Reused identities or consuming unowned events can break
command shortcuts while NORMAL/INSERT still work through the keyboard tap.

## Clicks keep the mode

A click never changes the mode: a physical click, `f` and `F` keep it
wherever they land, and Flash asks Accessibility nothing about the point.
Clicks are observed by the overlay's mouse monitors (`PointerMonitors.swift`:
one global and one local `NSEvent` monitor for button presses and scrolls),
not by a tap. Synthesized clicks carry Flash's tag and are ignored there;
clicks on Flash's own windows and in the menu bar never reach the app-click
decision, and a secondary click suspends NORMAL for the context menu. A
primary or middle click in NORMAL ends hints showing behind it. When Flash
was active, or the clicked window's app was not frontmost, macOS spent the
click on activation and Flash posts it again. NORMAL then recaptures, and
the keys typed after the click are NORMAL's. The session tap never holds a
key: it swallows or passes each one as it comes.

## The focus region

NORMAL's `move` keys (`h` `j` `k` `l`, the half pages and pages, `gg` /
`G`) send arrows in an engaged field and in lists and scroll elsewhere
([arrows or scrolling](normal-mode.md#arrows-or-scrolling)), so a keypress
needs to know where the focus sits without asking Accessibility on the
keyboard path. `FocusRegionTracker` keeps that answer for the focused app,
the focus region. Every focus change `AppMonitor`'s observers report
(`focusedElementMayHaveChanged`: an app activation,
`AXFocusedUIElementChanged`, a focused or main window change; never an
element's destruction, which a busy web app posts by the hundred while the
focus stays put) drops the cached region and starts a read on
`normalModeAXActionQueue`, the queue the motions and VISUAL use, off the
main loop. The read is the focused-text read (role, DOM classes, label,
whether the value can be set), then the role and
subrole of the element and of its first three ancestors, and the frame of
the scroll area around it, where a scroll lands when the pointer is outside
the focused window. A declared terminal emulator needs no read: its bundle
decides. Whether the focus is text NORMAL acts on is one predicate,
`TextScope.isActive(for:pid:element:)`, which the `move` region, the
motions and VISUAL all read:
editable focus whose element is the one engaged
([engage a field](normal-mode.md#engage-a-field)).

Reads are generation-scoped. A focus change while a read runs drops that
read's answer and starts another, so a reading from before the latest
change is never kept. A `move` that arrives while the read is pending waits
for it, in order behind any earlier one, instead of acting on a stale
region, and lands only in the mode it was typed in. A reading for another
app than the one the key was meant for counts as unknown: a page, which
scrolls. The keypress itself only looks the cache up, with no Accessibility
or WindowServer IPC on the main keyboard loop; `h` and `l` in text read
their line on the same queue, to stop at its edge. The arrows a `move`
sends then go through the app's `input` or `move` binding, 4 ms apart.

Editable focus alone never makes text. `TextScope` holds one engaged
element, its app's pid and the element's `CFHash`, in memory only. Before
any act counts, its policy says whether NORMAL engages in that app at all:
`[mode.text] enabled` is the switch, an app's `[mode.apps."<bundle>".text]
enabled` forces it either way, and otherwise an app a plugin declared
`own_text_editing` (the union across plugins, `OwnTextEditingApps`, read
like the terminal list) is never engaged; `v` and `V` ask the same
predicate first. It reads a bundle id and two config values, nothing from
Accessibility, and a reload that refuses the engaged app disengages it
(`config_changed`). A changed plugin declaration union reconciles this
policy after publication and invalidates pending engagement; plugin logs
and unchanged snapshots never trigger it. Leaving
INSERT with the focus in a field engages it; `gi`, a primary click and an
`f` on a text input go out first, then each settled reading until the next
key engages the editable element it names, so a reading from before the
click is corrected. Another app coming forward disengages at once, a
settled reading naming another element disengages, and one naming the
engaged element keeps it, whatever region it reports: nothing is
debounced. Escape (the text table's `mode leave`)
and every mode change but the INSERT, VISUAL, command-line and HYPER round
trips disengage too.
Each transition logs `[text] engaged` or `[text] disengaged` with its
reason and the app's bundle, never content.

NORMAL's table follows the engagement only. When it changes,
`applyTextScopeTable` switches the applied scope between `normal` and
`text` ([Vim motions in text](normal-mode.md#vim-motions-in-text)) with
the scope-only `MappingsCoordinator.apply(scope:)`: Carbon reconciles only
the chords that differ, no registry is rebuilt, and a half-typed sequence
of the old table drops. A focus reading that leaves the engagement as it
was changes nothing, so focus flapping between a field and its page never
drops a pending `]t`, and the keypress never changes the table itself. The
motions then read the focused text on `normalModeAXActionQueue` too, check
it is the engaged element, and set the caret there.

## Interaction ownership

`ActivationLifecycle` distinguishes discovery, a pending commit, and an active
gesture. A newer hint request replaces discovery or cancels a commit before its
input starts. Once a gesture starts, it finishes its mouse release before the
latest queued activation runs. Cancellation suppresses the old gesture's mode
and UI outcome; an old completion cannot clear a newer operation's state. Dock
and scroll-area discovery use the same ownership tokens as ordinary hints.

`HintSession` owns the selected action and target data. `ActionDispatcher`
owns the one button `mouse button` or `mouse pointer`'s `v` holds: a pure
`MouseButtonHold` decides which press and release events each transition
posts, so a press is released exactly once. While it is held, every pointer
move Flash makes posts that button's dragged event; a session reset or
replacement keeps it, so `mouse button --state=down` then `mf` drags to a
hint. Cancelling a Flash overlay, `mode leave`, application shutdown and a
committed click, drag or selection release it. Shutdown also waits for finite
synthetic gestures to post their release events. Click repetition
records a pending click only when its generation is still current and input
actually starts.

`window switch` is a hint-session phase like a confirmation: the list owns
every key in every mode, the focused app stays active until a window is
chosen, and only a label, Return or Escape ends it, so nothing waits for a
modifier to come up. Choosing raises the window on the window layout AX queue after
checking that its element still is that app's window, and a switcher opened
since owns what comes forward. See [windows](windows.md#switch-to-any-window).

`CandidateFinderSession` owns warm snapshots, query answers, live results, and
their scoring caches. `CandidateFinderCoordinator` manages the prompt and
publication lifecycle. Live source results stay separate from the warm catalog:
each exact source/query has a token checked before background preparation and
again at publication. Changing or leaving that query clears its rows and rejects
both stale replies and timeout results. Initial snapshot publication never
overwrites the current live-query result.
