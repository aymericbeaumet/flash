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
- `n` sends Cmd-N to open a new window.
- `r` reloads the current app view with Cmd-R.
- `R` force-reloads with Cmd-Shift-R, matching browser hard reload semantics.
- `f`, `sf`, and `df` click discovered elements while preserving the base mode.
- `mf` moves the cursor to a discovered target.
- `F`, `sF`, and `dF` use mouse grid mode while preserving the base mode.
- `mF` moves the cursor with mouse grid mode.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.

## Input capture and latency

NORMAL and hint input normally arrives through `KeyboardCaptureTap`, so the
overlay can remain non-key and the focused application keeps its active window
appearance. Command-line and modal surfaces still use the panel's key-window
path, as does the fallback when macOS refuses the Accessibility-backed tap.

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
  Carbon registrations stay installed across normal, insert, and command
  surfaces; only normal/insert registrations are replaced. Focusing a status
  popup suspends both all-scope and scoped registrations; leaving it restores
  the active scope. Rebuild the complete registry when effective mappings change.

`MainThreadWatchdog` records a `main_thread_stall` warning when the loop misses
its maintained threshold. A timeout-disabled event tap also logs before being
re-enabled; either message is evidence of main-thread work that needs moving or
narrowing.

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
finder input, and leaves INSERT (including locked INSERT) for NORMAL. In NORMAL
or disabled mode it only dismisses active hints. An all-scope binding to either
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

Only an explicitly configured `enter_insert_mode` or `enter_locked_insert_mode`
action enters INSERT. The default mapping set has no `i`, `I`, `a`, `A`, `o`, or
`O` insert aliases. Unmapped passthrough keys/modifiers keep the base mode;
clicks, editable hints, focus changes, find/new-tab actions, secure input, and
configuration enabling advanced mode do not infer INSERT intent.

```toml
[mode.all.mappings]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
"cmd+ctrl+[" = ["flash", "leave_mode"]
"alt+space" = ["flash", "terminal_show"]
```

Temporary routing handoffs for native menus, secure input, and pointer delivery
remain separate from mode changes. INSERT stays active until an explicit exit;
closing a terminal or command surface may restore its saved INSERT mode.
