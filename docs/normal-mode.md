# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Defaults map keys to high-level actions, never to raw key chords: each action
resolves in the focused app's context (see [source actions](#source-actions)),
and an app without the action gets nothing. Other tab, pane, archive,
find-match, document-URL and mark commands remain available for explicit
mappings.

- `h` / `l` scroll left/right. `ctrl+e` / `ctrl+y` send a mouse-wheel scroll
  down/up by 3 lines; `ctrl+d` / `ctrl+u` send 20 lines down/up. Configure these
  amounts with `[mode] scroll_step_lines` and `scroll_page_lines`, and set
  `scroll_smooth_ms` to spread each scroll over that many milliseconds.
- `gg` / `G` go to the top/bottom.
- `u` undoes and `ctrl+r` redoes. Bare `d`, `j` and `k` are unbound.
- `y` copies immediately and `p` pastes.
- `/` opens Find (`app_find`, Cmd-F) and enters INSERT, so typing goes to the
  find field.
- `x` closes the current tab (`tab_close`); `X` reopens the last closed one
  (`tab_reopen`). Inside tmux `x` closes the tmux window after tmux's own
  confirmation. `X` acts in browsers and editors; tmux, terminals and Finder
  keep no closed tabs, so there it does nothing.
- `r` reloads (`app_reload`); `R` hard-reloads (`app_reload --force`).
  Browsers use their own chords (Safari's hard reload is Cmd-Option-R) and
  tmux refreshes its client. Other apps, terminals included, do nothing:
  Cmd-R replies in Mail and runs in Xcode.
- `[a` / `]a` cycle previous/next app in MRU order.
- `[t` / `]t` switch to the previous/next tab (`tab_previous` / `tab_next`);
  repeat the final `t` to keep switching. Inside tmux they switch tmux windows;
  elsewhere the app's own chord (Control-(Shift-)Tab in Messages), else
  Cmd-Shift-[ / Cmd-Shift-], which WhatsApp binds to its previous/next chat.
- `t` opens a tab (`tab_new`): a tmux window inside tmux, Cmd-N in editors
  whose Cmd-T searches symbols, nothing in Notes, TextEdit, Pages and Mail,
  whose Cmd-T opens the Fonts panel, and Cmd-T elsewhere, terminals included.
  Once a tab opened, Flash enters INSERT so typing goes to its address bar or
  shell; where nothing opened, NORMAL stays.
- `g1`–`g9` select a tab by position (`tab_select`): a tmux window by ordinal,
  a browser tab through the browsers plugin, a native tab strip through
  Accessibility, else Cmd-1…Cmd-9. These actions preserve NORMAL.
- `g0` / `g^` go to the first tab and `g$` to the last. tmux and plugin
  sources select their own first and last windows; otherwise the first tab is
  Cmd-1, and the last is the chord an app's plugin declares (Cmd-9 in
  browsers).
- `[m` / `]m` move the current tab left/right; repeat `m` to continue moving it.
  Firefox and Chromium browsers use their native Control-Shift-Page Up/Down
  (checked in Chrome; a Chromium browser that drops the chord does nothing).
  Safari, which has no shortcut, moves
  the neighbouring tab across the current one by AppleScript; tmux reorders
  its window.
- `ctrl+o` / `ctrl+i` traverse Flash's movement history.
- `H` / `L` go back/forward in the focused app's own history, as in Vimium:
  Cmd-[ / Cmd-] in browsers, Finder and most apps. Editors where Cmd-[
  outdents use their own chord (Control-Minus in VS Code, Cursor, Zed and
  Sublime Text; Control-Command-Arrow in Xcode). Terminals and apps without
  history (Notes, TextEdit, Pages, Mail) do nothing.
- Lowercase `f` targets discovered clickable elements; uppercase `F` targets a
  screen position through the grid. A lowercase prefix picks the click on
  either surface: none for primary, `s` secondary, `d` double, `m` move.
  So `df` double-clicks an element and `dF` double-clicks a grid position.
- `<leader>s`, then one letter, then a two-character hint jumps to that
  letter in the focused window's visible text (EasyMotion `s`). A lowercase
  letter ignores case; an uppercase letter is exact. Backspace edits the
  letter, Escape cancels, and no match stays silent. `mouse_bigram --move`
  moves the pointer without clicking. The text comes from Accessibility,
  never from screen pixels.
- A prefix letter must not also be a mapping of its own, or that mapping waits
  for `sequence_timeout_ms` before it fires. Triple click therefore ships
  unbound, because `tf` would stall the bare `t` (new tab). To bind `tf` /
  `tF`, remove the default `t` with `"t" = false` in the same table; `tf`
  then fires on its second key with no timeout.
- Primary clicks enter INSERT only on input targets; secondary clicks preserve
  NORMAL. Everything in a terminal emulator (an app a plugin declares in
  `terminal_emulators`) is an input target, so a primary click on any hint
  there — tmux pane, window and link hints included — enters INSERT. A hint click moves the pointer to the target and leaves it there;
  `m` (move) moves it without clicking. With `[hints] restore_pointer = true`,
  every committed click, drag or selection — hint or grid, and `mouse_repeat`
  — puts the pointer back where it was; `m` and `mouse_pointer` still move it.
  NORMAL's vertical scroll keys act at the pointer, so with the option on they
  keep scrolling where the pointer was, not in the area you just clicked; use
  `mf` or `scroll_target` to move it there.
- Terminal link hints add Shift, so `f` opens the link through the terminal.
  The hover and click carry the same modifiers.
- Modifiers held on the final hint key ride the click (`hints.magic_modifiers`,
  and Shift always): `f` then Shift-`<hint>` is a Shift-click, on targets and on
  the grid alike. Link text repeated in a terminal pane resolves to the copy
  under the hint.
- `sF` / `dF` use the [mouse grid](#mouse-grid) for secondary/double clicks.
- `mF` moves the cursor with the mouse grid.
- `?` and `:mappings` open the browser mapping reference for the focused app,
  with both effective plugin-merged and configured mappings, including expanded leader
  bindings and argv mappings.
- `:help` opens the browser help homepage; `:help <topic>` opens a feature guide.

## Mouse grid

`mouse_grid` (`F`) splits the screen like the left half of your keyboard: 4
rows × 5 columns, each cell labelled with the key at the same position in the
`hints.keys` layout's number, top, home and bottom rows. On QWERTY:

```text
+---+---+---+---+---+
| 1 | 2 | 3 | 4 | 5 |
+---+---+---+---+---+
| q | w | e | r | t |
+---+---+---+---+---+
| a | s | d | f | g |
+---+---+---+---+---+
| z | x | c | v | b |
+---+---+---+---+---+
```

Colemak uses `12345` / `qwfpg` / `arstd` / `zxcvb` and Dvorak `12345` /
`',.py` / `aoeui` / `;qjkx`; a literal `hints.keys` gets the QWERTY block, and
`hints.mouse_grid_keys` sets any other matrix. Press the key where you want to
go: the grid zooms into that cell and tiles it with the same keys, so every
step uses the same muscle memory. The last of `hints.mouse_grid_steps` (default
3) clicks, as does any step whose cells reach 18 points. When the clicking
step's cells are smaller than a label, they are drawn as one glued cluster
centred on (and covering) the chosen cell; each click lands on its label.

The grid starts on the display of the focused window, below Flash's status
bar, or on the pointer's display when no window is focused.

| Key | Action |
| --- | --- |
| a grid key | Zoom into that cell; on the last step, click its centre |
| `space` | Zoom into the centre; on the last step, click the centre |
| `return` | Click the centre of the current region now |
| `backspace` | Undo the last grid key (zoom, move, display switch) |
| `cmd-backspace` / `alt-backspace` | Start over on the whole display |
| arrows | Slide the region by its own size, stopping at the display edge |
| `tab` / `shift-tab` | Move to the next / previous display |
| `` ` `` | Toggle cursor-follow (`hints.mouse_grid_cursor_follow`) |
| `escape` | Cancel; a pointer moved by cursor-follow goes back |
| any other key | Cancel |

Modifiers held on the key that clicks ride the click (`hints.magic_modifiers`,
and Shift always), so Shift-`1` Shift-clicks the `1` cell. Command, Control or
Option chords outside the magic modifiers cancel. Every click flag works with
the grid: `--drag` and `--select` pick a first point, then restart on the
whole display for the second; Backspace from there returns to the first
point's step. `--multi` restarts on the same display after each click.

`mouse_grid --bisect` halves the region instead: `h` / `j` / `k` / `l` keep
the left, bottom, top or right half, and `y` / `u` / `b` / `n` (drawn as
quadrants) keep the top-left, top-right, bottom-left or bottom-right quarter.
It ignores the step count and clicks once the kept region is at most 18 points
on both sides, or on `return`; the other grid keys work as above.
`mouse_grid --zoom-to-depth=N` starts N steps deep on the cell under the
pointer, on the pointer's display, stopping while one selection remains;
Backspace walks back out.

## Holding a mouse button

`mouse_button --state=down|up|toggle [--secondary|--middle]` presses or
releases a button where the pointer is; it ships unbound. While a button is
held, every pointer move Flash makes drags it — `mf`, `mF`, `mouse_pointer`
movement, grid cursor-follow — so a keyboard drag works in any app:

```toml
[mode.normal.mappings]
"<leader>v" = ["flash", "mouse_button", "--state=toggle"]
```

Press `<leader>v` over what to grab, `mf` (or `mF`) to the drop point, then
`<leader>v` again to drop. `mouse_pointer`'s `v` toggles the same held
button. Cancelling a Flash overlay (Escape), `leave_mode` and quitting Flash
release it, as does a committed click, drag or selection.

## Movement history

`ctrl+o` and `ctrl+i` move backward and forward across apps and source locations,
including browser tabs and tmux windows. App focus and location-catalog changes
feed the same history. Repeated observations of the same location coalesce;
returning to a location after visiting another remains a chronological stop.
Choosing a new destination after moving backward discards the forward branch.

Locations restore through their owning source. A browser tab restores through
its `flash-browser://tab?pid=…&url=…` route: the browser process and the tab's
URL, or its title when the tab exposes no URL, so a title change keeps the
destination and a restarted browser's stops fail rather than land elsewhere.
Chromium browsers and Safari select the first tab with that URL by
AppleScript; Firefox re-walks its tab strip and presses the match through
Accessibility.
Tmux keeps stable window IDs so reordering a window does not change its history
destination. Apps without a more precise source restore application focus.
The stack does not capture page scroll positions, editor cursor positions, or
terminal scrollback offsets. History is in memory and bounded to 20 stops in
each direction.

## Source actions

Every verb that asks the focused app to do something is a high-level source
action: tabs, panes, reload, archive, back/forward, `gg` / `G`, and the app's
generic commands — `app_undo`, `app_redo`, `app_find`, `app_save`,
`app_print`, `document_open`, `window_new`, `window_close`,
`clipboard_copy`, `clipboard_cut` and `clipboard_paste`, which back `u`,
`ctrl+r`, `/`, `:w`, `:print`, `:e`, `:new`, `:q`, `:copy`, `:cut`, `:paste`,
the yank fallback when no Accessibility selection is exposed, and the paste
that delivers a flashlight answer. No default or bundled mapping sends a raw
chord instead (`send_key` remains an explicit escape hatch). Each action runs
one policy that knows no app and no chord:

1. a source that performs it in the focused app: tmux for the windows and
   panes of the tmux client hosting the focused terminal, the browsers plugin,
   the Accessibility tab strip for `tab_select`;
2. for `window_close`, the focused window's close button (Flash's own step);
3. else the binding a plugin declares for the action in that app
   (`action_bindings`, see [plugin protocol](plugin-protocol.md)): a chord, a
   chord sequence, a menu-bar item pressed through Accessibility, or `false`
   for an app without the action;
4. else Flash's own scrolling for `resource_next` / `resource_previous`
   (wheel lines) and `scroll_top` / `scroll_bottom` (the focused-window
   scroller);
5. else nothing.

The macOS conventions — Cmd-Shift-[ / Cmd-Shift-] switch tabs, Cmd-T opens
one, Cmd-W closes it, Cmd-1…Cmd-9 select one, Cmd-[ / Cmd-] go back/forward,
Cmd-Z / Cmd-Shift-Z, Cmd-F, Cmd-S, Cmd-P, Cmd-O, Cmd-N, Cmd-C / Cmd-X /
Cmd-V — are `""` bindings of the bundled `defaults` plugin, which also
carries the apps that differ (editors, Messages, Xcode, Notes and friends).
Browsers, VS Code and terminals override them in their own plugins. With
`[plugins] disabled = ["defaults"]` those actions do nothing. Reload, reopen,
the last tab, tab moves, panes and archiving have no shared binding: their
chords mean different things across apps, so they act only where a source or
an app-specific binding knows the app. The inspector's Mappings page lists how
each action resolves in the focused app.

A source that claims an action and fails reports `.failed`, and no binding
follows it; a menu item that is missing or disabled fails the same way. App
knowledge lives in manifest data (the `browsers`, `defaults`, `terminals` and
`vscode` plugins), never in host conditionals. A terminal treats a Command
chord a plugin binds for that emulator as bound, like the chords every
emulator binds; any other Command chord is refused (see below), while a menu
press is always allowed.

## Shared mode exit

`leave_mode`, `enter_insert_mode`, `enter_command_mode`, `enter_terminal_mode`,
and `focus_input` ship without default mappings in every scope except
TERMINAL, whose Command-W is `leave_mode`. Bare `a`, `A`, `i`, `I`, `o`, `O`,
and `gi` do not enter INSERT. Users explicitly choose their shortcuts,
including bindings that prefill the command line with `:flashlight`.

NORMAL is hermetic: every unmapped key and modifier chord is swallowed, and
only explicit mappings act. Map a key to the high-level action it stands for;
for a chord no action covers, `send_key` is the explicit escape hatch, or the
user enters INSERT first. The release of a swallowed key is swallowed with it,
because a terminal running the Kitty keyboard protocol encodes key releases to
its pty.

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
digits, and Shift-bracket tab traversal); a chord a plugin binds for that
emulator specifically, such as the bare brackets of the emulators whose splits
live on them, is added. A plugin-wide binding for every app never is, so
`app_save` does nothing in a terminal rather than type an `s`. A refused mapping does
nothing and NORMAL stays.

The four vertical scroll bindings synthesize line-based mouse-wheel events
in every app, including terminals, at the current pointer position. They use
no app-specific scrolling action or Accessibility scroll fallback. The receiving
app handles the event just as it handles a physical wheel. With
`[mode] scroll_smooth_ms` set, one keypress becomes several smaller line
events spread over that duration (at most 300 ms): the first moves at once,
the rest follow at least a frame apart on the click queue, and they add up to
the same lines, so terminals scroll exactly as far. A new scroll, including
`gg` / `G` and `h` / `l`, drops what the previous one has left. `[mode] scroll_step`
continues to set horizontal movement in pixels. `gg` and `G` retain their
source-aware edge behavior. Inside tmux they follow tmux's own wheel routing:
a pane in a mode scrolls that mode (history-top, cancel); a program that
tracks the mouse, such as a full-screen CLI, owns its scrolling and receives
1,000 wheel reports; any other pane enters copy-mode at the top of its history
and is already at its live bottom. Another terminal scrolls 1,000 lines as a
line wheel, like the four vertical bindings.

NORMAL is persistent by default; `enter_normal_mode` takes no persistence
option. Opening Find (`/`) and a new tab (`t`) are the two actions that ask to
type next: once the action reached the app (a source performed it or its chord
was sent) Flash enters INSERT, once however large the count. A claiming source
that failed, an app without the action, a missing app or a chord a terminal
would refuse leave NORMAL in place. Switching tabs and `focus_input` preserve
NORMAL even when the app focuses an editable field. Accessibility focus
notifications never change the mode. A primary `f` hint click enters INSERT
only when its selected target is an input; other hint targets keep NORMAL.
`F` follows the same rule: the grid point is hit-tested before the click, and
only a primary, double or triple click on a text input enters INSERT. Physical
app clicks and an explicit `enter_insert_mode` mapping also hand typing to the
app. A text input is a text-field, text-area, combo-box or search-field role,
or any element with the search-field subrole. In an iOS app (Mac Catalyst or
iPad, such as Messages and WhatsApp) it must also accept keyboard focus: UIKit
reports read-only text such as a message bubble with a text-area role.

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

Each hint or grid session fixes its capture path when it starts
(`KeyboardCaptureTap.sessionCapture`). Under secure input (a focused password
field) macOS hides keys from every tap, so that session takes the key window
instead and typed labels reach Flash, never the password field. A commit hands
focus back by raising its target; a cancel yields activation to the covered
app. `#{flash.secure_input}` and `flash status` show the state, which the tap
refreshes when it reads it for a key; there is no banner and no poll.

Interpreters read keys through `[app] keyboard_layout`'s reference table
(`KeyCharacters.read`, one lookup per key): labels, the grid, pointer and
adjustment keys and NORMAL mappings match by key position under a non-Latin
input source, while `--search` keeps the typed text. The table is rebuilt on
input-source changes and config loads, never per key, and the swallow decision
never reads it.

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
[performance](performance.md). `Scripts/measure-footprint.sh` samples the resident and its children
(CPU, idle wakeups, memory, descriptors) and summarises stalls and log volume
for a before/after comparison.

## Interaction ownership

`ActivationLifecycle` distinguishes discovery, a pending commit, and an active
gesture. A newer hint request replaces discovery or cancels a commit before its
input starts. Once a gesture starts, it finishes its mouse release before the
latest queued activation runs. Cancellation suppresses the old gesture's mode
and UI outcome; an old completion cannot clear a newer operation's state. Dock
and scroll-area discovery use the same ownership tokens as ordinary hints.

`HintSession` owns the selected action and target data. `ActionDispatcher`
owns the one button `mouse_button` or `mouse_pointer`'s `v` holds: a pure
`MouseButtonHold` decides which press and release events each transition
posts, so a press is released exactly once. While it is held, every pointer
move Flash makes posts that button's dragged event; a session reset or
replacement keeps it, so `mouse_button --state=down` then `mf` drags to a
hint. Cancelling a Flash overlay, `leave_mode`, application shutdown and a
committed click, drag or selection release it. Shutdown also waits for finite
synthetic gestures to post their release events. Click repetition
records a pending click only when its generation is still current and input
actually starts.

`CandidateFinderSession` owns warm snapshots, query answers, live results, and
their scoring caches. `CandidateFinderCoordinator` manages the prompt and
publication lifecycle. Live source results stay separate from the warm catalog:
each exact source/query has a token checked before background preparation and
again at publication. Changing or leaving that query clears its rows and rejects
both stale replies and timeout results. Initial snapshot publication never
overwrites the current live-query result.

## Hyper

Holding the NORMAL leader key enters HYPER until that key is released. The
status pill is purple and shows `mode.labels.hyper` (default `HYPER`). Keys
pressed while it is held are read from `[mode.hyper.mappings]`, not from
NORMAL. A key with no hyper mapping can still complete a NORMAL `<leader>`
sequence, so holding the leader and pressing `s` still runs `<leader>s`
when `s` is not a hyper binding. Unmapped keys are swallowed.

Releasing the leader returns to NORMAL. If nothing else was pressed, that
tap arms the `<leader>` prefix: press the leader, release it, then the next
key, and the sequence runs as before. HYPER is only entered from idle
NORMAL. INSERT, the command line, a popup, and an open hint session keep
their own keys. See [configuration](configuration.md).

## Popup input

Every popup is a terminal. TERMINAL sits beside NORMAL, INSERT, COMMAND, and
the momentary HYPER layer: `enter_terminal_mode [--name=<popup>]` enters it by showing the
popup standalone (the built-in `terminal` popup without a name), and clicking a
popup's body or pinning it from the status bar enters it too. Either way the
popup's local terminal view gets focus. `leave_mode` leaves it, closing the
popup. Entering the popup already focused is a no-op; entering another replaces
it. The overlay owns no keyboard input in this mode: the
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
and are replayed exactly once to the terminal that received them; a key press
replayed to a fresh popup whose process has ended closes the popup instead
([lifecycles](popups.md#lifecycles)). Focus and
configuration changes flush unresolved events without dispatching a pending
command. `repeat = true` retains the explicit final-key repetition behavior.

Local mappings run before native copy/paste and terminal key encoding. Text
popups use the same focus mode for selection, copying, and scrolling. Leaving via
`enter_normal_mode` dismisses the popup and activates the captured external app
before NORMAL recapture. Losing popup focus restores the prior base mode without
activating a different app. A popup's lifecycle, not its focus or visibility,
decides how long its process lives; see [popups](popups.md#lifecycles).

`leave_mode` provides one configured exit across surfaces. It dismisses a popup,
text or terminal alike, and restores its prior base mode/app (the default
`[mode.terminal.mappings]` bind it to Command-W), restores the saved mode from command or
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
  `f` and `F`): a text input, or anything in a declared terminal emulator;
- `app_find` (`/`) or `tab_new` (`t`) once it reached the app.

Other normal commands, focus changes and app activation preserve NORMAL.
Moving the pointer, dragging, or selecting with the grid does not request INSERT.
A multi-click session ends when its click enters INSERT. Otherwise
`mouse_target --multi` discovers the app's targets again after each click, so
controls the click revealed get hints and removed ones lose theirs; a target
that is still there keeps its label. The previous labels stay drawn until the
new set replaces them, and an app left with no targets ends the session.
Use `leave_mode` / `enter_normal_mode` to return from INSERT to NORMAL.

```toml
[mode.all.mappings]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"alt+space" = ["flash", "enter_terminal_mode"]
```

Closing a popup or command surface may restore its saved INSERT mode.
