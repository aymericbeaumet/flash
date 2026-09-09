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
  sleeps, and full overlay layout belong off this path.
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
  action at dispatch; only mode-specific registrations are replaced. Rebuild
  the complete registry only when the effective mappings change.
  Focusing a terminal popup suspends every Carbon registration; leaving it
  restores the active scope.

`MainThreadWatchdog` records a `main_thread_stall` warning when the loop misses
its maintained threshold. A timeout-disabled event tap also logs before being
re-enabled; either message is evidence of main-thread work that needs moving or
narrowing.

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
winning action is `leave_mode` or `enter_normal_mode`. Scope and plugin precedence are resolved
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
