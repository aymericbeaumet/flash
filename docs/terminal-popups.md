# Status bar terminals

Named command popups are resident terminals. Flash starts each declaration after its initial login-shell environment resolves, even if the status bar is disabled or no template currently refers to the popup. Hover only presents the existing screen; it does not run a command. One named session is shared across displays.

```toml
[statusbar]
template = "#[popup=system]System#[nopopup]"

[statusbar.popup.system]
command = ["ytop"]
columns = 80
rows = 24
# working_directory = "~/workspace"
# env = { EXAMPLE = "value" }

[mode.terminal.mappings]
"cmd+r" = ["flash", "terminal_restart"]
```

Commands are argv arrays, with the same environment and path resolution as other Flash commands. Shell syntax needs an explicit shell, for example `["/bin/sh", "-c", "exec ytop"]`. Commands inherit the resolved environment and use `TERM=xterm-256color` and `COLORTERM=truecolor`. Configured foreground and background colors apply before spawning, so startup terminal queries see the same palette as the popup. A popup has a real controlling PTY with ordinary shell job control, terminal responses, input modes, alternate screens, and resize notifications.

The terminal starts at its configured grid, defaulting to 80 columns by 24 rows. Presentation clamps it to the available screen and sends a real PTY resize. Hiding it preserves the last nonzero grid. Font, colors, placement, and size changes preserve the child; changing command, working directory, or environment replaces only that named session. Removing a declaration stops it. Exited commands retain their final screen and exit status until explicit `terminal_restart` (optionally `--name=system`) or a changed declaration. State lasts until Flash quits.

Hover placement remains centered below the pointer and clamped to the hovered screen. A popup is visible only while the pointer is over its originating status segment. Leaving that segment hides it immediately, including when moving down toward the popup; the popup body cannot retain or revive it. Menu reveal and other Flash surfaces also dismiss presentation without ending the child.

Terminal focus has its own mode. Global mappings are suspended while local terminal mappings run before native copy/paste and terminal input. Pending sequences preserve the order of key presses, releases, and modifier changes; a matched mapping consumes its releases. Replays retain the originating session and restart generation, so a late release cannot enter a replacement child. Only effective INSERT mappings that enter NORMAL are inherited as terminal exit mappings; explicit terminal mappings override them. Plain Escape remains available to the TUI. Exiting through an inherited NORMAL mapping restores the previously focused application. Losing focus to another app does not steal focus back.

Command popups and document popups share the same cell renderer. Documents never spawn children: styled runs become generated VT, while literal control characters are made inert. Replacing a document clears previous content and its history. Long documents can scroll; selecting text and Command-C work in both kinds of popup. Shift-drag selects text even when a TUI requests mouse reporting. Command-V uses Ghostty's paste encoder and respects bracketed paste mode. macOS input-method composition is local to the terminal view.

## Ownership and resource bounds

`FlashTerminal` owns a serial worker queue per terminal. The queue performs PTY I/O, VT parsing, input encoding, resize, and immutable frame extraction. A C-only `forkpty`/`execve` boundary prepares the controlling terminal; Swift never runs in the post-fork child. The child resets signal dispositions and closes unrelated inherited descriptors. Flash reports executable or working-directory failures through the session state.

Output is parsed while hidden. Frame updates coalesce with one-shot work to at most about 30 Hz under continuous output, and hidden views do not draw. There is no PTY polling loop. A visible blinking cursor or blinking text uses a local half-second redraw timer, which stops when hidden. Scrollback is capped at approximately 2,000 lines and 4 MiB; libghostty applies limits at its internal page boundaries. The input queue is bounded at 4 MiB; an input batch exceeding available capacity reports rejection without recording its contents.

Flash owns the child and its terminal process groups. Stop sends hangup and termination, allows 200 ms for exit, then escalates to kill and reaps the child. The registry retains retiring sessions until asynchronous stop completes; application shutdown waits for active and retiring children to be reaped. Commands should remain in the foreground; popup declarations are not a mechanism for launching detached services.

## Build and verification

The backend pins libghostty-vt to `b0c421fcd2e290629d4285c181b52fe2f2095f06` and Zig 0.16.0. `Scripts/build-ghostty.sh --dev` downloads the pinned source with a SHA-256 check and caches a native macOS static XCFramework under `build/ghostty`. `--release` combines arm64 and x86_64 into the macOS slice. It does not build or depend on the Ghostty application. The Ghostty MIT notice ships in the application resources.

Run the bootstrap before direct SwiftPM commands on a fresh checkout:

```sh
mise install
./Scripts/build-ghostty.sh --dev
swift test --filter TerminalTests
```

The app build, CI, plugin conformance, and GUI integration entrypoints bootstrap this dependency automatically. Development deployment remains `./Scripts/install.sh --dev`.

`TerminalTests` exercises real PTY startup before any view exists, controlling-terminal dimensions, retained exit screens, input and resize, explicit restart with a new PID, failed spawn, and bounded shutdown/reaping. Unicode grapheme clustering is enabled as the terminal default, including after a reset. Direct VT tests cover Unicode graphemes and wide cells, styling, document replacement and control sanitization, terminal queries, application cursor input, Ctrl-C, Kitty modifier and release events, bracketed paste, alternate screens, and scrollback. Popup placement, immediate anchor-exit dismissal, and mapping precedence are covered by the app's separate presentation and mode tests.

## Native status drawing

The status bar consumes the ordered typed format document through `StatusFormatLayout`. Its cells determine painted positions and native closed-range hit areas, including list focus/markers, fill colors, alignment clipping, and absolute-centre overlays. Flash shortens explicitly elastic `#[shrink]` spans before native drawing; unmarked formats retain native trimming. The mode pill requires explicit `#[pill]` metadata. It keeps the original point-based padding and centered label, reserving the longest configured base-mode label. The transient TERMINAL label widens the pill only while active. Pill backgrounds and interaction areas share the same geometry; native cell rounding must not change their visible shape or spacing.

Each display uses the same pooled layer renderer. Non-ASCII cells have independent origins so font shaping cannot shift subsequent text or interaction rectangles away from native columns. Notched displays suppress centre content and clip other cells and hit areas around the notch margin. Visible blink/breathing effects and cycle transitions use Core Animation.

Use `#[align=absolute-centre]` for a label at the physical center of the screen. Native tmux `#[align=centre]` instead centers the space remaining between the left and right content, so unequal side widths shift that label.
