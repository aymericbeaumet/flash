# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Defaults use Flash-owned actions, standard macOS editing commands and basic tab
actions. Other tab, pane, page-history, reload, archive, find-match,
document-URL and mark commands remain available for explicit mappings.

- `h` / `l` scroll left/right. `ctrl+e` / `ctrl+y` send a mouse-wheel scroll
  down/up by 3 lines; `ctrl+d` / `ctrl+u` send 20 lines down/up. Configure these
  amounts with `[mode] scroll_step_lines` and `scroll_page_lines`.
- `gg` / `G` go to the top/bottom.
- `u` undoes and `ctrl+r` redoes. Bare `d`, `j` and `k` are unbound.
- `y` copies immediately, `p` pastes and `/` opens Find.
- `x` sends Cmd-W to close the current tab; `X` sends Cmd-Shift-T to reopen it.
  Both preserve NORMAL and send the same shortcut in every app.
- `r` sends Cmd-R to reload; `R` sends Cmd-Shift-R to hard-reload. Terminals
  leave Cmd-R unbound, so there both do nothing rather than typing an `r`.
- `[a` / `]a` cycle previous/next app in MRU order.
- `[t` / `]t` send Cmd-Shift-[ / Cmd-Shift-] directly in every app, including
  terminals. Repeat the final `t` to keep switching tabs. WhatsApp binds the
  chord to its previous/next chat; Messages, which leaves it unbound, receives
  its own Control-(Shift-)Tab conversation chord instead.
- `t` sends Cmd-T directly. `g1`–`g9` send Cmd-1…Cmd-9 directly, including in
  terminals and tmux. These shortcuts preserve NORMAL.
- `g0` / `g^` go to the first tab and `g$` to the last. tmux and plugin
  sources select their own first and last windows; otherwise the first tab is
  Cmd-1, and the last is Cmd-9 in browsers.
- `[m` / `]m` move the current tab left/right; repeat `m` to continue moving it.
  Tmux reorders its window, and Firefox receives Control-Shift-Page Up/Down.
- `ctrl+o` / `ctrl+i` traverse Flash's movement history.
- Lowercase `f` targets discovered clickable elements; uppercase `F` targets a
  screen position through the grid. A lowercase prefix picks the click on
  either surface: none for primary, `s` secondary, `d` double, `m` move.
  So `df` double-clicks an element and `dF` double-clicks a grid position.
- A prefix letter must not also be a mapping of its own, or that mapping waits
  for `sequence_timeout_ms` before it fires. Triple click therefore ships
  unbound, because `tf` would stall the bare `t` (new tab). Bind `tf` / `tF`
  in your own config if you want it, and drop your `t` mapping to match.
- Primary clicks enter INSERT only on input targets; secondary clicks preserve
  NORMAL. A hint click moves the pointer to the target and leaves it there;
  `m` (move) moves it without clicking.
- Terminal link hints add Shift, so `f` opens the link through the terminal.
  The hover and click carry the same modifiers.
- Modifiers held on the final hint key ride the click (`hints.magic_modifiers`,
  and Shift always): `f` then Shift-`<hint>` is a Shift-click, on targets and on
  the grid alike. Link text repeated in a terminal pane resolves to the copy
  under the hint.
- `sF` / `dF` use mouse grid mode for secondary/double clicks.
- `mF` moves the cursor with mouse grid mode.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.

## Movement history

`ctrl+o` and `ctrl+i` move backward and forward across apps and source locations,
including Firefox tabs and tmux windows. App focus and location-catalog changes
feed the same history. Repeated observations of the same location coalesce;
returning to a location after visiting another remains a chronological stop.
Choosing a new destination after moving backward discards the forward branch.

Locations restore through their owning source. The Firefox bridge preserves
tab IDs across title, URL and window changes; restoration matches the current
tab strip to one AX window and cancels if two windows are indistinguishable.
Without the bridge, Firefox uses the URL, or title when AX has no URL.
Tmux keeps stable window IDs so reordering a window does not change its history
destination. Apps without a more precise source restore application focus.
The stack does not capture page scroll positions, editor cursor positions, or
terminal scrollback offsets. History is in memory and bounded to 20 stops in
each direction.

## Shared mode exit

`leave_mode`, `enter_insert_mode`, `enter_command_mode`, and `focus_input` ship
without default mappings in every scope. Bare `a`, `A`, `i`, `I`, `o`, `O`,
and `gi` do not enter INSERT. Users explicitly choose their shortcuts,
including bindings that prefill the command line with `:flashlight`.

NORMAL is hermetic: every unmapped key and modifier chord is swallowed, and
only explicit mappings act. A chord the focused app should receive is bound
to `send_key`, or the user enters INSERT first. The release of a swallowed
key is swallowed with it, because a terminal running the Kitty keyboard
protocol encodes key releases to its pty.

A synthesized chord reaches an iOS app (Mac Catalyst or iPad) with its
modifiers pressed and released around the key, as a keyboard sends it: UIKit
matches key commands against the modifier state it tracks from those presses
and ignores a lone key event carrying modifier flags.

Hermeticity also bounds what NORMAL synthesizes. A terminal emulator does not
ignore a Command chord it has no binding for: its encoder falls through to the
plain-text path and writes the chord's base character, so an unbound `cmd+g`
types a literal `g` into the shell, hardware or synthetic. In a terminal
Flash therefore refuses to synthesize any Command chord outside the set every
emulator binds (copy, paste, close, new tab, new window, quit, find, the tab
digits, and Shift-bracket tab traversal); the bare bracket chords are added
only for the emulators whose splits live on them. A refused mapping does
nothing and NORMAL stays.

The four vertical scroll bindings synthesize line-based mouse-wheel events
in every app, including terminals, at the current pointer position. They use
no app-specific scrolling action or Accessibility scroll fallback. The receiving
app handles the event just as it handles a physical wheel. `[mode] scroll_step`
continues to set horizontal movement in pixels. `gg` and `G` retain their
source-aware edge behavior; inside tmux they use history-top and cancel.

NORMAL is persistent by default; `enter_normal_mode` takes no persistence
option. Opening Find, creating or switching tabs, and `focus_input` preserve
NORMAL even when the app focuses an editable field. Accessibility focus
notifications never change the mode. A primary `f` hint click enters INSERT
only when its selected target is an input; other hint targets keep NORMAL.
`F` follows the same rule: the grid point is hit-tested before the click, and
only a primary, double or triple click on a text input enters INSERT. Physical
app clicks and an explicit `enter_insert_mode` mapping also hand typing to the
app.

The status pill resolves its mode label and palette from the current mode
together. Background status evaluations preserve the live `#{flash.mode}`
reference, so plugin updates and queued renders cannot repaint an old label
with the new mode's colors. Mode labels update without a fade.

Bind `["flash", "leave_mode"]` in `[mode.all.mappings]` to enable advanced
mode with one exit shortcut. It returns INSERT to
NORMAL, closes command-line, finder, and terminal surfaces using their recorded
return mode, and does nothing in idle NORMAL or with advanced mode disabled.
`enter_normal_mode` remains the explicit action for selecting NORMAL even when
a command panel was opened with `--restore-mode`.

Advanced-mode eligibility follows the base mode through command, finder, and
terminal surfaces. Opening a surface while disabled cannot enable NORMAL.
Changing the enabling binding while a surface is open updates its return mode:
enabling returns to NORMAL, and disabling returns to the disabled base mode.
A label or configuration refresh preserves native-menu capture suspension; only an explicit
mode entry resets that interaction context. Reentrant events wait until the
current mode effect batch finishes, preserving transition order.

Modified bindings in `[mode.normal.mappings]`, `[mode.insert.mappings]`, and
`[mode.command.mappings]` override the same physical chord from the all-mode
map. The command map is empty by default, so the shared exit works without
duplicating it per mode.

Command surfaces try the configured mapping matcher before native editing or
finder navigation. Their local `performKeyEquivalent` path uses the same
precedence as Carbon. The global tap still passes command typing.

The all-mode and scoped Carbon registries share an event dispatcher. Their
hotkey identities must be distinct, and a handler must decline events owned by
the other registry. Reused identities or consuming unowned events can break
command shortcuts while NORMAL/INSERT still work through the keyboard tap.

## Input capture and latency

NORMAL and hint input normally arrives through `KeyboardCaptureTap`, so the
overlay can remain non-key and the focused application keeps its active window
appearance. Command-line and modal surfaces still use the panel's key-window
path, as does the fallback when macOS refuses the Accessibility-backed tap.
Startup resolves tap availability before entering NORMAL or a capturing surface.
Starting the tap after NORMAL renders would activate Flash through the fallback
path and leave the previous app inactive until another app switch.

Handing activation back needs the cooperative API: `NSApp.yieldActivation(to:)`
then `app.activate(from: .current)`. `NSApp.deactivate()` and a bare
`activate(options:)` are ignored on current macOS, and they leave Flash active
with no key window: the next command-line open cannot make the panel key, so
AppKit draws no caret. Closing the command line without running anything hands
activation back this way; a submit that opens an app hands it over through that
app's own activation. The command line's caret is AppKit's insertion point, and
it is live only while the panel is key with the field editor as first responder.

The tap source, Carbon callbacks, AX observer sources, and mode coordinator all
share the main run loop. Treat that loop as the input latency budget:

- The synchronous tap callback only makes the pure swallow decision and queues
  handling. AX IPC, `CGWindowListCopyWindowInfo`, subprocesses, filesystem I/O,
  sleeps, and full overlay layout belong off this path. The INSERT branch tests
  raw flags and the O(1) mapping table before anything else, and the frontmost
  reconcile
  does no work when the event's target pid already matches the observed
  frontmost app (`reconcileFrontmostApplication(forKeyTargetingPID:)`).
- A recapture-only event calls `recaptureNormalModeKeyboardInput()`. With a live
  tap this restores `.normal` routing and stops; only the no-tap fallback needs
  key-window retries. Recapture must not rebuild the status bar or active-window
  border.
- Once the command surface is visible, edits repaint only the prompt and result
  layers. Plugin commands, subcommands, and help topics are snapshotted once per
  command session and discarded by `resetCommandLineState()`.
- Tab traversal and selection use `normalModeDispatchContext()`, which avoids an
  exact AX or WindowServer geometry lookup for an identity-only action.
- Scope-only mode changes use `MappingsCoordinator.apply(scope:)`. All-scope
  Carbon registrations stay installed and resolve the current mode's winning
  action at dispatch; mode-specific registrations are reconciled by chord, so
  only the chords that differ between the two scopes are unregistered or
  registered. Each `ModeMapping` parses its native chord once at construction.
  Reconcile the registry only when the effective mappings change.
- A mode transition never takes a WindowServer snapshot synchronously: mode-entry
  bookkeeping and INSERT target activation resolve the app by identity, and
  the active-window border paints its cached frame at once, then reads the
  window list on the next main-queue turn, coalescing a burst of updates into
  one read (about a millisecond, 20 ms at worst during an activation). That
  read must stay on main. `CGWindowListCopyWindowInfo` synchronizes with the
  process's pending Core Animation transaction while holding the WindowServer
  connection lock, so from another queue it deadlocks against a main-thread
  commit that carries WindowServer actions until SkyLight's 500 ms timeout,
  freezing the main thread with it. Every window-list read therefore goes
  through `WindowSnapshot.windowList`, which runs it on main (background
  callers hop with `DispatchQueue.main.sync`, so main must never wait
  synchronously on a queue that reads the window list); a guardrail rejects
  any other caller. AX work, LaunchServices lookups, catalog gathering and
  plugin event encoding stay off main: `tab_select`, `y` and `:q` press or
  read through AX on background queues, minimized-window restores follow an
  activation instead of preceding it, app-name resolution and the running-app
  refresh run on their own queues, and plugin events are encoded on the plugin
  manager's event queue only when a plugin listens. Scroll verbs resolve
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
  Focusing a terminal popup suspends every Carbon registration; leaving it
  restores the active scope.

`MainThreadWatchdog` records a `main_thread_stall` warning when the loop misses
its maintained threshold. The warning carries `last_activity_ms_ago`: the most
recent coarse main-thread units of work (`tap_key`, `mode_effects`,
`mode_overlay`, `effective_mappings`, `activation`, `hint_commit`,
`config_reload`) with their age, so a stall names what main was doing. Call
`MainThreadWatchdog.note` at the top of any new coarse main-thread unit of
work. A
timeout-disabled event tap also logs before being re-enabled; either message is
evidence of main-thread work that needs moving or narrowing.

Two debug-level probes measure the path itself: `[latency] tap_to_route` is the
delay from the HID timestamp to the main-thread turn that routes a swallowed
key, and `[latency] normal_dispatch` is the synchronous cost of one normal-mode
action. `Scripts/measure-footprint.sh` samples the resident and its children
(CPU, idle wakeups, memory, descriptors) and summarises stalls and log volume
for a before/after comparison.

## Interaction ownership

`ActivationLifecycle` distinguishes discovery, a pending commit, and an active
gesture. A newer hint request replaces discovery or cancels a commit before its
input starts. Once a gesture starts, it finishes its mouse release before the
latest queued activation runs. Cancellation suppresses the old gesture's mode
and UI outcome; an old completion cannot clear a newer operation's state. Dock
and scroll-area discovery use the same ownership tokens as ordinary hints.

`HintSession` owns the selected action, target data, and pointer drag. Every
reset, replacement, mode exit, and application shutdown consumes any held
primary button exactly once before forgetting the session. Shutdown also waits
for finite synthetic gestures to post their release events. Click repetition
records a pending click only when its generation is still current and input
actually starts.

`CandidateFinderSession` owns warm snapshots, query answers, live results, and
their scoring caches. `CandidateFinderCoordinator` manages the prompt and
publication lifecycle. Live source results stay separate from the warm catalog:
each exact source/query has a token checked before background preparation and
again at publication. Changing or leaving that query clears its rows and rejects
both stale replies and timeout results. Initial snapshot publication never
overwrites the current live-query result.

## Terminal popup input

Clicking a status popup's body focuses its local terminal view and enters the
transient `TERMINAL` mode. The overlay owns no keyboard input in this mode: the
existing global tap passes keys through, every Carbon registration is suspended,
and only `[mode.terminal.mappings]` can intercept keys in the popup. The label is
configured with `mode.labels.terminal` and defaults to `TERMINAL`.

Terminal mappings inherit only the effective INSERT-active bindings whose
winning action is `enter_normal_mode` or `leave_mode`. Scope and plugin precedence are resolved
before this inheritance; an explicit terminal mapping overrides an inherited
binding with the same canonical key. Other all, normal, and insert bindings are
inactive. Plugins may contribute terminal mappings using the same priority rules.

The local sequence recognizer accepts the shared key syntax, including modified
chords and explicit sequences, but has no implicit Escape behavior, counts,
register prefixes, or `<leader>`. Only known sequence prefixes wait for
`mode.sequence_timeout_ms`. An exact mapping that also starts a longer sequence
waits for that timeout; a mismatch resolves the longest completed mapping and
reprocesses the remaining keys. Unmatched events retain their original modifiers
and are replayed exactly once to the terminal that received them. Focus and
configuration changes flush unresolved events without dispatching a pending
command. `repeat = true` retains the explicit final-key repetition behavior.

Local mappings run before native copy/paste and terminal key encoding. Text-only
popups use the same focus mode for selection, copying, and scrolling. Leaving via
`enter_normal_mode` dismisses the popup and activates the captured external app
before NORMAL recapture. Losing popup focus restores the prior base mode without
activating a different app. Popup focus and visibility do not determine the
lifetime of a configured terminal process.

`leave_mode` provides one configured exit across surfaces. It dismisses a terminal
and restores its prior base mode/app, restores the saved mode from command or
finder input, and leaves INSERT for NORMAL. In NORMAL or disabled mode it only
dismisses active hints and is otherwise a no-op. An all-scope binding to either
`enter_normal_mode` or `leave_mode` enables advanced mode. For a shifted bracket,
use `"cmd+shift+[" = ["flash", "leave_mode"]`; the key matcher handles the `{`
character produced by Shift.

## Rejected commands

Unknown commands and unsupported subcommands do nothing visible: no toast, only
a warning log naming the invocation and pointing to the mapping or
configuration. Invalid mapping arrays report their source location during
configuration loading. Malformed built-in commands cannot silently become plugin
calls. Plugin execution failures still raise the error toast.

The CLI accepts `--key=value` and boolean `--flag` arguments, rejects stray
positional subcommands, and returns status 2 when parsing or resident dispatch
rejects an invocation. Successful dispatch does not imply an asynchronous plugin
operation completed successfully; later failures appear in the toast and logs.
An empty command prompt remains quiet.

## Explicit INSERT entry

The default mapping set has no `i`, `I`, `a`, `A`, `o`, or `O` insert aliases.
INSERT is entered by:

- a configured `enter_insert_mode` mapping;
- a physical primary click while NORMAL is capturing;
- a primary hint or mouse-grid click on an input target (the same rule for
  `f` and `F`).

Other normal commands, focus changes and app activation preserve NORMAL.
Moving the pointer, dragging, or selecting with the grid does not request INSERT.
A multi-click session ends when its click enters INSERT.
Use `leave_mode` / `enter_normal_mode` to return from INSERT to NORMAL.

```toml
[mode.all.mappings]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
"cmd+ctrl+[" = ["flash", "leave_mode"]
"alt+space" = ["flash", "terminal_show"]
```

Closing a terminal or command surface may restore its saved INSERT mode.
