# Changelog

Each released version's section becomes its GitHub release notes when CI
publishes it ([releases](docs/release.md)). Renamed configuration gets no
compatibility shims: `flash config check` rejects the old spelling, names the
command it most likely meant, and the upgrade notes below say what to write.

## Unreleased

### Fixes

- Enlarge the calendar's analog clock and animate its second hand while hovered,
  without keeping a second-by-second clock running for hidden popups.
- Keep a focused terminal popup open while other status-bar hover previews
  appear, without moving keyboard focus away from the terminal.
- Expand the active-app hover with app identity, uptime, resource totals and
  its busiest helper processes. The calendar popup combines an analog face
  and numeric time in the same view.
- Preserve a flashlight pick while returning focus refreshes the app's mappings,
  so emoji insertion reaches the original input field.
- Parse Inspector HTML comments without joining surrounding text into new tags.
- Report timed-out AppleScript execution consistently when cancellation races
  with result delivery.

### Development and getting started

- Refresh the Rust and browser-tooling dependencies, including SQLite through
  rusqlite 0.42, the pinned Ghostty terminal library and the Electron 45
  integration fixture. TypeScript stays on
  6.0.3 until the Svelte checker supports the native compiler without a second
  compiler installation.
- Lock the mise development tools across macOS and Linux, and use the same
  pinned environment and frozen dependency resolution locally and in CI.
- Separate released installation instructions from the development manual,
  with a short first-hint walkthrough and explicit Accessibility limitations.

### Upgrading from 1.1

Run `flash config check` after updating: every renamed command or key below
that your configuration still uses is reported with its file position. Then
run `flash resident doctor`: it names each plugin value your bar, widgets or
monitors read that no plugin publishes any more, with its replacement.

- **A status link opens only `http`, `https` and `mailto` URLs.** A
  `#[link=…]` on the bar, hinted or clicked, or a hyperlink in a popup, is
  text a plugin, a source or a program wrote, so any other scheme is now
  refused: `file:`, `slack:`, `x-apple.systempreferences:` and the rest do
  nothing until you list them in `[statusbar] link_schemes = ["slack"]`
  (exact lowercase names). A refusal is logged by its scheme alone and
  `flash resident doctor` lists the schemes refused since launch.
  `[statusbar.click]` URLs are your own configuration and still open any
  scheme ([status bar](docs/statusbar.md#turn-a-label-into-an-action)).

- **`h` `j` `k` `l` are the arrow keys on a page too.** A web page or a PDF
  scrolls on them as before, a field the page focused gets them, and a
  terminal still scrolls; `ctrl+d` / `ctrl+u` and `gg` / `G` are unchanged.
- **Editors keep their own text editing.** NORMAL never engages a field in
  VS Code and its forks (VSCodium, Cursor, Windsurf), the JetBrains IDEs,
  Zed or Sublime Text: the keys keep their page meaning there, `v` and `V`
  do nothing and the text table never applies. The list is the `defaults`
  plugin's manifest `own_text_editing`, which any plugin extends;
  `[mode.apps."<bundle id>".text] enabled = true` forces an app on and
  `enabled = false` keeps one out. `[mode.text] enabled = false` turns the
  engagement off everywhere, for kindaVim and SketchyVim users
  ([engage a field](docs/normal-mode.md#engage-a-field)).
- **Commands are two words, `<topic> <action>`.** `"flash", "mouse_target"`
  is now `"flash", "mouse", "target"`, `enter_insert_mode` is `mode insert`,
  `leave_mode` is `mode leave`, `window_move` is `window move`, `send_keys` is
  `key send`. `flash config check` and the CLI name the replacement for each
  old command; [commands](docs/commands.md) lists them all.
- **The flashlight has its own command.** Replace
  `["flash", "enter_command_mode", "--input=:flashlight "]` with
  `["flash", "mode", "flashlight"]`; a starting query is
  `--query=@emojis` (no trailing space needed). `app switch` lists
  running apps only.
- **Flashlight filters are one-word resource types.** `@emojis.glyphs` is
  `@emojis`, `@notes.notes` `@notes`, `@reminders.tasks` `@reminders`,
  `@contacts.cards` `@contacts`, `@files.results` `@files`,
  `@processes.processes` `@processes`, `@system.actions` `@system`, the
  clipboard's three sources `@clipboard`, and `@firefox.tabs`,
  `@firefox.history`, `@chrome.bookmarks` read every browser's as `@tabs`,
  `@history`, `@bookmarks` (`!fh`, `!cb` and the other bangs still read one
  browser). tmux windows are `@terminals`. `[flashlight.precedence]` keys are
  types (`terminals = 200`, `tabs = 120`), and a dotted `@source` in an alias,
  a precedence key or a `--query` fails `flash config check`, naming the type
  it meant. A plugin's `sources[]` entries need a `type`
  ([plugin protocol](docs/plugin-protocol.md#resource-types)).
- **Plugin settings are `[plugins.<id>]`**, beside `[plugins]`, instead of
  `[plugin.<id>]`. `[plugins] exec_paths` is gone.
- **The system plugins are one, `sysinfo`.** cpu, memory, disks, network and
  power merged: `#{flash.plugin.cpu.label}` is
  `#{flash.plugin.sysinfo.cpu_label}`, `#{flash.plugin.power.percent}` is
  `#{flash.plugin.sysinfo.power_percent}` (domain, underscore, segment), and
  `[plugin.network] summary_mode` is `[plugins.sysinfo] summary_mode`.
- **Other plugins merged or moved into Flash itself.** tmux is part of
  `terminals` (`#{flash.plugin.terminals.session}`, `[plugins.terminals]
  ssh_hosts`); history is part of `browsers`; reference is `emojis`; search
  bangs are `searchproviders` (source `searchproviders.bangs`). apple,
  caffeinate, files, marks, media, processes and system are built in: drop
  them from `[plugins] disabled`. The busiest-process tables are
  `#{flash.top_cpu}` and `#{flash.top_mem}`, sized by `[statusbar] top_count`.
- **Removed plugins:** github, kitty, spotify, windows and vscode, and the
  HTTP status code catalog.
- **Leftover plugin data.** Flash no longer reads the folders of the plugins
  above under `~/Library/Application Support/Flash/Plugins/`; delete them.
  `history/` held a copy of your Firefox and Chrome history.
- **Focused-app values:** `#{flash.active_app_name}` is
  `#{flash.focused_app_name}` and `#{flash.active_bundle_identifier}` is
  `#{flash.focused_app_bundle_id}`.
- **Updates.** Flash now checks GitHub's releases API once a day for a newer
  release; `[app] updates = "off"` stops it ([updates](docs/updates.md)).
- **`{N}gt` selects tab N**, as in Vim; `{N}]t` still moves N tabs on.
- **Marks are on `m{x}`, `'{x}` and `` `{x} ``** in NORMAL, read by the
  interpreter; a mapping of your own on those keys still wins.
- **`[overlay] screen_capture = "hide"` is `[app] hide_from_capture = true`.**
  It now covers every Flash window, About included
  ([screen capture](docs/privacy.md#screen-capture)).
- **`gm` is monitor select** in NORMAL; a mapping of your own on `gm` still
  wins, and `"gm" = false` removes it.
- **Function keys are `<f1>` to `<f20>`.** A mapping key `"f12"` was the
  keys f, 1 and 2, and is now rejected: write `"<f12>"`, or `"f 1 2"` for
  that sequence. `cmd+f12` is now Command-F12, no longer Command-F then 1
  and 2 ([function keys](docs/mappings.md#function-keys)).
- **Snippets live in their file.** `[plugins.snippets]` takes `file` alone,
  a file of `name = text` entries at its top level: move the entries of a
  `[snippets]` table in that file up a level. A
  `[plugins.snippets.snippets]` table never loaded and is still rejected.
- **The CLI speaks a socket, not an Apple Event.** `flash <command>` reaches
  the resident over `~/Library/Application Support/Flash/run/flash.sock`;
  the `Flsh`/`Cmd ` Apple Event is gone, so an `osascript` or AppleScript
  that sent it must run `flash` instead. A launcher no longer needs
  Automation permission to run `flash`. A new `flash` cannot talk to an
  older resident: quit and reopen Flash after updating.
- **A click no longer enters INSERT.** Only `mode insert` does (`i` or a
  key you bind to it). A click with
  the mouse, `f` or `F` keeps the mode wherever it lands, on a text field, a
  password field or a terminal too: click, then press `i` to type there. A
  click chain (`alt+f`) goes on after a click on an input until Escape
  ([enter INSERT](docs/insert-mode.md#enter-insert)). A plugin hint target no
  longer takes `enters_insert_mode`: a `hints` reply that sends it is
  rejected, and the Rust SDK's `JumpTarget::enters_insert_mode` is gone.
- **Flash does not edit text.** It moves, selects, copies and pastes, and
  nothing else: no key or command deletes, changes or cuts text, not even
  through the app's own Cut, and nothing goes into a field but what you
  paste or pick
  ([what Flash does not do with text](docs/vim.md#what-flash-does-not-do-with-text)).
  Only `i` enters INSERT, and `mode insert` takes no argument. HOLD's `d`,
  `x` and `c` no longer cut or change: they read NORMAL's keys there, so
  `d` and `c` start a double-click and a right-click and `x` closes the
  tab; `y` still copies and `p` pastes over the selection. 1.1's
  `clipboard_cut` and `selection --action=cut` / `--action=change` are gone
  with no replacement, and so are the nightlies' `mode insert --at`,
  `--open` and `--change` (Vim's `I` `a` `A` `o` `O` `s` `S` `C` and
  VISUAL's `c` `s`), `selection cut`, `clipboard cut`, `input newline`,
  `input delete_backward` and `input delete_forward`: a mapping on one of
  them fails to load and `flash config check` reports it. Map the key to
  `["flash", "mode", "insert"]` to keep it entering INSERT, or remove it.
  Edit inside a field with the app's own keys in INSERT, or with
  [kindaVim](docs/alternatives/kindavim.md) or
  [SketchyVim](docs/alternatives/sketchyvim.md) there. `s`, `ms`, `ds` and
  `cs` stay the letter jump, as in 1.1; the nightlies' `gw`, `mgw`, `dgw`
  and `cgw` are gone.
- **`h` `j` `k` `l`, `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b` and `gg` /
  `G` are `move`.** In a field you engaged they move the caret and in a
  list, table, outline or column browser the selection, with the app's
  arrows; in a page, a document, a field you have not engaged or a terminal
  they scroll as before
  ([arrows or scrolling](docs/normal-mode.md#arrows-or-scrolling)).
  `ctrl+e` / `ctrl+y` always scroll. To scroll everywhere as 1.1 did, map
  the keys back to `scroll`:

  ```toml
  [mode.normal.mappings]
  "h" = ["flash", "scroll", "left"]
  "j" = ["flash", "scroll", "down"]
  "k" = ["flash", "scroll", "up"]
  "l" = ["flash", "scroll", "right"]
  "ctrl+d" = ["flash", "scroll", "half_page_down"]
  "ctrl+u" = ["flash", "scroll", "half_page_up"]
  "ctrl+f" = ["flash", "scroll", "page_down"]
  "ctrl+b" = ["flash", "scroll", "page_up"]
  "gg" = ["flash", "scroll", "top"]
  "G" = ["flash", "scroll", "bottom"]
  ```

- **In a field you engaged, `H`, `L`, `t`, `gg`, `G` and `p` are Vim's.**
  A field is engaged once you act in it: leave INSERT there, click it, `gi`
  or `v`. A field the page focused on its own (a search box on load, the
  address bar) is not, and Escape or the focus moving on ends it
  ([engage a field](docs/normal-mode.md#engage-a-field)). While a field is
  engaged NORMAL reads `[mode.text.mappings]` first: `H` / `L` go to the
  first / last visible line instead of back / forward, `t` is till instead
  of a new tab, `gg` / `G` go to the first / last line's first non-blank,
  `p` pastes after the cursor (`P` at it), `x`, `r` and `R` do nothing, and
  Escape (`mode leave`) gives NORMAL's own keys back. Everywhere else they
  keep their meaning ([keys in text](docs/normal-mode.md#keys-in-text)). To
  keep Flash's in a field too:

  ```toml
  [mode.text.mappings]
  "H" = ["flash", "history", "back"]
  "L" = ["flash", "history", "forward"]
  "t" = ["flash", "tab", "new"]
  "gg" = ["flash", "move", "top"]
  "G" = ["flash", "move", "bottom"]
  "p" = ["flash", "register", "paste"]
  "x" = ["flash", "tab", "close"]
  "r" = ["flash", "app", "reload"]
  "R" = ["flash", "app", "reload", "--force"]
  ```

- **`v` and `V` start VISUAL in the focused field.** They were free keys
  and are now NORMAL's, in `[mode.normal.mappings]`: in a focused text
  field they engage it and select characters and whole lines
  ([VISUAL](docs/visual-mode.md)); with nothing editable focused they do
  nothing. VISUAL's keys are a new table, `[mode.visual.mappings]`,
  `[mode] labels` takes `visual` and `visual_line`, and `visual` is a
  mapping scope, so a layer can no longer be named `visual`. To keep `v`
  and `V` free:

  ```toml
  [mode.normal.mappings]
  "v" = false
  "V" = false
  ```

- **Escape in NORMAL is the app's own cancel** (`app cancel`): it closes a
  popover, a dialog or a search, where it was swallowed. Hints, a
  half-typed key and an engaged field's Escape still come first, a context
  menu or Mission Control gets the key itself, and a terminal gets nothing.
  `"<esc>" = false` in `[mode.normal.mappings]` swallows it again
  ([app operations](docs/normal-mode.md#app-operations)).
- **`:p` and `:pr` print**, as vim's `:p[rint]`; `process` is now `:proc`
  or longer (`flash proc kill --pid=…`). `:e!` reverts the document, after
  asking, where it was rejected.
- **`ctrl+e` / `ctrl+y` scroll one line**, as Vim's, a count multiplying
  it (`5 ctrl+e`): they are `scroll line_down` / `scroll line_up` now,
  where they were `scroll down` / `up` and scrolled `[mode]
  scroll_step_lines`. `j` / `k` keep that step (3 lines) where they
  scroll. A mapping of yours on `scroll down` keeps the step; map
  `scroll line_down` for one line.
- **A topic alone runs its only action only when it just shows
  something**: `:display` turned the displays off and `:screen` locked the
  screen. `:logs`, `:mappings`, `:about` and `flash logs` still open their
  page; `:screen`, `:screensaver`, `:trash`, `:appearance` and the other
  topics whose action changes something wait for the action.
  `:di[splay]` is Vim's, the registers.
- **A key that continues no sequence runs nothing**, as in Vim: `gx`, `]x`
  and `ctrl+w x` no longer close the tab, `z.` no longer repeats and `gu`
  no longer undoes. A key that names no register, mark or macro after `"`,
  `'`, `` ` ``, `q` or `@` is dropped the same way (`".` used to repeat).
- **A named yank leaves the clipboard alone** (`"ay`), as the manual and
  Vim's `clipboard=unnamedplus` say; a bare `y` still writes it and `"0`.
- **HOLD's `x` does nothing**: it closed the tab under the drag.
  `"x" = ["flash", "tab", "close"]` in `[mode.hold.mappings]` takes it back.
- **`P` pastes outside text** too, where it was unbound, as `p` does there.
- **`[macos]` is gone: write `[startup] run`** (only development builds had
  `[macos]`). Flash no longer writes macOS preferences; it runs the commands
  you list once each time it starts, and `flash config check` rejects a
  `[macos]` table with its position. Before updating, run
  `flash macos revert` if you want Flash's changes undone: removing a line
  no longer restores anything. Then convert each setting to a `defaults
  write` command, followed by the restart its domain needs
  ([startup commands](docs/startup.md)):
  - `[macos.dock] autohide = true` is
    `["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"]`,
    then `["killall", "Dock"]`. Booleans are `-bool`, a choice is the value
    the preference stores (`orientation = "left"` is `-string left`).
  - A `_ms` duration is seconds as `-float` (`autohide_delay_ms = 0` is
    `autohide-delay -float 0`, `resize_duration_ms = 1` is
    `NSWindowResizeTime -float 0.001`), except key repeat, in 1/60 s ticks as
    `-int`: `repeat_interval_ms = 33` is `KeyRepeat -int 2`,
    `repeat_delay_ms = 250` `InitialKeyRepeat -int 15`.
  - A setting named for the opposite of its key writes the opposite:
    `ds_store_on_usb_volumes = false` is `com.apple.desktopservices
    DSDontWriteUSBStores -bool true`, `displays_have_separate_spaces = false`
    `com.apple.spaces spans-displays -bool true`.
  - `[macos.defaults."<domain>"] key = 0.1` is `defaults write <domain> key
    -float 0.1` (an integer `-int`, a string `-string`), and
    `[macos.defaults_current_host.…]` is `defaults -currentHost write …`.
  - Restart the Dock after `com.apple.dock`, Finder after `com.apple.finder`,
    `com.apple.desktopservices` and `AppleShowAllExtensions`, SystemUIServer
    after `com.apple.screencapture`, ControlCenter after the clock and the
    battery percentage; key repeat and Spaces apply at the next login, and
    `restart = "never"` is leaving the `killall` lines out.
  - `[macos.lock_screen] require_password` has no startup equivalent: it
    needs your password, so set it once in System Settings › Lock Screen, or
    with `sysadminctl -screenLock immediate -password -` in a terminal.
  - `~/Library/Application Support/Flash/macos-settings.plist`, the values
    your preferences had before Flash changed them, is no longer read or
    written: `plutil -p` shows them, and you can delete it.

### New

- `flash resident doctor` warns (`telemetry_receiver`) when
  `[telemetry.receiver]` is on without a `token` while a monitor whose
  `value` reads a `#{flash.otel…}` metric has a `run`, naming those
  monitors: any local program could post a metric and fire them
  ([telemetry](docs/telemetry.md#the-receiver)). The receiver stays opt-in
  and the token optional.
- Tiling supports dragging one tile onto another to swap, preserving manual split resizes, and restoring workspace layouts across restarts. `[tiling] persist = false` disables saving and removes the saved layout.
- `menu choose --prompt=…` labels a script picker without changing its query or answer.
- The which-key palette lists HYPER and named-layer mappings after entry and sequence prefixes.
- Vim parity in NORMAL, all navigation, selection and clipboard: `''` and
  ``` `` ``` go back to before the last jump, `gv` selects the last VISUAL
  range again (`mode visual --reselect`), `:42` and `:$` go to a line of the
  field you engaged, `@:` runs the last command line again (`macro play
  --register=:`), `qA` appends to macro `a`, `1.` repeats with a count of 1
  (`macro repeat --count=N`), and plain `ctrl+[` is Escape in NORMAL and
  VISUAL. The command line edits as Vim's: `ctrl+w` deletes a word,
  `ctrl+u` back to the `:`, `ctrl+r {x}` inserts register `x` (`:` the last
  line), and Up recalls only the lines that start with what you typed.
- The everyday operations of an app's menus are commands, bound per app by
  the bundled plugins ([app operations](docs/normal-mode.md#app-operations)):
  `document save_as` (`:sav`), `document export_pdf`, `document revert`
  (`:e!`), `document duplicate`, `document rename`, `document page_setup`,
  `app settings` (`:opt`), `app select_all`, `app help`, `app cancel`,
  `window close_all`, `window zoom`, and in browsers `url bookmark`,
  `url edit`, `history show`, `window new --private`, `app stop`,
  `app downloads`, `app developer_tools`, `tab duplicate`, `tab pin`,
  `tab mute` and `tab detach`. `:p[rint]` and `:ha[rdcopy]` print. Reverting
  and closing every window ask first. `app hide` (`:hid`), `app hide_others`,
  `app show_all` and `app raise` are Flash's own, and `menu press
  --path=<Menu,Item,…>` presses any menu-bar item of the focused app by its
  titles.
- NORMAL's `h` `j` `k` `l`, `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b` and
  `gg` / `G` are one `move` command each, resolved by where the focus sits:
  the caret in a field you engaged (`h` and `l` never leave the line), the
  selection in a list, table, outline or column browser, and a scroll in a
  page, a field you have not engaged or a terminal, which never gets an
  arrow. Flash classifies the focused element once per focus change, off
  the keyboard path, so a key costs a lookup
  ([arrows or scrolling](docs/normal-mode.md#arrows-or-scrolling)).
  New `input` cursor moves (`line_start`, `line_end`, `char_left`,
  `char_right`, `line_up`, `line_down`, `document_start`, `document_end`)
  and `move` binding keys let a plugin say what an app does for each.
- Vim's motions in a field you engaged: `w` `b` `e` `ge` and their WORD
  forms, `0` `^` `$` `g_` `|`, `gg` / `G` and `{N}G`, `%` and `{N}%`, `{` `}`,
  `(` `)`, `+` `-` `_` and Return, `H` `M` `L`, `t` `T` `;` `,`, `zt` `zz`
  `zb`, `gj` `gk`, and `p` / `P` putting after or at the cursor, with
  counts. They are the new `cursor` commands in a new table,
  `[mode.text.mappings]`, which NORMAL reads before its own while a field
  is engaged and never otherwise or in a terminal. Flash computes
  Vim's landing from the text Accessibility gives and sets the caret,
  checked against Vim 9.1; where an app gives no text, the macOS chord for
  `b`, `e`, `0`, `$`, `gg` and `G` runs, and plugins may bind the `cursor`
  motions per app. `f` / `F` stay the hints; Vim's find is
  `cursor next_char` / `previous_char`
  ([Vim motions in text](docs/normal-mode.md#vim-motions-in-text)).
- NORMAL acts on a field only once you engage it: leaving INSERT there,
  `gi`, a primary click or an `f` on it, or `v` / `V`. A page that keeps a
  field focused (Google Docs' hidden editor, google.com's search box, the
  address bar) keeps NORMAL's own keys: `x` closes the tab and `j` scrolls.
  Escape, the focus moving on and any mode change
  but INSERT and VISUAL end the engagement, and NORMAL's table changes only
  with it, so focus changes never drop a half-typed `]t`. `flash resident
  status` reports `mapping_scope` `text` while a field is engaged
  ([engage a field](docs/normal-mode.md#engage-a-field)).
- VISUAL in the focused field: `v` selects characters and `V` whole lines
  from the cursor, engaging the field, every motion grows or shrinks the
  selection with counts, and `o` moves its other end. `y` copies, and `p`
  and `P` paste over the selection, as do ⌘C and ⌘V, with the app's own
  keys; `"ay` and `"ap` use a register. Flash sets the selection through
  Accessibility from the text it reads, with the motions' Vim-checked
  engine, and never writes text there; where an app gives no text, as in a
  password field, or does not take the selection Flash sets, the new
  `input select_*` commands extend the app's own selection with Shift and
  its arrows. The pill reads `VISUAL` or `V-LINE`, in red, and
  `core:mode.changed` reports `visual`
  ([VISUAL](docs/visual-mode.md)).
- `[mode] move_page_lines` (15 by default) sets how many arrows `ctrl+d` /
  `ctrl+u` send in an engaged field and lists; `ctrl+f` / `ctrl+b` send
  twice as many.
- ⌘C and ⌘V in NORMAL copy and paste what the app has selected,
  through each app's `clipboard` binding, so a selection made with the
  mouse copies without leaving NORMAL.
- A scroll lands in the focused window: at the pointer while the pointer is
  inside it, else in the middle of the focused element's scroll area or of
  the window, rather than in whatever the pointer rests on
  ([where a scroll lands](docs/normal-mode.md#where-a-scroll-lands)).
- Flash runs on macOS 13 Ventura and later, down from macOS 14, with the
  same features ([getting started](docs/getting-started.md)).
- NORMAL mode gains Vim's counts, `.` repeat, macros (`q`, `@`), `:normal`,
  `:!` and ex commands, and `flash <command>` in a terminal runs exactly what
  `:<command>` runs ([Coming from Vim](docs/vim.md)).
- `window switch` (`:ls`) lists every window, most recently used first;
  named window positions survive displays being plugged and unplugged
  ([windows](docs/windows.md)).
- `[startup] run` lists commands Flash runs once each time it starts, in
  order, each bounded by `timeout`, the next one even after a failure:
  `defaults write` lines, `killall Dock`, Flash commands. `flash startup
  run` runs them again and prints how each ended
  ([startup commands](docs/startup.md)).
- Show, hide and toggle Mission Control, App Exposé, Show Desktop,
  Launchpad, Notification Center and Control Center.
- `[monitors]` run commands and react to host events; `flash status set`
  pushes status values from scripts.
- A versioned IPC socket with JSON Schemas for every message: `flash
  events watch` streams host events as NDJSON (mode changes, focus, config
  reloads, hint sessions, monitor triggers, workspaces), `flash --json`
  prints any reply as JSON, and `flash` starts Flash when it is not running
  ([IPC protocol](docs/ipc-protocol.md)).
- User-defined layers (`mode layer --name=`), clipboard history in the
  flashlight (`!clip`), the next calendar event and `calendar join`.
- In-place updates with a "Check for Updates…" button in About.
- `[monitors] run` takes a list of commands, run in order and stopped at the
  first failure, one run at a time, with a `timeout` and a `cooldown` that
  survives restarts ([monitors](docs/monitors.md#running-commands)).
- `[monitors.<name>] usb = { vendor_id = 0x05ac, product_id = 0x024f, name =
  "Keyboard" }` narrows `core:usb.attached` and `core:usb.detached` to one
  device, any subset of the three ([USB devices](docs/monitors.md#usb-devices)).
- `[macos.lock_screen] require_password` declares the lock screen's password
  delay; changing it asks for your password at `sysadminctl`'s own prompt.
- `[flashlight.bangs]` adds your own bangs and quicklinks beside the
  plugins' bangs: `jira = "https://example.atlassian.net/browse/{query}"`
  makes `!jira ABC-1` open that issue, with the query percent-encoded; a
  URL without `{query}` opens as written
  ([your own bangs](docs/flashlight.md#your-own-bangs-and-quicklinks)).
- `@windows` in the flashlight searches every window by title and app;
  `@<type>` narrows to one resource type, whoever feeds it, and `@` completes
  the types with how many sources feed each.
- Status sources read SwiftBar/xbar, i3blocks and waybar output
  (`output =`), and `status refresh --name=` reruns one now.
- Vim and Vimium keys: `ctrl+w p` (`window last`), `zi` / `zo` / `z0`
  (`app zoom_in` / `zoom_out` / `zoom_reset`), `gs` (`app view_source`), and
  `mouse target --copy-url`, which copies a link's URL.
- The documentation has a Modes section with a page per mode, links to the
  exact line of `config.default.toml`, and pages for moving from Linux tools,
  menu-bar managers, clipboard managers, app switchers, key remappers and
  more ([alternatives](docs/alternatives/README.md)).

- Monitor select: `gm` (`mouse screens`) numbers each display, and the
  pointer and keyboard focus go to the one you type; `2gm`,
  `--index=<n>` and `--direction=next|previous` pick without labels, and
  `--to=last` lands where the pointer left that display
  ([pick a display](docs/mouse-grid.md#pick-a-display)).
- `notify send` posts a native macOS notification that stays in Notification
  Center, apart from `alert show`'s centred alert; a click opens a URL or runs
  a Flash command, and monitors post one with `notify = true`.
- `log write` (`:log --warn --message=…`) writes a line to Flash's log at a
  level, and `metrics record` records a gauge, counter or histogram that the
  bar, monitors and the OpenTelemetry exporter read with Flash's own metrics,
  which status formats can now read too.
- `flash.toml` has a JSON Schema: editors with a TOML language server
  (Taplo, Tombi) complete, document and check keys as you type. The starter
  points at it with `#:schema`; `flash config schema` prints the one for
  your version ([configuration](docs/configuration.md#editor-support)).
- Mappings bind the function keys F1–F20 (`"<f5>"`, `"cmd+<f12>"`), the
  mappings page draws F1–F12 above the number row, and `key function`
  presses F13–F20 too.
- Shell completions for zsh, bash and fish and a `flash(1)` man page,
  generated from the command table: the Homebrew cask installs them, and
  `flash cli completion --shell=<shell>` and `flash cli manpage` print them
  ([commands](docs/commands.md#status-doctor-config-events-and-shell-queries)).

### Fixes

- A count before a chord counts (`3 ctrl+d`, `5 ctrl+e`), and `.` and a
  macro repeat the chord. A count before `"` is kept (`3"ap` pastes three
  times), and one before `'` or `q` no longer leaves the keys after it to
  run on their own (`3'a` jumps to mark `a`).
- A `:` line typed while recording a macro is recorded as submitted; the
  replay used to open an empty command line. `q` stops a recording in
  VISUAL too.
- `.` no longer repeats `v` or `V`.
- The which-key palette waits for your key: a mapping that is also a
  prefix no longer runs at `sequence_timeout_ms` while it lists what can
  follow. A count, a register, a mark or macro name and a character search
  wait for their key as long as it takes, as in Vim.
- A `<leader>` sequence or the command line no longer disengages the field
  you engaged, and `mode normal` (⌘⌃[) out of VISUAL deselects as Escape
  does instead of leaving the selection.
- VISUAL's `y` fills `"0` too, as every bare yank does.
- `N` in Finder no longer opens Go to Folder: Finder's Cmd-Shift-G is not
  Find Previous, so `n` and `N` do nothing there.
- The help server refuses changes a browser marks as coming from another
  site and forbids other sites from embedding its responses.
- Command history, ranking data, marks, the macOS settings ledger and the
  browsers plugin's copies of your history are readable by your account
  only (`0600`); the copies of Firefox history kept Firefox's `0644`.
- An unknown command names the one it most likely meant, in `flash config
  check`, the CLI and the log.
- `flash config check` accepts the next-meeting values
  (`#{flash.calendar.next}` and its parts) in the bar, popups, widgets and
  monitors instead of calling them unknown, and lists them when one is
  misspelled.
- Closing the About window with `x`, `:q` or ⌘W never closes the app behind
  it: while it is the key window, it gets every key.
- A burst of `notificationcenter toggle` or `controlcenter toggle` ends as
  its count says instead of losing presses.
- Finder's desktop is never mistaken for a maximized window, and window
  layouts return to their display when it is plugged back in.
- Accessibility calls share one 1.5 s timeout instead of whichever a probe
  set last, so hint walks no longer come back incomplete after a grid click.
- Flash idles at about 1% CPU: the dev build is optimized and the secure
  input check no longer scans every app every two seconds.
- The browser help opens long manual pages in half the time (the commands
  page in 24 ms rather than 49) and ranks a mappings search keystroke in half
  the time, and a help tab left open no longer costs Flash or the browser
  while the status bar updates: Flash rebuilds and sends only the sections
  that changed, and the page redraws only what shows them
  ([performance](docs/performance.md#browser-help)).
