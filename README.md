# Flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

**Click anything on macOS from your keyboard.**

Press a hotkey and Flash puts a short label on every clickable control in the
app you are using. Type the label and Flash clicks it. It works in native apps,
browser pages, Electron apps, and tmux panes, with no per-app setup, no browser
extension, and no screen capture.

<!-- Demo: a 10–15 s GIF of hotkey → labels → typed hint → click, in a browser and a native app. -->

Flash is free and open source (MIT). It needs macOS 14 or later and the
Accessibility permission, and nothing else.

## What it does

- **Hints.** Label every visible button, link, tab, and field, then click,
  right-click, double-click, drag, or move the pointer to it.
- **Grid.** Reach any screen position when a control is not exposed to
  Accessibility.
- **Terminal hints.** The bundled tmux plugin labels panes, URLs, and file paths
  inside your terminal.
- **Normal mode (optional).** A persistent, Vim-like layer over all of macOS:
  `f` for hints, `[t` / `]t` for tabs, `gg` / `G`, `ctrl+d` / `ctrl+u` to
  scroll, `u` to undo. Press a key to go back to typing.
- **flashlight (optional).** A command bar that searches apps, browser tabs,
  tmux windows, emoji, and plugin data, with inline math, unit, and currency
  answers.
- **Status bar (optional).** A tmux-style top bar with mode, calendar, and
  system details, driven by the same plugins.

Everything is configured in one TOML file that reloads live. There is no
preferences window; the menu-bar icon offers About, Open Configuration, and
Quit.

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

## Get started

On first launch Flash creates `~/.config/flash/flash.toml` with one mapping:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
```

Press **⌘⇧Space**, then type the letters on the control you want. Press Escape
to cancel. Open the file from the menu-bar icon (**Open Configuration**) and add
more; changes apply as soon as you save:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]                               # hints
"cmd+shift+alt+space" = ["flash", "mouse_grid"]                             # any screen position
"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "] # search
```

Keep the trailing space in `--input=:flashlight `: it opens search directly.
Try `@emojis.glyphs fire` or `1234 euros in dollars` in the search bar.

Pick hotkeys that are free on your Mac. macOS uses Control-Space and
Control-Option-Space to switch input sources, and many editors use
Control-Space for completion.

### Normal mode

Normal mode turns your keyboard into a remote for the frontmost app until you
leave it:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
```

While NORMAL is active, keys that are not mapped are captured instead of typed.
Press ⌘⌃I, click into a text field, or pick an input with `f` to type again.
NORMAL stays active across app and tab switches. See
[normal mode](docs/normal-mode.md) for every binding.

### Status bar

```toml
[statusbar]
enabled = true
```

The bar takes the top of the screen, so macOS auto-hides its own menu bar while
it is enabled. Start from the [ready-to-use example](docs/examples/statusbar/README.md)
or write your own [format](docs/status-format.md).

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

- **Homerow** is the polished commercial option (closed source, paid). Flash is
  free, MIT-licensed, and configured in a file.
- **Neru** and **Scoot** are open-source hint and grid tools. Flash puts more
  weight on a persistent normal mode, terminal and tmux hints, a command bar,
  and plugins, and it never uses OCR.
- **Vimac** is no longer maintained.
- **Vimium** and **Surfingkeys** work inside the browser only. Flash covers the
  browser and every other app.

Flash only sees what an app exposes to Accessibility. Canvas-drawn interfaces
and some games show no hints; use the grid there.

## Troubleshooting

- **No hints at all.** Check that Flash is enabled under Accessibility and
  that a hotkey is mapped. Then see `~/Library/Logs/Flash/flash.log`.
- **Hints stopped after an update.** Remove Flash from the Accessibility list
  and add it again (see [Install](#install)).
- **Missing or misplaced hints in one app.** Set
  `[debug] show_hints_bounds = true` to draw what Flash sees, and please
  [open an issue](https://github.com/aymericbeaumet/flash/issues) with the app
  name and version.
- **A hotkey does nothing.** Another app may own it. Pick a different
  combination; Flash reports invalid mappings when you save the file.

## Quit and uninstall

Quit from the menu-bar icon or with `flash quit`. Set `[app] autostart = false`
to stop Flash from starting at login, and `[app] menu_bar_icon = false` to hide
the icon.

```sh
brew uninstall --cask --zap flash@nightly
```

`--zap` also removes your configuration, logs, and local data.

## Documentation

- **Using Flash:** [configuration](docs/configuration.md) ·
  [full default reference](config.default.toml) · [commands](docs/commands.md) ·
  [normal mode](docs/normal-mode.md) · [flashlight](docs/flashlight.md) ·
  [privacy](docs/privacy.md)
- **Status bar:** [format](docs/status-format.md) ·
  [example](docs/examples/statusbar/README.md) · [calendar](docs/calendar.md) ·
  [usage and system popups](docs/status-popups.md) ·
  [terminal windows](docs/terminal-popups.md)
- **Integrations and plugins:** [Firefox tabs add-on](docs/firefox-extension.md) ·
  [writing a plugin](docs/plugin-cookbook.md) ·
  [plugin protocol](docs/plugin-protocol.md) · [Rust SDK](docs/plugin-rust-sdk.md)
- **Contributing:** [development and tests](docs/development.md) ·
  [architecture](docs/architecture.md) · [observability](docs/observability.md)

## License

Flash is released under the [MIT License](LICENSE).
