# Popups

A popup is a small window Flash shows over your apps: under a status-bar label
while you hover it, pinned by a click, or standalone in the middle of the
screen through `enter_terminal_mode`. Every popup runs in a real PTY terminal.
There is one namespace, `[popup.<name>]`, and each popup is one of two kinds:

- a **text popup** sets `text`, a [status format](status-format.md). Flash
  evaluates it with the same sources and plugins as the bar and shows the
  result in the system `less` pager.
- a **terminal popup** sets `command`, an argv array Flash runs in the popup's
  own PTY: `btop`, a shell, a feed reader, a TUI.

```toml
[popup]                      # the chrome every popup shares
bg = "#242933F2"
padding = 10

[popup.date]                 # a text popup
text = "#{flash.calendar}"

[popup.btop]                 # a terminal popup
command = ["btop"]
size = "90%x85%"
persistent = true

[statusbar]
enabled = true
template = "#[align=right]#[popup=btop]CPU MEM#[nopopup] #[popup=date]%H:%M#[nopopup]"

[mode.normal.mappings]
"'t" = ["flash", "enter_terminal_mode"]               # the built-in terminal popup
"'b" = ["flash", "enter_terminal_mode", "--name=btop"]
```

See the [example status strip](examples/statusbar/README.md) for a complete
configuration.

## Style

`[popup]` holds the style keys every popup shares, hover previews and
standalone windows alike. Every other `[popup]` key is a table, a named popup;
TOML types tell the two apart, and an unknown scalar key is diagnosed with the
closest style key.

| Key | Default | Meaning |
| --- | --- | --- |
| `fg` | `#D8DEE9` | Default text colour; `#[fg=…]` in a text popup overrides it |
| `bg` | `#2E3440F2` | Surface and terminal background |
| `border` | `#4C566A` | Border colour |
| `border_size` | `1` | Border width, 0–12 points |
| `corner_radius` | `8` | 0–64 points |
| `padding` | `8` | Space around the terminal, 0–64 points |
| `min_width` | `480` | Narrowest a text popup gets, 80–2000 points |
| `max_width` | `750` | Widest a text popup grows, 80–2000 points |
| `offset` | `8` | Gap between the status bar and a hover popup, 0–64 points |

Colours are `#RRGGBB` or `#RRGGBBAA`. Terminal text is opaque, so a translucent
`fg` is mixed over `bg`. At the 13-point font with 10-point padding and a
one-point border, the 480-point `min_width` fits 50 content columns and the
750-point `max_width` 80, enough for the three-month [calendar](calendar.md).

## Declaring popups

A popup name uses letters, digits, `_` and `-`. Each `[popup.<name>]` sets
exactly one of `text` or `command`; a later file's `[popup.<name>]` replaces
the whole definition. An invalid declaration is diagnosed and keeps the
previous file's definition; on reload, a terminal popup whose new declaration
is invalid keeps running on its last good one until it is fixed or removed.

A text popup takes only `text`. Its body keeps its newlines and supports the
whole status format: colours, bold, italics, underline, dim, reverse, links. It
reads the values the bar already collects, so opening it starts no collector.
`#[popup=inline:<percent-encoded-body>]` lets a dynamic row carry its own body
instead of naming a popup. A text popup is as wide as its widest line, from
`min_width` up to `max_width` and the screen; longer lines wrap and taller
content scrolls in the pager. The floor leaves room for the pager's `/` search
prompt and for wider values after Command-R.

A terminal popup takes:

| Key | Meaning |
| --- | --- |
| `command` | argv array; required |
| `cwd` | working directory |
| `env` | table of extra environment variables |
| `size` | `"COLUMNSxROWS"`, default `"100x28"` |
| `persistent` | `true` for one long-lived process; default `false` |

Commands use the shared [environment and path resolution](configuration.md#executables-and-opaque-arguments):
the login-shell environment, `$VAR` and a leading `~` expanded on every argument
and `cwd`, and only the executable and `cwd` resolved against the defining
file. Set `cwd = "."` for arguments relative to that file. Shell syntax needs
an explicit shell, for example `["/bin/sh", "-c", "exec btm"]`. Every session
exports `TERM=xterm-256color` and `COLORTERM=truecolor`; the inherited
`NO_COLOR` is removed, and an explicit `env = { NO_COLOR = "1" }` opts that
popup out. The configured colours apply before the process starts, so its
first terminal queries see the popup's palette. A popup has a controlling PTY
with ordinary job control, terminal responses, input modes, alternate screens,
and resize notifications.

Each side of `size` is a cell count from 1 to 1000 or a percentage from 1% to
100% of the visible frame of the screen the popup shows on, for example
`"120x36"`, `"90%x85%"` or `"120x80%"`. A percentage sizes the whole popup,
padding and border included. Every grid is clamped to the screen. A popup sized
in percentages resizes its PTY when it shows on another screen and when its
screen's visible frame changes (a display change, the menu bar, the Dock);
hidden ones refit to the main screen. Changing `size`, colours or fonts keeps
the process; changing `command`, `cwd`, `env` or `persistent` replaces it.
Removing a declaration stops it.

### The terminal popup

`config.default.toml` declares one terminal popup, `terminal`: a fresh login
shell, `["$SHELL", "-l"]`, in the home directory. `enter_terminal_mode` without
a name opens it. Redeclare `[popup.terminal]` to change it.

## Lifecycles

A terminal popup has one of two lifecycles; there is one instance per name
either way.

**Persistent** (`persistent = true`) popups start once the login environment
resolves, even with the status bar disabled or no label referring to them.
Showing attaches to the running process, and hiding keeps it, with its screen
and history; its output is parsed while hidden. When the process exits, Flash
restarts it: the first retry waits 100 ms, and repeated exits within a second
back off to 1, 2, 4, 8, 16, then at most 30 seconds. Running for a second
resets the delay; ten consecutive failed starts park it until an explicit
restart or a definition change. The last screen stays visible, with an
`Exited (N) · restarting automatically` footer, while it waits.

A command that cannot start at all fails the same way on every retry, so it
skips the backoff and waits: a bare name no directory of the login `PATH`
holds (`btop: command not found · install it, then Command-R`), an executable
`execve` refuses, or a working directory that cannot be entered. No child is
forked for a missing command. Command-R (`popup_restart`) first rereads the
login environment, so a tool installed since Flash started is found, and a
configuration reload retries every such persistent popup once the environment
is reread. `flash doctor` lists popup commands missing from the login `PATH`.

**Fresh** popups (the default) run one process per showing, and dismissing
the popup stops it. A process you end by typing into it (`exit` in a shell,
`q` in btop) closes the popup. One that ends by itself before any key, paste
or mouse report reached it leaves the popup open on its last screen until you
dismiss it as usual, with an `Exited (N)` footer when the status is not 0;
scrolling its history does not count. That screen is final, so the popup drops
its blank trailing rows and its cursor and fits the output. No process is left to read keys, so a
focused one closes on a key press (Command-C still copies, and Command-V does
nothing); `popup_restart` (Command-R) runs it again in place.

A fresh popup a user can open is **prewarmed**: Flash keeps its next process
running hidden, so showing it attaches to a live screen instead of waiting for
the program to start. The next process starts once the previous one is gone,
so a program holding a lock (newsboat's cache) can start again. A popup counts
as openable when it appears in a `#[popup=<name>]` marker of the enabled bar's
template or text popups, in a `[statusbar.click]` `enter_terminal_mode`
action, or in an `enter_terminal_mode` mapping of any scope
(`enter_terminal_mode` without a name counts for `terminal`). Any other fresh
popup starts when it is opened: on `enter_terminal_mode`, or on hover after a
150 ms dwell with the pointer still on its label, so sweeping across the bar
never forks one child per label.

A prewarmed process that ends before it is ever shown is a one-shot report:
started ahead, it would be stale by the time it shows. Flash does not replace
it; until the popup's `command`, `cwd`, `env` or `persistent` changes, that
popup starts when opened, like one nothing refers to, so each showing runs a
current report.

[tokscale](https://github.com/junhoyeo/tokscale)'s `usage` prints your AI
subscriptions' quotas and exits, so it makes a one-shot report popup. It is
yours to install, for example with `npm i -g tokscale`, mise or bun; Flash does
not install it.

```toml
[popup.ai-usage]             # a one-shot report
command = ["tokscale", "usage"]
size = "68x16"
```

When the tool has an interactive view of its own, prefer it in a persistent
popup: it shows at once, keeps its state, and refreshes itself. The
[example status strip](examples/statusbar/flash.toml) runs tokscale's TUI that
way.

A text popup's pager is fresh too: it starts when the popup shows and stops,
removing its snapshot file, when it closes.

## Showing popups

**Hover** previews the label's popup, placed once from the label, not the
pointer: centred on the label's text (the span the hover wash covers, without
its outer separator spaces), its top `offset` points below the bar, and clamped
to the screen that bar is on. Moving the pointer along the label never moves
it; moving onto another label switches to that label's popup, hung from that
label. A refresh or a size change keeps it centred on its label, and when the
bar re-lays out (a value gets wider) it follows the label. Leaving the label
hides the preview immediately, and so do a click anywhere outside Flash's
status bar, a change of focused app or window, a bare Escape (swallowed while a
preview shows, except in the command line and during hints), and
`enter_normal_mode`; the preview then stays closed until the pointer leaves the
label. Hover works anywhere in the band, its top point row included, where a
pointer thrown at the bar comes to rest. The native menu bar owns the band only
while it is revealed under the pointer: the bar then shows no wash, preview or
pointing hand, a reveal clears any already showing, and hover resumes when the
native bar folds away. A hovered text popup refreshes as its values change. The
panel appears with its first frame, so a pager still starting never shows an
empty box; it waits 150 ms at most. A persistent popup kept parsing its output
while hidden, and showing it draws that current screen at once rather than the
one it had when it was hidden.

**Click** a popup label, left or right, to pin it and focus its terminal;
repeated clicks keep it open, and clicking another label switches popups.
Labels with a click action or link keep their left-click action; right-click
or Option-click pins their popup. Pinning leaves a preview where it is, and a
pinned popup stays hung from its label while the pointer moves.

**`enter_terminal_mode --name=<name>`** shows a popup standalone, centred on
the focused application's screen and focused. Without a name it opens
`terminal`. A text popup shows the document the status bar last evaluated, so
it needs `[statusbar] enabled = true`; without it Flash logs a warning and
shows nothing. One popup shows at a time: entering another hides a persistent
one and stops a fresh one, and entering the popup already focused does
nothing. Hover and article rotation never replace a standalone popup.

A focused popup, whether entered with `enter_terminal_mode`, pinned from the
bar or clicked, puts Flash in TERMINAL mode (the mode label is
`mode.labels.terminal`): its terminal receives every key its
`[mode.terminal.mappings]` leave alone, and plain Escape reaches the program.
`leave_mode` leaves TERMINAL like any other mode: it closes the popup and
restores the previous mode and application. The default mappings are:

```toml
[mode.terminal.mappings]
"cmd+q" = ["flash", "popup_quit"]    # stop the process
"cmd+r" = ["flash", "popup_restart"] # restart it now
"cmd+w" = ["flash", "leave_mode"]    # close the popup
```

| Verb | Effect |
| --- | --- |
| `enter_terminal_mode [--name=N]` | Show `N` (default `terminal`) standalone and focus it |
| `leave_mode` | Close the focused popup and restore the previous mode and app |
| `popup_restart [--name=N]` | Restart the focused or named popup's process now |
| `popup_quit [--name=N]` | End the focused or named popup's process |

`popup_restart` works for every kind: a text popup rereads the latest collected
values. `popup_quit` ends a persistent process, which then restarts
automatically; a fresh popup or a pager closes. Only effective INSERT mappings
for `enter_normal_mode` or `leave_mode` are inherited as terminal exit
mappings; explicit terminal mappings override them. Exiting through an
inherited NORMAL mapping restores the previously focused application; losing
focus to another app does not steal it back. Menu reveal, focus loss, removed
labels and other Flash surfaces dismiss a hover or pinned popup. See
[popup input](normal-mode.md#popup-input) for sequences and key routing.

A focused text popup holds its content and search stable: reopen it or press
Command-R to consume the latest values. Selecting text and Command-C work in
every popup. Shift-click opens HTTP(S) links, including printed URLs and OSC 8
hyperlinks, without forwarding the click to the program; wrapped URLs stay one
link, and Shift-drag selects even when a TUI requests mouse reporting.
Command-V uses Ghostty's paste encoder and respects bracketed paste. macOS
input-method composition stays local to the popup.

## Diagnostics

Set `[debug] log_level = "debug"` (or `"trace"`) to record popup diagnostics in
`~/Library/Logs/Flash/flash.log`:

- `Status hover regions changed` and `Status hover target changed`: hover
  regions, pointer targets, whether the window passes mouse input through and
  whether the native menu bar suppressed the hover.
- `Status popup presentation changed` / `Status popup layout changed`:
  dismissal reason, terminal grid, frame readiness, rendering state and panel
  visibility.
- `Status terminal state changed`: PID, exit status, and spawn failure
  category and reason, under `core:StatusTerminalRegistry.lifecycle`.
- `Status terminal restart scheduled`: attempt and delay of a persistent
  restart, under `core:StatusTerminalRegistry.restart`; `Status popup
  prewarmed` marks each prewarmed start, and `Status popup starts on show` a
  prewarmed process that ended before any showing.
- `Status menu reveal changed`, `Status hover eligibility changed` and
  `Status inline popup rejected`.

Records carry a hashed popup ID; they exclude popup names, text, URLs, terminal
contents and command arguments. A healthy plugin with no hover target points to
hit regions or input routing; a target with no visible panel points to
presentation.

## Internals

### Ownership

`StatusTerminalRegistry` owns every popup session on the main thread, keyed by
popup name, with an explicit kind: `pager` (a text or inline popup's `less`
over a private snapshot file) or `terminal` (a configured command). A terminal
popup's lifecycle is `persistent` or `fresh`. `StatusPopupController` owns only
presentation — hidden, preview, focused, or standalone — and places a label's
popup with `OverlayPanel.statusBarPopupFrame`, a pure function of the label's
span, the popup size, the screen's visible frame and `offset`; a refresh
re-hangs a shown popup from the nearest span of the same name. It tells the
registry when a showing starts (`open`, `preparePager`) and, exactly once, when
it ends (`hide`); the registry decides from the kind and lifecycle whether that
stops the process. One restart mechanism, a per-name backoff with one pending work
item, revives a persistent process. A fresh process that ends by itself while
showing stays registered, exited, until `hide`; `TerminalSession.receivedInput`
tells a typed exit, which releases it at once, from a report. Removing,
replacing or reloading a declaration, and quitting Flash, cancel pending
restarts; replies carry the session and restart generation, so a late callback
never mutates a replacement.

The configuration reload computes one set of terminal popup names
(`Config.terminalPopupNames`) for the status bar's hover regions and the
hover handlers, and one prewarm set (`Config.prewarmedPopupNames`).

### Sessions and frames

`FlashTerminal` owns a serial worker queue per terminal. The queue performs PTY I/O, VT parsing, input encoding, resize, and immutable frame extraction. A C-only `forkpty`/`execve` boundary prepares the controlling terminal; Swift never runs in the post-fork child. The child resets signal dispositions and closes unrelated inherited descriptors: the parent enumerates its open descriptors before `fork`, and the child closes every number up to the highest plus 64 of slack for descriptors other threads open meanwhile, using only `close`. It never sweeps the whole descriptor table, which a raised `RLIMIT_NOFILE` (184,320 descriptors under a login shell's unlimited `ulimit -n`) made cost about 165 ms per spawn. Flash reports executable or working-directory failures through the session state.

Hidden sessions keep running and their output is parsed, but no frame is built for it: a session only snapshots its grid and hops to the main thread while a visible view wants frames (`TerminalSession.setWantsFrames`), and re-showing publishes one frame immediately. Frames publish on the leading edge: output after a quiet period is snapshotted at once, and only a burst inside the 16 ms interval waits for its end, so a keystroke echo never pays a coalescing window and continuous output settles at about 60 Hz. Viewport scrolls share the same coalescing. A snapshot visits only the rows libghostty reports dirty and reads each with one bulk getter per cell (`ghostty_cell_get_multi` over the row's raw cells) plus style, grapheme, and hyperlink lookups only where the row's flags call for them. Rows are shared copy-on-write values of 20-byte cells with per-row grapheme and hyperlink tables and their own wrap and blink flags; a reread row equal to its predecessor keeps the previous storage, and a snapshot with nothing visible moved is not published at all. Reapplying the colours already in effect, which every view bind and configuration apply does, is free. Hidden views do not draw. There is no PTY polling loop and no redraw timer.

Scrollback depends on the kind: persistent popups keep about 2,000 lines and
4 MiB, fresh popups 1,000 lines, and pagers none, since `less` pages on the
alternate screen; libghostty applies the caps at its page boundaries. The input
queue is bounded at 4 MiB; an input batch exceeding available capacity reports
rejection without recording its contents. Key and mouse encoding reuse one
libghostty event each and reread terminal modes only after output or a reset
changed them.

### Pagers

A text popup's document becomes terminal escape sequences — styled runs and
OSC 8 links, with literal control characters made inert — in a private
registry-owned snapshot file read by `/usr/bin/less -R --mouse`. Snapshot files
are written on a utility queue only when their bytes change; dismissal, startup
failure and shutdown remove them with their temporary directories. The pager
grid is measured from the document: printable ASCII takes one cell per byte
without sanitizing, and anything else goes through the terminal's width
tables. `less` keeps its last row for the prompt; a hover preview clips it, a
focused pager keeps it for `/` search and messages.

### Stopping

Flash owns the child and its terminal process groups. Stop sends hangup and termination, allows a bounded grace period, escalates to kill, then closes the
PTY before a bounded nonblocking reap. Both 200 ms waits block on the kernel's
exit event (`kqueue`) rather than sleeping between polls, so a stop returns as
soon as the child is gone. Application shutdown stops every active and retiring
session at once through `TerminalSession.shutdown(_:)`, each on its own queue,
so quitting takes as long as the slowest child rather than the sum.
Exceptional kernel exit delays are tracked by an in-process reaper, which reaps
the child when the kernel reports its exit (a process-exit dispatch source, no
retry timer), and logged; they never block the main thread indefinitely. A
child's exit event is followed by a blocking reap, which waits out the
moment between the kernel's report and the child becoming reapable instead of
re-checking on a timer. The registry retains retiring
sessions until their asynchronous stop completes. Commands should remain in
the foreground; popups are not a mechanism for launching detached services.

### Drawing

The terminal view draws each row in its own Core Animation layer and repaints
exactly the rows whose contents, selection, or configuration changed; a
layer-backed view would merge several dirty rects into their bounding box.
Row layers are opaque and draw asynchronously, so a repaint is recorded on the
main thread and rasterised off it. Backgrounds paint as merged runs of one
colour and cells on the terminal's own background need no fill at all. Every
glyph is placed at `column × cellWidth` with `CTFontDrawGlyphs`, one call per
run of a font variant and colour, from a per-variant scalar-to-glyph cache; a
scalar the monospaced font lacks resolves once to a fallback font's glyph
(including colour emoji), clipped to its cells. Only grapheme clusters and
scalars no font covers use a cached Core Text line in their own clipped cell.
Text therefore never drifts from the integral cell grid that backgrounds,
selection, the cursor, and hit testing share. Glyph, line, and colour caches
are bounded and retire their older half instead of wiping when full. The cursor
is its own layer drawn as an inverted cell, and blinking text draws in a
transparent layer over its row; both blink through an opacity animation that
Core Animation runs in the render server, without a timer or a redraw. The
`FlashTerminal` and `CFlashTerminal` modules compile optimized in the
incremental dev build too, so the daily-driver bundle runs the same per-cell
code as a release build.

### Build and verification

The backend pins libghostty-vt to `b40acce58dcf77df52231c3798ea58e924647c89` and Zig 0.16.0, built ReleaseFast. `Scripts/build-ghostty.sh --dev` downloads the pinned source with a SHA-256 check, removes retired revisions, and caches a native macOS static XCFramework under `build/ghostty`. `--release` builds the arm64 and x86_64 slices in parallel and combines them into the macOS slice. Finished slices are stamped per architecture and reused without invoking Zig, and a universal framework for the pinned revision already satisfies `--dev`, so alternating release and development builds does not rewrite the framework or relink SwiftPM products. The x86_64 slice uses Zig's macOS baseline (core2): Ghostty's build replaces a macOS target with its generic macOS target on macOS hosts, so a `-Dcpu` model has no effect. CI caches only the stamped XCFramework. The script does not build or depend on the Ghostty application. The Ghostty MIT notice ships in the application resources.

Run the bootstrap before direct SwiftPM commands on a fresh checkout:

```sh
mise install
./Scripts/build-ghostty.sh --dev
swift test --filter TerminalTests
```

The app build, CI, plugin conformance, and GUI integration entrypoints bootstrap this dependency automatically. Development deployment remains `./Scripts/install.sh --dev`.

`TerminalTests`, `TerminalLinkTests`, `TerminalSnapshotTests`, and
`TerminalRenderingTests` exercise real PTY startup, styled and Unicode output,
link interaction, redraws, hidden-frame suppression, session rebinding,
controlling-terminal dimensions, retained exit screens, input and what counts
as received input, resize, explicit restart, failed spawn, and bounded
shutdown and reaping. Direct VT tests cover incremental snapshots, terminal
queries, application cursor input, Ctrl-C, Kitty modifiers and releases,
bracketed paste, alternate screens, and scrollback. `TerminalBenchmarkTests` prints `[terminal-bench]` throughput lines
for VT parsing, snapshots, drawing, and PTY spawns (`FLASH_TERMINAL_BENCH_MB`
scales the parsed workload). `StatusTerminalRegistryTests` cover both
lifecycles, prewarming and one-shot reports started on show, the persistent
backoff, typed exits, kinds changing on reload, screen refits, the exported
terminal environment and parallel shutdown; `StatusPopupControllerTests` and
`OneShotTerminalTests` cover pager ownership and cleanup, placement,
percentage sizes across screens, standalone text popups, preview dismissal,
pinned focus, kept report screens and their exit footers, and crash recovery
in every presentation. `StatusPopupPlacementTests` keep a label's popup on its
label through pointer moves, label switches, refreshes, resizes, relayouts,
pinning and clamping at both screen edges.
