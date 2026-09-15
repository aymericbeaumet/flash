# Normal Mode

PASSTHROUGH is the default: apps receive ordinary typing, Escape and native
shortcuts, while explicitly configured Flash shortcuts remain available. Enter
NORMAL deliberately for repeated navigation, then return to PASSTHROUGH when
finished. Focus changes never activate NORMAL or end PASSTHROUGH.

The status pill keeps a fixed width of at least 14 columns in every mode.
PASSTHROUGH uses neutral styling and the active app name when its mode label is empty; it has no window
border. NORMAL and TERMINAL use filled green and blue pills with dark text;
COMMAND stays purple. All three share the same two-point border with a soft
glow, subject to configured overrides. NORMAL/COMMAND border the target app;
TERMINAL borders its own focused popup/window. Hover previews never activate
TERMINAL emphasis.
The centered app name and other configured status content remain independent.

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Important defaults:

- `gg` scrolls to top.
- `G` scrolls to bottom.
- `g1` through `g9` select indexed tabs when the focused source supports it.
- `[t` / `]t` cycle previous/next tab.
- `[h` / `]h` navigate target page history back/forward.
- `[a` / `]a` cycle previous/next app in MRU order.
- `[m` / `]m` (alias `[e` / `]e`) reorder the current tab.
- `[s` / `]s` cycle previous/next split inside the focused terminal window:
  tmux `select-pane` when a tmux client hosts the terminal, otherwise the
  terminal's own ⌘[ / ⌘] split cycling where it binds them. Outside terminals
  the pair is a no-op.
- A `[` / `]` letter never shares a finger with the bracket: `[` and `]` are
  right-pinky keys, so splits use `s` rather than the QWERTY-pinky `p`.
- `n` / `N` cycles find matches with Cmd-G / Cmd-Shift-G. No terminal binds
  that chord, so the pair does nothing in a terminal rather than typing a `g`.
- `r` reloads the current app view with Cmd-R.
- `R` force-reloads with Cmd-Shift-R, matching browser hard reload semantics.
- `f`, `F`, `sf`, and `Df` target discovered clickable elements. `F` requests
  Command-Shift for a new-context click. Primary hint
  clicks enter PASSTHROUGH only when the target declares typing intent.
- `mf` moves the cursor to a discovered target. Every other commit clicks
  where the hint is and returns the pointer to where it was, so hinting never
  relocates the mouse; `scroll_target` is the other verb that moves it.
- `ctrl-f`, `ctrl-shift-f`, `sF`, and `DF` use mouse grid mode for precise screen
  clicks. Primary grid clicks enter PASSTHROUGH.
- `mF` moves the cursor with mouse grid mode.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.

## Explicit mode shortcuts

Mode-entry shortcuts are configured, not global defaults. For example:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_passthrough_mode"]
```

Each shortcut selects its named mode every time. Bare Escape and `i` are not
mode-entry shortcuts; Escape can still cancel an active hint or command surface.
NORMAL stays active across scrolling, tab/app traversal and noneditable hint
commits. A hint session opened directly from PASSTHROUGH returns there after commit or
cancellation. Command/finder completion and dismissal return to PASSTHROUGH
regardless of their entry mode. `enter_command_mode` has no return-mode option.
Users choose command/finder shortcuts, including bindings that prefill the
command line with `:flashlight`.

NORMAL is hermetic: every unmapped key and modifier chord is swallowed, and
only explicit mappings act. A chord the focused app should receive is bound
to `send_key`, or the user enters PASSTHROUGH first. The release of a swallowed
key is swallowed with it, because a terminal running the Kitty keyboard
protocol encodes key releases to its pty.

Hermeticity also bounds what NORMAL synthesizes. A terminal emulator does not
ignore a Command chord it has no binding for: its encoder falls through to the
plain-text path and writes the chord's base character, so an unbound `cmd+g`
types a literal `g` into the shell, hardware or synthetic. In a terminal
Flash therefore refuses to synthesize any Command chord outside the set every
emulator binds (copy, paste, close, new tab, new window, quit, find, the tab
digits, and Shift-bracket tab traversal); the bare bracket chords are added
only for the emulators whose splits live on them. A refused mapping does
nothing and NORMAL stays.

The same bound covers pointer synthesis. A terminal whose foreground program
enabled mouse tracking does not scroll on a wheel event: it encodes an SGR
mouse report and writes it to the pty, and an unconsumed report prints at the
prompt as literal text. Flash cannot read that mode for a terminal it does not
host, so NORMAL never synthesizes a wheel into one and the scroll verbs fall
back to the Accessibility scroller there. `gg` and `G` inside tmux are the tmux
plugin's own history-top and cancel.

`/` (`app_find`) executes its command without changing mode. `t` (`tab_new`)
enters PASSTHROUGH once the tab or window is open, so the browser's address bar or
the new tmux shell can be typed into immediately; in an unsupported app it does
nothing and NORMAL stays.

An all-scope `enter_normal_mode` binding enables advanced mode, which starts in
PASSTHROUGH. The default all-scope map is empty.

Advanced-mode eligibility follows the base mode through command, finder, and
terminal surfaces. Opening a surface while disabled cannot enable NORMAL.
Changing the enabling binding while a surface is open updates its eligibility:
enabling closes to PASSTHROUGH, and disabling closes to the disabled base mode.
A label or configuration refresh preserves native-menu capture suspension;
only an explicit mode entry resets that interaction context. Reentrant events
wait until the current mode effect batch finishes, preserving transition order.

Modified bindings in `[mode.normal.mappings]`, `[mode.passthrough.mappings]`, and
`[mode.command.mappings]` override the same physical chord from the all-mode
map. The command map is empty by default, so the configured mode entries work
without duplicating them per mode.

Command surfaces try the configured mapping matcher before native editing or
finder navigation. Their local `performKeyEquivalent` path uses the same
precedence as Carbon. The global tap still passes command typing.

The all-mode and scoped Carbon registries share an event dispatcher. Their
hotkey identities must be distinct, and a handler must decline events owned by
the other registry. Reused identities or consuming unowned events can break
command shortcuts while NORMAL/PASSTHROUGH still work through the keyboard tap.

## Input capture and latency

NORMAL and hint input normally arrives through `KeyboardCaptureTap`, so the
overlay can remain non-key and the focused application keeps its active window
appearance. Command-line and modal surfaces still use the panel's key-window
path, as does the fallback when macOS refuses the Accessibility-backed tap.
Startup resolves tap availability before presenting a capturing surface. Starting
the tap after NORMAL renders would activate Flash through the fallback path and
leave the previous app inactive until another app switch.

The tap source, Carbon callbacks, AX observer sources, and mode coordinator all
share the main run loop. Treat that loop as the input latency budget:

- The synchronous tap callback only makes the pure swallow decision and queues
  handling. AX IPC, `CGWindowListCopyWindowInfo`, subprocesses, filesystem I/O,
  sleeps, and full overlay layout belong off this path. The PASSTHROUGH branch
  tests raw flags and the O(1) mapping table before anything else. The frontmost
  reconcile does no work when the event's target pid already matches the observed
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
  bookkeeping and PASSTHROUGH target activation resolve the app by identity, and
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

External terminal apps receive their usual shell, Vim and tmux input in
PASSTHROUGH. Their internal modes need no detection by Flash; NORMAL is an
explicit navigation layer there just as it is in another app.

Clicking a status popup's body focuses its local terminal view and enters the
transient `TERMINAL` mode. The overlay owns no keyboard input in this mode: the
existing global tap passes keys through, every Carbon registration is suspended,
and only `[mode.terminal.mappings]` can intercept keys in the popup. The label is
configured with `mode.labels.terminal` and defaults to `TERMINAL`.

Terminal mappings inherit the effective PASSTHROUGH-active bindings for explicit
`enter_normal_mode` and `enter_passthrough_mode` transitions. Scope and plugin
precedence are resolved first; an explicit terminal mapping overrides an
inherited binding with the same canonical key. Other all, normal and passthrough
bindings are inactive. Plugins may contribute terminal mappings using the same
priority rules.

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
popups use the same focus mode for selection, copying, and scrolling. Escape
and Ctrl-C reach the terminal process unless explicitly mapped. Command-W,
`terminal_dismiss`, and `enter_passthrough_mode` dismiss to PASSTHROUGH and
activate the captured external app. Losing popup focus also returns to PASSTHROUGH without
activating a different app. Explicit `enter_normal_mode` selects NORMAL after
dismissal. Persistent processes survive dismissal; fresh processes stop and
lose their session/history. See [terminal lifetimes](terminal-popups.md).

The explicit mode-entry shortcuts also apply to terminal, command and finder
surfaces. `enter_normal_mode` always selects NORMAL;
`enter_passthrough_mode` always selects PASSTHROUGH.

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

## Keyboard handoff

In addition to explicit mode entry and surface dismissal, NORMAL hands the
keyboard to the app through:

- `t` (`tab_new`) once the new tab or window exists, and `focus_input` once a
  text input is focused;
- a physical click or a mouse-grid / pointer-mode / adjust commit while NORMAL
  is capturing (pointer simulation always hands the keyboard to the app);
- an `f` / `F` hint whose target is editable (`JumpTarget.entersPassthroughMode`).

NORMAL remains active across passive focus changes and app activation.
PASSTHROUGH remains active when a text field loses focus; returning to NORMAL
uses an explicit mode-entry action. Bare `a`, `A`, `i`, `I`, `o`, `O`, `gi`, and
Escape do not provide implicit mode transitions; `/` stays in NORMAL. Escape
keeps its native meaning in PASSTHROUGH and terminal surfaces.
