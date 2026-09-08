# Terminal windows and status popups

Status popups and shortcut windows share one terminal registry, terminal mode,
input mappings, exit commands, and renderer. Declare every process under
`[terminal.<name>]`; `#[popup=<name>]` and `terminal_show --name=<name>` present
the same session. `[statusbar.popup]` contains document strings only.

`persistent = true` starts a session after the login-shell environment resolves,
even if the status bar is disabled or no template refers to it. Hiding it keeps
the process and history. The default, `persistent = false`, starts on an
explicit opening or the first hover and stops when dismissed. Continued hover
reuses the existing process; re-entry starts a fresh one. One named session is
shared across displays.

```toml
[statusbar]
template = "#[popup=system]System#[nopopup]"

[terminal.system]
persistent = true
command = ["btm", "--read_only", "--rate", "2s"]
columns = 80
rows = 24
# working_directory = "~/workspace"
# env = { EXAMPLE = "value" }

[mode.terminal.mappings]
"cmd+r" = ["flash", "terminal_restart"]
```

Commands are argv arrays, with the same environment and path resolution as other Flash commands. Shell syntax needs an explicit shell, for example `["/bin/sh", "-c", "exec btm"]`. Commands inherit the resolved environment and use `TERM=xterm-256color` and `COLORTERM=truecolor`. Configured foreground and background colors apply before spawning, so startup terminal queries see the same palette as the popup. A popup has a real controlling PTY with ordinary shell job control, terminal responses, input modes, alternate screens, and resize notifications.

The terminal starts at its configured grid, defaulting to 100 columns by 28 rows. Presentation clamps it to the available screen and sends a real PTY resize. Hiding it preserves the last nonzero grid. Font, colors, placement, and size changes preserve the child; changing command, working directory, or environment replaces only that named session. Removing a declaration stops it. Every owned terminal restarts after any exit, including a normal quit or a killed process. The first retry waits 100 ms. Repeated exits within one second of startup back off to 1, 2, 4, 8, 16, then at most 30 seconds; running for at least one second resets the delay. Nonpersistent terminals retry only until their window or preview is dismissed. The final screen remains visible while waiting. `terminal_restart` restarts immediately (optionally `--name=system`). Removing or replacing a declaration and quitting Flash cancel pending retries. State lasts until Flash quits.

Hover placement remains centered below the pointer and clamped to the hovered screen. Leaving the originating status segment hides an ordinary preview immediately. Click a popup label to pin it and focus its terminal; it then stays anchored while the pointer moves into the popup or over other segments. Clicking its label again closes it and restores the previous application. Clicking another popup label switches views. Existing links retain their normal action; Option-click a link to pin its popup. Menu reveal, focus loss, removed anchors, and other Flash surfaces dismiss presentation without ending the child.

Terminal focus has its own mode. Global mappings are suspended while local terminal mappings run before native copy/paste and terminal input. Pending sequences preserve the order of key presses, releases, and modifier changes; a matched mapping consumes its releases. Replays retain the originating session and restart generation, so a late release cannot enter a replacement child. Only effective INSERT mappings that enter NORMAL are inherited as terminal exit mappings; explicit terminal mappings override them. Plain Escape remains available to the TUI. Exiting through an inherited NORMAL mapping restores the previously focused application. Losing focus to another app does not steal focus back.

Command popups and document popups share the same cell renderer. Documents never spawn children: styled runs become generated VT, while literal control characters are made inert. Replacing a document clears previous content and its history. Long documents can scroll; selecting text and Command-C work in both kinds of popup. Shift-drag selects text even when a TUI requests mouse reporting. Command-V uses Ghostty's paste encoder and respects bracketed paste mode. macOS input-method composition is local to the terminal view.

## Shortcut terminals

`flash terminal_show` opens a fresh login shell in the home directory. Each
invocation creates a new process. `flash terminal_dismiss` closes the focused
terminal and restores the previous application. Exiting a fresh shell starts
a replacement in the same window. Dismissing the window stops and reaps its
child and cancels pending retries.

Declare a named terminal to launch a particular process:

```toml
[terminal.bonsai]
command = ["bonsai", "hq", "--no-open", "--port", "0"]
persistent = true
working_directory = "~"
columns = 120
rows = 36

[mode.normal.mappings]
"'b" = ["flash", "terminal_show", "--name=bonsai"]
# A fresh shell, with no declaration required:
"'t" = ["flash", "terminal_show"]

[mode.terminal.mappings]
"cmd+w" = ["flash", "terminal_dismiss"]
"cmd+r" = ["flash", "terminal_restart"]
```

Named definitions accept `command`, `working_directory`, `env`, `columns`,
`rows`, and `persistent`. The default is `persistent = false` and a 100 × 28
grid: the name then identifies a command template, and each opening gets a
fresh process. With `persistent = true`, Flash starts the session after its
login environment resolves, even when hidden or the status bar is disabled.
Reopening preserves the process, screen, and history. All sessions use
the same automatic restart policy as status popups while owned by Flash.

Windows appear centered on the focused application's screen and clamp to its
available area. One terminal window is presented at a time; changing windows
hides a persistent session and stops a fresh one. Status hover and article
rotation cannot replace a standalone window. Explicitly dismissing a status
popup suppresses reopening until the pointer leaves its segment. Clicking another app dismisses
it without taking focus back. Plain Escape remains available to the process;
terminal mappings and the inherited NORMAL shortcut can close the window.

The Bonsai example suppresses automatic browser opening and chooses an available
port; the TUI runs inside Flash. Its process must remain in the foreground.
Use `flash terminal_show --name=bonsai` from the CLI or `:terminal_show
--name=bonsai` from Flash's command line. `terminal_restart --name=bonsai`
restarts the named persistent session. A nonpersistent name resolves to the
focused instance of that template; without a name it restarts the focused
terminal, including a fresh shell.

## Hover diagnostics

Set `[debug] log_level = "debug"` (or `"trace"`) to record hover diagnostics in
`~/Library/Logs/Flash/flash.log`. The existing log rotation retains three older
10 MiB segments. Test runs leave the resident log alone: their default disk
logging is disabled, while stderr and in-memory test sinks remain available.
File-writer tests use temporary destinations. Diagnostics include:

- `Status hover regions changed`: per-window region indices, hashed popup IDs,
  local rectangles, and content byte counts.
- `Status hover target changed`: entry/exit or a changed target, pointer
  position, link hit, popup ID, and whether the window is passing mouse input
  through. Repeated movement within the same target is suppressed.
- `Status popup presentation changed` / `Status popup layout changed`: the
  same hashed ID, dismissal reason, terminal grid, cache reuse, frame readiness,
  rendering state, and actual panel visibility.
- `Status terminal state changed`: terminal child lifecycle records, including
  PID, exit status, and spawn failure category and reason, without command arguments or output.
- `Status terminal restart scheduled`: attempt number and retry delay under
  `core:StatusTerminalRegistry.restart`, correlated by hashed popup ID.
- `Status menu reveal changed`: whether the native menu bar has taken over
  input. `Status inline popup rejected` reports an invalid or oversized marker.

These records exclude article text, URLs, terminal contents, and raw popup
names. Feed refresh outcomes and plugin lifecycle events remain under
`source = "plugin:feed"`. A healthy plugin with no hover target points to hit
regions or input routing; a target with no visible panel points to presentation.
Mouse-enter and stationary refresh must carry the same compiled popup document
through coordinate conversion, preserving literal text and styles.

## Ownership and resource bounds

`FlashTerminal` owns a serial worker queue per terminal. The queue performs PTY I/O, VT parsing, input encoding, resize, and immutable frame extraction. A C-only `forkpty`/`execve` boundary prepares the controlling terminal; Swift never runs in the post-fork child. The child resets signal dispositions and closes unrelated inherited descriptors. Flash reports executable or working-directory failures through the session state.

Output is parsed while hidden. Frame updates coalesce with one-shot work to at most about 30 Hz under continuous output, and hidden views do not draw. There is no PTY polling loop. A visible blinking cursor or blinking text uses a local half-second redraw timer, which stops when hidden. Scrollback is capped at approximately 2,000 lines and 4 MiB; libghostty applies limits at its internal page boundaries. The input queue is bounded at 4 MiB; an input batch exceeding available capacity reports rejection without recording its contents.

Flash owns the child and its terminal process groups. Stop sends hangup and termination, allows a bounded grace period, escalates to kill, then closes the
PTY before a bounded nonblocking reap. Exceptional kernel
exit delays are tracked by an in-process reaper and logged; they never block
the main thread indefinitely. The registry retains retiring sessions until
asynchronous stop completes, and application shutdown stops active and retiring
children. Commands should remain in the foreground; popup declarations are not a mechanism for launching detached services.

## Build and verification

The backend pins libghostty-vt to `b0c421fcd2e290629d4285c181b52fe2f2095f06` and Zig 0.16.0. `Scripts/build-ghostty.sh --dev` downloads the pinned source with a SHA-256 check and caches a native macOS static XCFramework under `build/ghostty`. `--release` combines arm64 and x86_64 into the macOS slice. It does not build or depend on the Ghostty application. The Ghostty MIT notice ships in the application resources.

Run the bootstrap before direct SwiftPM commands on a fresh checkout:

```sh
mise install
./Scripts/build-ghostty.sh --dev
swift test --filter TerminalTests
```

The app build, CI, plugin conformance, and GUI integration entrypoints bootstrap this dependency automatically. Development deployment remains `./Scripts/install.sh --dev`.

`TerminalTests` exercises real PTY startup before any view exists, controlling-terminal dimensions, retained exit screens, input and resize, explicit restart with a new PID, failed spawn, and bounded shutdown/reaping. Unicode grapheme clustering is enabled as the terminal default, including after a reset. Direct VT tests cover Unicode graphemes and wide cells, styling, document replacement and control sanitization, terminal queries, application cursor input, Ctrl-C, Kitty modifier and release events, bracketed paste, alternate screens, and scrollback. Popup placement, immediate preview dismissal, pinned focus, and mapping precedence are covered by the app's separate presentation and mode tests.

## Native status drawing

The status bar consumes the ordered typed format document through `StatusFormatLayout`. Its cells determine painted positions and native closed-range hit areas, including list focus/markers, fill colors, alignment clipping, and absolute-centre overlays. Flash shortens explicitly elastic `#[shrink]` spans before native drawing; unmarked formats retain native trimming. The mode pill requires explicit `#[pill]` metadata. It keeps the original point-based padding and centered label, reserving the longest configured base-mode label. The transient TERMINAL label uses that same width, so entering terminal mode does not shift adjacent segments. Pill backgrounds and interaction areas share the same geometry; native cell rounding must not change their visible shape or spacing.

Each display uses the same pooled layer renderer. Non-ASCII cells have independent origins so font shaping cannot shift subsequent text or interaction rectangles away from native columns. Notched displays suppress centre content and clip other cells and hit areas around the notch margin. Visible blink/breathing effects and cycle transitions use Core Animation.

`monitor = "primary"` selects the display at desktop origin `(0, 0)`. Moving
keyboard focus to another display does not move the bar or reserve status-bar
space there. `monitor = "all"` draws a bar on every display.

Use `#[align=absolute-centre]` for a label at the physical center of the screen. Native tmux `#[align=centre]` instead centers the space remaining between the left and right content, so unequal side widths shift that label.

For the combined SYS dashboard, battery widget, and calendar setup, see the
[ready-to-use configurations](examples/statusbar/README.md).
