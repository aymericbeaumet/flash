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
- `f`, `sf`, and `df` target discovered clickable elements, then enter insert
  mode as explicit mouse interactions.
- `mf` moves the cursor to a discovered target.
- `F`, `sF`, and `dF` use mouse grid mode for precise screen clicks, then enter
  insert mode.
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
  Carbon registrations stay installed; only normal/insert registrations are
  replaced. Rebuild the complete registry only when the effective mappings
  change.

`MainThreadWatchdog` records a `main_thread_stall` warning when the loop misses
its maintained threshold. A timeout-disabled event tap also logs before being
re-enabled; either message is evidence of main-thread work that needs moving or
narrowing.
