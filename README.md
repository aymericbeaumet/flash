# Flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

**Your keyboard, all of macOS.**

Click anything, drive every app from a Vim-like normal mode, and build your own
status bar and desktop widgets, all from one TOML file. Flash never reads your
screen.

Coming from i3, sway or Hyprland with keynav, conky, polybar and rofi? This is
that toolkit for macOS. Never edited a dotfile? Start with one hotkey.

<!-- Demo: a 10–15 s GIF of hotkey → labels → typed hint → click, in a browser and a native app. -->

Flash is free and open source (MIT). It needs macOS 14 or later and the
Accessibility permission, and nothing else.

## What you get

- **Hints.** Label every visible button, link, tab, and field, then click,
  right-click, double-click, drag, or move the pointer to it. Menu bars, the
  Dock, and Notification Center too.
- **Keyboard grid.** The screen is split like the left half of your keyboard
  (`12345` / `qwert` / `asdfg` / `zxcvb` on QWERTY, your layout's keys
  otherwise). Press the key where you want to go, again to refine. Bisect mode
  halves the screen with `hjkl`.
- **Terminal hints.** The bundled tmux plugin labels panes, URLs, and file paths
  inside your terminal.
- **Normal mode.** A persistent, Vim-like layer over all of macOS: `f` for
  hints, `[t` / `]t` for tabs, `gg` / `G`, `ctrl+d` / `ctrl+u` to scroll, `u` to
  undo.
- **flashlight.** A command bar that searches apps, browser tabs, tmux windows,
  emoji, and plugin data, with inline math, unit, and currency answers.
- **Status bar and desktop widgets.** tmux-format templates with meters,
  sparklines, conditionals and shell jobs, fed by system plugins (CPU, memory,
  disks, network, battery, top processes) or any command you write.
- **Plugins.** Any program that speaks JSON lines over stdin and stdout; a Rust
  SDK is included.

Everything reloads live when you save. There is no preferences window; the
menu-bar icon offers About, Open Configuration, and Quit.

## Install

```sh
brew install --cask aymericbeaumet/tap/flash@nightly
```

This installs `Flash.app` and the `flash` command, and starts Flash. Then:

1. **Allow the first launch.** Builds are not notarized yet. If macOS says it
   could not verify Flash, open **System Settings → Privacy & Security** and
   click **Open Anyway**.
2. **Grant Accessibility.** Flash opens **System Settings → Privacy & Security →
   Accessibility** for you. Turn Flash on.

Nightly builds are ad-hoc signed, so macOS can drop the Accessibility grant
after an update while the toggle still shows as on. If hints stop working after
`brew upgrade`, remove Flash from the list with **−** and add it again.

To build from source, see [development](docs/development.md).

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
Press ⌘⌃I, click into a text field, or pick an input with `f` to type again.
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
"t" = false                                        # remove a default
"gb" = ["flash", "send_key", "--keys=cmd+shift+b"] # add your own
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
| i3, sway, Hyprland modes | NORMAL / INSERT / COMMAND with `[mode.*.mappings]` |
| i3 `move`, Hyprland dispatchers | `window_move` |
| swaymsg, hyprctl | `flash <verb>`, `flash status --json` |
| dotfiles | one `flash.toml`, live reload, `flash config_check` |

## Privacy

Flash asks for Accessibility only. It does not use Screen Recording, OCR, or
Input Monitoring, and it has no telemetry, analytics, or update checks.

- **Screen.** Hints come from the Accessibility tree and window geometry. Flash
  never reads screen pixels. The optional `:screenshot` command runs macOS
  `screencapture` and asks for Screen Recording only when you use it.
- **Keyboard.** A keyboard tap is active only while Flash owns input (hints,
  normal mode, the command bar). It decides whether to swallow or pass each key
  and never records what you type in other apps. Queries you submit in Flash's
  own command bar are kept in a local history.
- **Network.** Flash's core has no network features. A few bundled plugins
  fetch data, such as daily exchange rates, and remote tmux over SSH is off
  until you list hosts. Disable any plugin with `[plugins] disabled = ["<id>"]`.
- **Local data.** Clipboard history, command history, and ranking data stay in
  `~/Library/Application Support/Flash`. Clipboard history skips items that
  password managers mark as concealed or transient.

The [privacy page](docs/privacy.md) lists every permission prompt, network
request, and file for each plugin.

## How it compares

- **Neru** (MIT) is the closest open-source relative: hints, grid, recursive
  grid, bisect, and scroll modes, controlled over a Unix socket. Its optional
  OCR and contour detection need Screen Recording. Flash stays on
  Accessibility only and adds normal mode, search, a status bar, and widgets.
- **Homerow** is polished, closed source, and paid. Flash is free, MIT-licensed,
  configured in a file, and goes beyond clicking.
- **Vimac** was Homerow's open-source predecessor and is no longer maintained.
- **Shortcat** is free and closed source, and clicks by typing visible text.
  Flash has that as `mouse_target --search`, next to labels.
- **Scoot** (BSD-3) offers element hints and a grid. Flash adds normal mode,
  terminal hints, search, and plugins.
- **Wooshy**, **Mouseless**, and **Superkey** are paid. Superkey's text seek
  needs Screen Recording; Flash asks for Accessibility only.
- **Vimium** and **Surfingkeys** work inside the browser only. Flash covers the
  browser and every other app, with no extension.
- **Raycast** and **Alfred** are launchers. flashlight covers apps, tabs, emoji,
  and quick math, but Flash's focus is acting on what is on screen, and it runs
  fine next to them.
- **SketchyBar** is a scriptable bar. Flash's bar uses tmux formats and shares
  its plugins with hints, search, and widgets.
- **Übersicht** renders desktop widgets as web views, and **conky** needs
  XQuartz on macOS. Flash widgets are native text layers fed by the same
  collectors as the bar.
- **Hammerspoon** is a Lua automation toolkit. Flash is a ready-made keyboard
  layer in TOML, and Hammerspoon can drive it with `flash <verb>`.

Flash only sees what an app exposes to Accessibility. Canvas-drawn interfaces
and some games show no hints; use the grid there.

## Performance

Flash prepares each focused window's targets in the background as it changes,
so most activations draw hints without walking the app. Every activation logs
its latency from the keypress to the frame that shows the hints;
[performance](docs/performance.md) has the method, the benchmark script, and
measurements.

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

## Community

Flash is young and moves fast. Bug reports with the app name and version, new
plugins, and your bar and widget setups are all welcome: open an
[issue](https://github.com/aymericbeaumet/flash/issues) or send a pull request
adding your setup to [`docs/examples`](docs/examples).

## Documentation

- **Using Flash:** [configuration](docs/configuration.md) ·
  [full default reference](config.default.toml) · [commands](docs/commands.md) ·
  [normal mode](docs/normal-mode.md) · [flashlight](docs/flashlight.md) ·
  [privacy](docs/privacy.md)
- **Status bar and widgets:** [format](docs/status-format.md) ·
  [widgets](docs/widgets.md) ·
  [example](docs/examples/statusbar/README.md) · [calendar](docs/calendar.md) ·
  [usage and system popups](docs/status-popups.md) ·
  [terminal windows](docs/terminal-popups.md)
- **Integrations and plugins:** [Firefox tabs add-on](docs/firefox-extension.md) ·
  [writing a plugin](docs/plugin-cookbook.md) ·
  [plugin protocol](docs/plugin-protocol.md) · [Rust SDK](docs/plugin-rust-sdk.md)
- **Contributing:** [development and tests](docs/development.md) ·
  [architecture](docs/architecture.md) · [observability](docs/observability.md) ·
  [performance](docs/performance.md)

## License

Flash is released under the [MIT License](LICENSE).
