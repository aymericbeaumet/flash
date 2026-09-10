# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Important defaults:

- `gg` scrolls to top.
- `G` scrolls to bottom.
- `g1` through `g9` select indexed tabs when the focused source supports it.
- `[t` / `]t` cycle previous/next tab.
- `[h` / `]h` navigate target page history back/forward.
- `[a` / `]a` cycle previous/next app in MRU order.
- `n` / `N` cycles find matches with Cmd-G / Cmd-Shift-G.
- `r` reloads the current app view with Cmd-R.
- `R` force-reloads with Cmd-Shift-R, matching browser hard reload semantics.
- `f`, `sf`, and `df` target discovered clickable elements. Primary hint
  clicks enter INSERT only when the target declares typing intent.
- `mf` moves the cursor to a discovered target.
- `F`, `sF`, and `dF` use mouse grid mode for precise screen clicks, then enter
  insert mode.
- `mF` moves the cursor with mouse grid mode.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.

## Shared mode exit

`leave_mode`, `enter_insert_mode`, `enter_command_mode`, and `focus_input` ship
without default mappings in every scope. Bare `a`, `A`, `i`, `I`, `o`, `O`,
and `gi` do not enter INSERT. Users explicitly choose their shortcuts,
including bindings that prefill the command line with `:flashlight`.

Both `mode.normal.passthrough_keys` and `mode.normal.passthrough_modifiers`
default to `[]`. Only matching configured unmapped keys or modifiers pass
through NORMAL and enter INSERT; explicit mappings take precedence.
`/` (`app_find`) and `t` (`tab_new`) execute their commands without changing
mode. Use an explicit `enter_insert_mode` shortcut to type afterward.

Bind `["flash", "leave_mode"]` in `[mode.all.mappings]` to enable advanced
mode with one exit shortcut. It returns INSERT to
NORMAL, closes command-line, finder, and terminal surfaces using their recorded
return mode, and does nothing in idle NORMAL or with advanced mode disabled.
`enter_normal_mode` remains the explicit action for selecting NORMAL even when
a command panel was opened with `--restore-mode`.

Advanced-mode eligibility follows the base mode through command, finder, and
terminal surfaces. Opening a surface while disabled cannot enable NORMAL.
Changing the enabling binding while a surface is open updates its return mode:
enabling returns to INSERT, and disabling returns to passthrough. A label or
configuration refresh preserves native-menu capture suspension; only an explicit
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

The tap source, Carbon callbacks, AX observer sources, and mode coordinator all
share the main run loop. Treat that loop as the input latency budget:

- The synchronous tap callback only makes the pure swallow decision and queues
  handling. AX IPC, `CGWindowListCopyWindowInfo`, subprocesses, filesystem I/O,
  sleeps, and full overlay layout belong off this path. Passthrough modifier
  flags are resolved once per config apply, the INSERT branch tests raw flags
  and the O(1) mapping table before anything else, and the frontmost reconcile
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
- A mode transition never takes a WindowServer snapshot on main: mode-entry
  bookkeeping and INSERT target activation resolve the app by identity, and
  the active-window border resolves its frame on `AppMonitor.geometryQueue`
  and applies it one hop later under a generation token. Scroll verbs resolve
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

Unknown commands and unsupported subcommands use Flash’s existing error toast
and warning log. The diagnostic names the invocation and points to the mapping
or configuration. Invalid mapping arrays report their source location during
configuration loading. Malformed built-in commands cannot silently become plugin
calls, and plugin execution failures are also surfaced.

The CLI accepts `--key=value` and boolean `--flag` arguments, rejects stray
positional subcommands, and returns status 2 when parsing or resident dispatch
rejects an invocation. Successful dispatch does not imply an asynchronous plugin
operation completed successfully; later failures appear in the toast and logs.
An empty command prompt remains quiet.

## Explicit INSERT entry

The default mapping set has no `i`, `I`, `a`, `A`, `o`, or `O` insert aliases,
and `/` / `t` no longer enter INSERT after their action. INSERT is entered by:

- a configured `enter_insert_mode` mapping;
- a configured `passthrough_keys` / `passthrough_modifiers` keypress (for
  example `cmd+l` with the default modifiers), which continues to the app;
- a physical click or a mouse-grid / pointer-mode / adjust commit while NORMAL
  is capturing (pointer simulation always hands the keyboard to the app);
- an `f` / `F` hint whose target is editable (`JumpTarget.entersInsertMode`).

Focus changes, app activation, and unrelated key sequences never enter INSERT.
INSERT exits automatically when the focused element stops being editable, as
before, or explicitly through `leave_mode` / `enter_normal_mode`.

```toml
[mode.all.mappings]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
"cmd+ctrl+[" = ["flash", "leave_mode"]
"alt+space" = ["flash", "terminal_show"]
```

Closing a terminal or command surface may restore its saved INSERT mode.
