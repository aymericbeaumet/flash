# flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/aymericbeaumet/flash)](https://github.com/aymericbeaumet/flash/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Your keyboard, all of macOS.**

What Vimium does in the browser, Flash does in every app: press a hotkey, type
the label on the thing you want, and it is clicked. Then keep going: a Vim-like
normal mode over all of macOS, a mouse grid, a tmux-style status bar, desktop
widgets and terminal popups, all from one TOML file. Flash never reads your
screen.

Coming from i3, sway or Hyprland with keynav, conky, polybar and rofi? This is
that toolkit for macOS. Never edited a dotfile? Start with one hotkey.

<!-- Demo: docs/assets/demo.gif, 10–15 s. Hotkey → labels → typed hint → click in
     Safari and in a native app, then `f` from normal mode and a `]t` tab switch.
     Show the keys pressed (KeyCastr) and keep the GIF under 5 MB. -->

Flash is free and open source (MIT), written in Swift with plugins in Rust. It
needs macOS 14 or later and the Accessibility permission.

## What you get

- **Hints.** Label every visible button, link, tab, and field, then click,
  right-click, double-click, drag, or move the pointer to it. Menu bars, the
  Dock, and Notification Center too.
- **Keyboard grid.** The screen is split like the left half of your keyboard
  (`12345` / `qwert` / `asdfg` / `zxcvb` on QWERTY, your layout's keys
  otherwise). Press the key where you want to go, again to refine. Bisect mode
  halves the screen with the keys at the QWERTY h, j, k and l positions of
  your layout.
- **Terminal hints.** The bundled tmux plugin labels panes, every detected URL
  and file path, and [supported status-bar tabs](docs/architecture.md#hint-activation)
  inside your terminal.
- **Normal mode.** A persistent, Vim-like layer over all of macOS: `f` for
  hints, `[t` / `]t` for tabs, `gg` / `G`, `ctrl+d` / `ctrl+u` to scroll, `u` to
  undo. Keys map to actions that fit the focused app: `]t` is the next browser
  tab, Finder tab or tmux window.
- **Windows.** Focus the nearest window in a direction, place windows with
  shortcuts or opt-in app/title rules, and control native full screen.
- **flashlight.** A command bar that searches apps, browser tabs, tmux windows,
  native windows, emoji, and plugin data, with inline math, unit, and currency answers.
- **Status bar and desktop widgets.** tmux-format templates with meters,
  sparklines, conditionals and shell jobs, fed by system plugins (CPU, memory,
  disks, network, battery, top processes) or any command you write.
- **Plugins.** Any program that speaks JSON lines over stdin and stdout; a Rust
  SDK is included. Bundled media controls can select input and output devices.

Everything reloads live when you save. There is no preferences window; the
menu-bar icon offers About, Open Configuration, and Quit.

## What Flash will not do

These are design rules, enforced by tests and a guardrail script, not plans.

- **Never read the screen.** No OCR, no Vision, no pixel access. Hints come
  from the Accessibility tree and window geometry; apps that expose nothing
  get the keyboard grid instead. `:screenshot` runs Apple's `screencapture`
  straight to the clipboard, and no image passes through Flash.
- **Never record keys.** One keyboard tap, in one file, decides whether a key
  is swallowed or passed through. It never logs, stores or sends keystrokes.
- **No private APIs, no SIP changes, no helper daemons.** One process, public
  frameworks, autostart through the standard login item.
- **No preferences window, no accounts, no telemetry, no update checks.** The
  configuration file is the whole interface; `flash config_check` validates
  it in CI.
- **Assemble, don't replace.** When a maintained tool already does the job
  (btop, newsboat, calcurse), Flash shows it in a popup instead of growing a
  copy of it.

## Install

### 1. Homebrew

```sh
brew install --cask aymericbeaumet/tap/flash@nightly
```

This installs `Flash.app` and the `flash` command, and starts Flash. Nightly
builds are ad-hoc signed, so macOS can drop the Accessibility grant after an
update while the toggle still shows as on. If hints stop working after
`brew upgrade`, remove Flash from the list with **−** and add it again.

### 2. mise

From a clone, mise installs the toolchain this repository pins. The installer
then builds and starts Flash:

```sh
git clone https://github.com/aymericbeaumet/flash.git
cd flash
mise install
mise exec -- ./Scripts/install.sh
```

See [development](docs/development.md) for tests and the dev build.

Flash is not on crates.io: `cargo install flash` installs an unrelated
program.

Whichever way you installed it:

1. **Allow the first launch.** Builds are ad-hoc signed and not notarized yet.
   If macOS says it could not verify Flash, open **System Settings → Privacy &
   Security** and click **Open Anyway**.
2. **Grant Accessibility.** Flash opens **System Settings → Privacy & Security →
   Accessibility** for you. Turn Flash on.

Open `:help` (or `flash help_show` from a terminal) for the browser help
homepage. It is a checklist of what this Mac has already set up and what is
still missing, plus the feature guides, commands, plugins, and live runtime
pages. In NORMAL mode, `?` jumps straight to your mappings; `:help
flashlight` opens a specific guide. See [browser help](docs/help.md).

## Start easy, go deep

### 1. One hotkey

On first launch Flash creates `~/.config/flash/flash.toml` with one mapping:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
```

Press **⌘⇧Space**, then type the letters on the control you want. Press Escape
to cancel. Open the file from the menu-bar icon (**Open Configuration**);
changes apply as soon as you save.

### 2. Grid and search

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]                               # hints
"cmd+shift+alt+space" = ["flash", "mouse_grid"]                             # keyboard grid
"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "] # search
```

In the grid, `1` is the top-left cell and `b` the bottom-right one. Each key
zooms into its cell with the same keys, and the last step clicks. Backspace
steps back, Tab moves to the next display; see [the grid keys](docs/normal-mode.md#mouse-grid).

Keep the trailing space in `--input=:flashlight `: it opens search directly.
Try `@emojis.glyphs fire` or `1234 euros in dollars`.

Pick hotkeys that are free on your Mac. macOS uses Control-Space and
Control-Option-Space to switch input sources, and many editors use
Control-Space for completion.

### 3. Normal mode

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
```

While NORMAL is active, keys that are not mapped are captured instead of typed.
Press ⌘⌃I, click into a text field, pick an input with `f`, or open Find
(`/`) or a new tab (`t`) to type again.
NORMAL stays active across app and tab switches. See
[normal mode](docs/normal-mode.md) for every binding.

### 4. Status bar and widgets

```toml
[statusbar]
enabled = true

[widgets.system]
anchor = "top_right"
template = """
CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer] #[spark]#{flash.plugin.cpu.history}#[nospark]
MEM #[meter=20]#{flash.plugin.memory.percent}#[nometer]
#{flash.plugin.processes.top_cpu}
"""
```

The bar takes the top of the screen, so macOS auto-hides its own menu bar while
it is enabled. Widgets sit on the desktop, below your windows. Start from the
[status bar example](docs/examples/statusbar/README.md) or the
[widget examples](docs/examples/widgets/README.md), and see
[widgets](docs/widgets.md) for a conky migration table.

### 5. Remap or remove anything

Every default binding can be changed or removed, including the ones plugins add:

```toml
[mode.normal.mappings]
"t" = false                                          # remove a default
"gs" = ["flash", "mouse_target", "--scope=screen"]   # add your own
```

`flash config_check` validates the file without the app running, so it fits in
a dotfiles CI job.

### 6. Plugins

Write a plugin in any language, or pin someone else's to a commit. Start with
the [plugin cookbook](docs/plugin-cookbook.md).

## Coming from Linux?

| You used | In Flash |
| --- | --- |
| keynav, warpd grid | `mouse_grid`, keyboard-shaped, with `--bisect` |
| Vimium, qutebrowser hints | `mouse_target`, in every app |
| warpd normal mode | `mouse_pointer` |
| conky | [desktop widgets](docs/widgets.md) |
| polybar, waybar | `[statusbar]` with tmux formats |
| rofi, dmenu | flashlight |
| i3, sway, Hyprland modes | NORMAL / INSERT / COMMAND / TERMINAL with `[mode.*.mappings]` |
| i3 `move`, Hyprland dispatchers | `window_move` |
| swaymsg, hyprctl | `flash <verb>`, `flash status --json` |
| dotfiles | one `flash.toml`, live reload, `flash config_check` |

## Privacy

Flash itself asks for Accessibility and nothing else. It does not use Screen
Recording, OCR, or Input Monitoring, and it has no telemetry, analytics, or
update checks. Bundled plugins are enabled by default and a few ask for
something more the first time you use them; every prompt, request and file is
listed on the [privacy page](docs/privacy.md).

- **Screen.** Hints come from the Accessibility tree and window geometry. Flash
  never reads screen pixels. The optional `:screenshot` command runs macOS
  `screencapture` and asks for Screen Recording only when you use it.
- **Keyboard.** A keyboard tap is active only while Flash owns input (hints,
  normal mode, the command bar). It decides whether to swallow or pass each key
  and never records what you type in other apps. Queries you submit in Flash's
  own command bar are kept in a local history.
- **Other prompts.** Listing browser tabs asks for Automation of that browser.
  Indexing Notes, Reminders or Contacts asks for Automation of those apps. A
  command you configure yourself, such as a calendar CLI in a widget, triggers
  its own prompt, attributed to Flash.
- **Network.** Flash's core has no network features. By default, `answers`
  fetches daily exchange rates from the ECB and `github` runs your `gh` CLI if
  it is signed in. Feeds and remote tmux over SSH are off until you configure
  them. Disable any plugin with `[plugins] disabled = ["<id>"]`.
- **Local data.** Clipboard history, command history, ranking data and a copy
  of your Chrome and Firefox history (for the `history` search source) stay in
  `~/Library/Application Support/Flash`, readable only by you. Clipboard
  history skips items that password managers mark as concealed or transient.

## How it compares

| | License | Hints from | Also has | Flash adds |
| --- | --- | --- | --- | --- |
| [Neru](https://github.com/y3owk1n/neru) | MIT | Accessibility, optional OCR and contour detection | Grid, bisect, scroll mode, Linux and Windows | Accessibility only, normal mode with per-app actions, search, status bar, widgets, popups, plugins |
| [Homerow](https://www.homerow.app) | Paid, closed | Accessibility | Scroll, search | Free, configured in a file, everything past clicking |
| [Shortcat](https://shortcat.app) | Closed | Accessibility, by typing visible text | | `mouse_target --search` does that, next to labels |
| [Scoot](https://github.com/mjrusso/scoot) | BSD-3 | Accessibility | Grid | Normal mode, terminal hints, search, plugins |
| [Vimac](https://github.com/nchudleigh/vimac) | GPL, unmaintained | Accessibility | Scroll | Homerow's open-source predecessor; Flash is maintained |
| Wooshy, Mouseless, Superkey | Paid | Accessibility or text seek | | Superkey's text seek needs Screen Recording; Flash does not |
| [Vimium](https://github.com/philc/vimium), Surfingkeys | MIT | The DOM, in the browser | | Every app, no extension |
| [Hammerspoon](https://www.hammerspoon.org) | MIT | | Lua automation of everything | A ready-made keyboard layer in TOML; see the [migration guide](docs/hammerspoon.md). Hammerspoon can drive Flash with `flash <verb>` |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | GPL | | Scriptable bar | tmux formats, and one plugin feeds the bar, hints, search and widgets |
| [Übersicht](https://github.com/felixhageloh/uebersicht), conky | GPL | | Web-view widgets; conky needs XQuartz | Native text widgets fed by the bar's collectors |
| Raycast, Alfred | Closed | | Launchers | flashlight covers apps, tabs, emoji and quick math; Flash's focus is acting on what is on screen, and it runs fine next to them |

Window managers are not on the list on purpose: Flash moves and focuses
windows but does not tile. It runs next to AeroSpace, yabai or Rectangle.

Flash only sees what an app exposes to Accessibility. Canvas-drawn interfaces
and some games show no hints; use the grid there.

## Performance

Flash prepares each focused window's targets in the background as it changes,
so most activations draw hints without walking the app. Every activation logs
its latency from the keypress to the frame that shows the hints;
[performance](docs/performance.md) has the method, the benchmark script, and
measurements.

## FAQ

**Is it Vim?** No. NORMAL, INSERT and COMMAND are borrowed from Vim because
they are a good way to make one keyboard do two jobs; the bindings are
Vimium's and your own, not an editor's.

**Does it work in Electron apps and Chrome?** Yes, through the Accessibility
tree Chromium exposes once an assistive client asks for it. Flash prepares a
window's targets in the background as it changes; a prepared window shows
hints in a fraction of a millisecond, and a cold walk of a small page takes
10 to 25 ms on an M4 Pro. A canvas, a game or a remote desktop exposes
nothing; use the grid.

**Is the key tap a keylogger?** It runs only while Flash owns input, decides
swallow or pass for each key, and never stores anything. The tap lives in one
file, `KeyboardCaptureTap.swift`, and a guardrail rejects any other tap or
global key monitor.

**What does it cost at idle?** Hints follow Accessibility events and tmux
follows its control client, so nothing polls for them. Whatever must poll
(CPU, battery, a feed) ticks on the one scheduler in the process, which
coalesces wake-ups and pauses when the display sleeps. The budget and the
script that measures it are in [performance](docs/performance.md).

**Why not Hammerspoon, Karabiner, SketchyBar and a tiler?** You can keep
them. Flash is the part that wants a single modal layer and a single file:
hints, modes and the bar sharing one set of plugins. It does not tile, remap
hardware keys or run Lua.

**Non-QWERTY keyboard?** Labels, grid keys and mappings are read by key
position, so AZERTY, Dvorak and non-Latin input sources work without
configuration (`[app] keyboard_layout`).

**Several displays?** Hints cover the focused window; `--scope=screen` labels
every app on the screen. Tab moves the grid to the next display. The bar sits
on the display you choose, and each widget can sit on one display or all of
them.

## Troubleshooting

- **Start with `flash doctor`.** It checks permissions, key capture, secure
  input, your configuration, hotkeys taken by other apps, and plugins.
- **No hints at all.** Check that Flash is enabled under Accessibility and
  that a hotkey is mapped. Then see `~/Library/Logs/Flash/flash.log`.
- **Hints stopped after an update.** Remove Flash from the Accessibility list
  and add it again (see [Install](#install)).
- **Missing or misplaced hints in one app.** Set
  `[debug] show_hints_bounds = true` to draw what Flash sees, and please
  [open an issue](https://github.com/aymericbeaumet/flash/issues) with the app
  name and version.
- **A hotkey does nothing.** Another app may own it; `flash doctor` lists
  refused hotkeys. Flash reports invalid mappings when you save the file.
- **Hints ignore your keys under a non-Latin input source.** Set
  `[app] keyboard_layout = "auto"` (the default) or name a layout explicitly.

## Quit and uninstall

Quit from the menu-bar icon or with `flash quit`. Set `[app] autostart = false`
to stop Flash from starting at login, and `[app] menu_bar_icon = false` to hide
the icon.

```sh
brew uninstall --cask --zap flash@nightly
```

`--zap` also removes your configuration, logs, and local data.

## Status

Flash is pre-1.0 and used daily by its author on macOS 26. There is one
rolling `nightly` release, built and published by CI from `main` on every push
that passes the full test and plugin gate. Expect configuration keys to be
renamed without compatibility shims until a tagged release; `flash
config_check` rejects the old ones and the commit that renamed them says
what to write instead.

## Community

Bug reports with the app name and version, new plugins, and your bar and
widget setups are all welcome: open an
[issue](https://github.com/aymericbeaumet/flash/issues/new/choose) or send a
pull request adding your setup to [`docs/examples`](docs/examples). See
[CONTRIBUTING.md](CONTRIBUTING.md) before changing code, and
[SECURITY.md](SECURITY.md) for private reports.

## Documentation

- **Using Flash:** [configuration](docs/configuration.md) ·
  [full default reference](config.default.toml) · [commands](docs/commands.md) ·
  [windows](docs/windows.md) · [audio devices](docs/audio.md) ·
  [from Hammerspoon](docs/hammerspoon.md) ·
  [normal mode](docs/normal-mode.md) · [flashlight](docs/flashlight.md) ·
  [privacy](docs/privacy.md)
- **Status bar and widgets:** [format](docs/status-format.md) ·
  [widgets](docs/widgets.md) ·
  [example](docs/examples/statusbar/README.md) · [calendar](docs/calendar.md) ·
  [popups](docs/popups.md)
- **Integrations and plugins:** [writing a plugin](docs/plugin-cookbook.md) ·
  [plugin protocol](docs/plugin-protocol.md) · [Rust SDK](docs/plugin-rust-sdk.md)
- **Contributing:** [development and tests](docs/development.md) ·
  [architecture](docs/architecture.md) · [observability](docs/observability.md) ·
  [performance](docs/performance.md)

## License

Flash is released under the [MIT License](LICENSE).
