# flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/aymericbeaumet/flash)](https://github.com/aymericbeaumet/flash/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Your keyboard, all of macOS.**

What Vimium does in the browser, Flash does in every app: press a hotkey, type
the label on the thing you want, and it is clicked. Then keep going: a Vim-like
normal mode over all of macOS, a mouse grid, a tmux-style status bar, desktop
widgets and terminal popups, all from one TOML file. Flash never reads your
screen.

![Hints in Safari, System Settings and the Dock](docs/assets/hero.gif)

*Press the hotkey, labels appear on every link, button and field, type one and
it is clicked: the same keys in Safari, System Settings and the Dock.*

Flash is free and open source (MIT), written in Swift with plugins in Rust. It
needs macOS 14 or later and the Accessibility permission.

## Install

```sh
brew install --cask aymericbeaumet/tap/flash
```

1. If macOS says it could not verify Flash, open **System Settings → Privacy &
   Security** and click **Open Anyway**.
2. Flash opens **System Settings → Privacy & Security → Accessibility**. Turn
   Flash on.
3. Press **⌘⇧Space** in any app and type the letters on the control you want.
   Escape cancels.

That is the whole setup. `flash@nightly` is the rolling build from `main`;
[development](docs/development.md) covers building from source.

## First five minutes

Flash wrote `~/.config/flash/flash.toml` with one mapping and, commented out,
the next three: the keyboard grid, search, and normal mode. Open it from the
menu-bar icon (**Open Configuration**), uncomment a line, save. Changes apply
on save, and `:help` opens a checklist of what is set up on this Mac.

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]                                   # hints
"cmd+shift+alt+space" = ["flash", "mouse_grid"]                                 # keyboard grid
"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "]  # search
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]                                   # normal mode
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
```

[Getting started](docs/getting-started.md) continues from there: the status
bar, widgets, remapping defaults, plugins, and a table for people coming from
i3, sway or Hyprland with keynav, conky, polybar and rofi.

## What you get

![Normal mode in Firefox](docs/assets/normal-mode.gif)

*NORMAL mode in Firefox: `f` then a label clicks, `]t` changes tab, `ctrl+d`
scrolls, `/` opens Find and switches to INSERT while you type.*

- **Hints.** Label every visible button, link, tab, and field, then click,
  right-click, double-click, drag, or move the pointer to it. Menu bars, the
  Dock, and Notification Center too.
- **Normal mode.** A persistent, Vim-like layer over all of macOS. Keys map to
  actions that fit the focused app: `]t` is the next browser tab, Finder tab
  or tmux window.
- **Keyboard grid.** The screen is split like the left half of your keyboard.
  Press the key where you want to go, again to refine, for apps that expose
  nothing to Accessibility.
- **Terminal hints.** The bundled tmux plugin labels panes, URLs, file paths
  and status-bar tabs inside your terminal.
- **Windows.** Focus the nearest window in a direction, place windows with
  shortcuts or opt-in app/title rules, and control native full screen.
- **flashlight.** A command bar over apps, browser tabs, tmux windows, native
  windows, emoji and plugin data, with inline math, unit and currency answers.
- **Status bar, widgets and popups.** tmux-format templates with meters,
  sparklines and shell jobs, fed by system plugins or any command; hover a
  segment for a terminal popup running btop, newsboat or calcurse.
- **Plugins.** Any program that speaks JSON lines over stdin and stdout; a
  Rust SDK is included.

| | |
| --- | --- |
| ![Keyboard grid](docs/assets/grid.gif) | ![tmux hints](docs/assets/tmux-hints.png) |
| *The grid in an app with no Accessibility tree: one key zooms, the next clicks.* | *tmux: hints on panes, the URL and path in a `git log`, and the window tabs.* |
| ![flashlight](docs/assets/flashlight.png) | ![Status bar and widgets](docs/assets/statusbar-widgets.png) |
| *flashlight ranking browser tabs and tmux windows, with `1234 eur in usd` answered inline.* | *The bar from `docs/examples/statusbar` and two desktop widgets, drawn below every window.* |

![A terminal popup running btop under the CPU segment](docs/assets/popup-btop.png)

*Hovering the bar's CPU segment opens a popup: a real terminal running btop.*

Everything reloads live when you save. There is no preferences window; the
menu-bar icon offers About, Open Configuration, and Quit.

## Modular, and loaded on demand

Flash is one small resident process plus plugins. Each plugin is a separate
sandboxed program with its own declared capabilities, and any of them can be
turned off with one line (`[plugins] disabled = ["history"]`). The surfaces
you do not configure do not exist at runtime:

| You configure | Flash starts | Otherwise |
| --- | --- | --- |
| A hotkey | That one hotkey registration | Nothing registered |
| `[statusbar] enabled = true` | The bar, its clock and the plugins its template names | No bar, no polling, the native menu bar untouched |
| `[widgets.<name>]` | One desktop window per widget per display, its sources | No windows |
| `[popup.<name>]` | A terminal session the first time the popup is shown | No PTY |
| A status plugin named in a template (CPU, memory, disks, battery, feed…) | That plugin, while a visible surface reads it | Not running |
| A command such as `:screenshot` or `media` | Its plugin on first use | Not running |
| `:help` or `[debug] http_inspector_enabled` | The local help server | No listener |

What does start at launch, with any configuration: the Accessibility
observer for the focused app, so hints are ready before you press the key;
the keyboard tap that decides which keys Flash swallows; and the plugins that
feed hints and search (browsers, tmux, windows, clipboard and the other
catalog sources), each a few megabytes. The [architecture guide](docs/architecture.md#what-starts-at-launch)
lists every one with its cost, and `flash status` and the `/plugins` help
page show what is running on your Mac right now.

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

Flash covers ground that usually takes several apps. Each line is one of
those areas, the tools people use for it, and a page that says honestly
where they are better and how to move over.

| Area | In Flash | Tools it compares with |
| --- | --- | --- |
| Clicking by keyboard | Hints, search, grid, bisect, drag, selection | [Neru](docs/alternatives/neru.md) · [Homerow](docs/alternatives/homerow.md) · [Shortcat](docs/alternatives/shortcat.md) · [Scoot](docs/alternatives/scoot.md) · [Vimac](docs/alternatives/vimac.md) · [Mouseless](docs/alternatives/mouseless.md) · [Wooshy](docs/alternatives/wooshy.md) · [Superkey](docs/alternatives/superkey.md) · [warpd](docs/alternatives/warpd.md) · [Neverclick](docs/neverclick.md) · [mousemaster](docs/mousemaster.md) |
| Vim keys everywhere | NORMAL, INSERT, COMMAND and TERMINAL modes across every app | [Vimium](docs/alternatives/vimium.md) · [Surfingkeys](docs/alternatives/surfingkeys.md) |
| Keyboard automation | Mappings to any verb or executable, per app | [Hammerspoon](docs/alternatives/hammerspoon.md) |
| Search and launching | flashlight: apps, tabs, windows, tmux, emoji, math, currency, plugin data | [Raycast](docs/alternatives/raycast.md) · [Alfred](docs/alternatives/alfred.md) |
| Status bar | tmux-format templates fed by plugins and shell jobs | [SketchyBar](docs/alternatives/sketchybar.md) |
| Desktop widgets | The same templates, drawn below your windows | [Übersicht](docs/alternatives/uebersicht.md) · [conky](docs/alternatives/conky.md) |
| Terminal popups | Any TUI in a real PTY under a bar segment | None; Flash shows btop, newsboat or calcurse instead of rebuilding them |
| Window placement | Named positions, rules, directional focus, full screen; no tiling | [AeroSpace](docs/alternatives/aerospace.md) · [yabai](docs/alternatives/yabai.md) · [Rectangle](docs/alternatives/rectangle.md) |
| Plugins | Sandboxed JSON-lines processes in any language, one set for all of the above | Raycast's store, Hammerspoon's Spoons |

What Flash will not do: read pixels, run on Linux or Windows, tile, remap
hardware keys or expand text. The [alternatives index](docs/alternatives/README.md)
says more, the [comparison table and FAQ](docs/comparison.md) is the one-screen
summary, and [troubleshooting](docs/troubleshooting.md) starts with `flash doctor`.

## Status

Flash is used daily by its author on macOS 26. Every push to `main` that
passes the full test and plugin gate publishes a build: a tagged release when
the version changed, the rolling `flash@nightly` cask otherwise. Renamed
configuration keys get no compatibility shims; `flash config_check` rejects
the old ones and the release notes say what to write instead.

## Community

Bug reports with the app name and version, new plugins, and your bar and
widget setups are all welcome: open an
[issue](https://github.com/aymericbeaumet/flash/issues/new/choose) or send a
pull request adding your setup to [`docs/examples`](docs/examples). See
[CONTRIBUTING.md](CONTRIBUTING.md) before changing code, and
[SECURITY.md](SECURITY.md) for private reports.

## Documentation

- **Using Flash:** [getting started](docs/getting-started.md) ·
  [configuration](docs/configuration.md) ·
  [full default reference](config.default.toml) · [commands](docs/commands.md) ·
  [normal mode](docs/normal-mode.md) · [flashlight](docs/flashlight.md) ·
  [windows](docs/windows.md) · [audio devices](docs/audio.md) ·
  [from Hammerspoon](docs/hammerspoon.md) · [from Neverclick](docs/neverclick.md) ·
  [from mousemaster](docs/mousemaster.md) · [privacy](docs/privacy.md) ·
  [comparison and FAQ](docs/comparison.md) · [troubleshooting](docs/troubleshooting.md)
- **Status bar and widgets:** [format](docs/status-format.md) ·
  [widgets](docs/widgets.md) ·
  [example](docs/examples/statusbar/README.md) · [calendar](docs/calendar.md) ·
  [popups](docs/popups.md)
- **Integrations and plugins:** [writing a plugin](docs/plugin-cookbook.md) ·
  [plugin protocol](docs/plugin-protocol.md) · [Rust SDK](docs/plugin-rust-sdk.md)
- **Contributing:** [development and tests](docs/development.md) ·
  [releases and notarization](docs/release.md) ·
  [architecture](docs/architecture.md) · [observability](docs/observability.md) ·
  [performance](docs/performance.md)

## License

Flash is released under the [MIT License](LICENSE).
