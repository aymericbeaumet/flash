# flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/aymericbeaumet/flash)](https://github.com/aymericbeaumet/flash/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Your keyboard, all of macOS.**

What Vimium does in the browser, Flash does in every app: press a hotkey, type
the label on the thing you want, and it is clicked. Then keep going: a Vim-like
normal mode over all of macOS, a mouse grid, a tmux-style status bar, desktop
widgets and terminal popups, all from one TOML file. Flash never reads your
screen.

<!-- Recorded media, listed in docs/assets/README.md, goes here.
![Hints in Safari, System Settings and the Dock](docs/assets/hero.gif)

*Press the hotkey, labels appear on every link, button and field, type one and
it is clicked: the same keys in Safari, System Settings and the Dock.*
-->

Flash is free and open source (MIT), written in Swift with plugins in Rust. It
needs macOS 13 or later on Intel or Apple Silicon and the Accessibility permission.

## Install

```sh
brew install --cask aymericbeaumet/tap/flash
```

The cask opens Flash once it is installed. Releases are not notarized yet,
so macOS first asks you to allow it: **System Settings → Privacy & Security →
Open Anyway**. Flash then opens the **Accessibility** pane; turn Flash on.
Press **⌘⇧Space** in any app and type the letters on the control you want.
Escape cancels.

[Install and update](docs/install.md) covers the direct download from GitHub
Releases, the nightly cask, the `flash` command without Homebrew, updates and
uninstalling. Current builds are ad-hoc signed, so an update asks for
Accessibility again ([permissions after an update](docs/install.md#permissions-after-an-update)).

## First five minutes

Flash wrote `~/.config/flash/flash.toml` with one mapping and, commented out,
the next three: the keyboard grid, search, and normal mode. Open it from the
menu-bar icon (**Open Configuration**), uncomment a shortcut, save. Enable
both NORMAL and INSERT shortcuts together: while NORMAL is on, keys you have
not mapped are swallowed rather than typed, and `i` (or your INSERT shortcut,
⌘⌃I below) hands the keyboard back; a click never does. Escape cancels
hints, else it is the app's own Escape (a popover or a dialog closes); it
does not leave NORMAL. Changes apply on save. Add entries to the
existing table instead of declaring `[mode.all.mappings]` again. Run
`flash help show` for this Mac's setup checklist.

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]                            # hints
"cmd+shift+alt+space" = ["flash", "mouse", "grid"]                          # keyboard grid
"cmd+ctrl+alt+space" = ["flash", "mode", "flashlight"]                      # search
"cmd+ctrl+[" = ["flash", "mode", "normal"]                                  # normal mode
"cmd+ctrl+i" = ["flash", "mode", "insert"]
```

[Getting started](docs/getting-started.md) continues from there: the status
bar, widgets, remapping defaults, plugins, and a table for people coming from
i3, sway or Hyprland with keynav, conky, polybar and rofi.
[Coming from Vim](docs/vim.md) maps Vim's modes, keys and ex commands onto
NORMAL, and [How Flash works](docs/concepts.md) names the pieces.

## What you get

<!-- Recorded media, listed in docs/assets/README.md, goes here.
![Normal mode in Firefox](docs/assets/normal-mode.gif)

*NORMAL mode in Firefox: `f` then a label clicks, `]t` changes tab, `ctrl+d`
scrolls, `/` opens Find and `i` switches to INSERT while you type.*
-->

- **Hints.** Label every visible button, link, tab, and field, then click,
  right-click, double-click, drag, or move the pointer to it. Menu bars, the
  Dock, and Notification Center too.
- **Normal mode.** A persistent, Vim-like layer over all of macOS. Keys map to
  commands that fit the focused app: `]t` is the next browser tab, Finder tab
  or tmux window.
- **Keyboard grid.** The screen is split like the left half of your keyboard.
  Press the key where you want to go, again to refine, for apps that expose
  nothing to Accessibility.
- **Terminal hints.** The bundled terminals plugin labels tmux panes, URLs,
  file paths and status-bar tabs inside your terminal.
- **Windows.** Switch to any window from `:ls`, most recently used
  first, one hint label per window; focus the nearest window in a direction,
  place windows with shortcuts or opt-in app/title rules, and control native
  full screen.
- **flashlight.** A command bar over apps, browser tabs, tmux windows, emoji
  and plugin data, with inline math, unit and currency answers,
  and every DuckDuckGo and Kagi bang resolved on your Mac.
- **Status bar, widgets and popups.** tmux-format templates with meters,
  sparklines and shell jobs, fed by system plugins or any command; hover a
  segment for a terminal popup running btop, newsboat or calcurse.
- **Plugins.** Any program that speaks JSON lines over stdin and stdout; a
  Rust SDK is included.

<!-- Recorded media, listed in docs/assets/README.md, goes here.
| | |
| --- | --- |
| ![Keyboard grid](docs/assets/grid.gif) | ![tmux hints](docs/assets/tmux-hints.png) |
| *The grid in an app with no Accessibility tree: one key zooms, the next clicks.* | *tmux: hints on panes, the URL and path in a `git log`, and the window tabs.* |
| ![flashlight](docs/assets/flashlight.png) | ![Status bar and widgets](docs/assets/statusbar-widgets.png) |
| *flashlight ranking browser tabs and tmux windows, with `1234 eur in usd` answered inline.* | *The bar from `docs/examples/statusbar` and two desktop widgets, drawn below every window.* |

![A terminal popup running btop under the CPU segment](docs/assets/popup-btop.png)

*Hovering the bar's CPU segment opens a popup: a real terminal running btop.*
-->

Everything reloads live when you save. There is no preferences window; the
menu-bar icon offers About, Open Configuration, and Quit.

## Modular, and loaded on demand

Flash is one small resident process plus plugins. Each plugin is a separate
program with declared capabilities. Most run in a sandbox; plugins that need
unsandboxed access are listed in the [privacy inventory](docs/privacy.md#plugin-isolation).
Any plugin can be turned off with one line (`[plugins] disabled = ["feed"]`).
The surfaces you do not configure do not exist at runtime:

| You configure | Flash starts | Otherwise |
| --- | --- | --- |
| A hotkey | That one hotkey registration | Nothing registered |
| `[statusbar] enabled = true` | The bar, its clock and the plugins its template names | No bar polling, the native menu bar untouched |
| `[widgets.<name>]` | One desktop window per widget per display, its sources | No windows |
| `[monitors.<name>]` (battery, disk, memory and plugin health are built in) | Its evaluation beside the bar, the plugins and sources its value reads, an alert when it crosses a threshold | Nothing evaluated |
| A terminal popup | A process when opened; persistent and prewarmed popups start ahead | No PTY |
| A status plugin named in a template (feed, the AI quotas…) | That plugin, while a visible surface reads it | Not running |
| A `sysinfo` segment in a template (CPU, memory, disks, network, battery) | That domain's sampling, while a visible surface reads it | No sampling |
| A command such as `:screenshot screen` | Its plugin on first use | Not running |
| A mapping that runs a plugin command | That plugin, once launch has settled | Started by its first command |
| `:help` or `[debug] http_inspector_enabled` | The local help server | No listener |
| `[startup] run` (a `defaults write` line, `killall Dock`…) | Those commands, once after launch, in order | Nothing run, no macOS setting touched |

What does start at launch, with any configuration: the Accessibility
observer for the focused app, so hints are ready before you press the key;
one on the Dock, so `missioncontrol show` and `hide` know which view is up;
the keyboard tap that decides which keys Flash swallows; the private socket
the `flash` command and your scripts reach it through, idle until one
connects ([IPC protocol](docs/ipc-protocol.md)); the plugins that
feed hints and search (browsers, terminals and the other catalog sources),
from 2 MB to about 30 MB each ([footprint](docs/performance.md#footprint));
and, until you disable them, the
built-in [monitors](docs/monitors.md), which keep the `sysinfo` plugin's
battery and disk figures sampled. The [architecture guide](docs/architecture.md#what-starts-at-launch)
lists every one with its cost, and `flash resident status` and the `/plugins` help
page show what is running on your Mac right now.

## What Flash will not do

These are design rules, enforced by tests and a guardrail script, not plans.

- **Never read the screen.** No OCR, no Vision, no pixel access. Hints come
  from the Accessibility tree and window geometry; apps that expose nothing
  get the keyboard grid instead. `:screenshot screen` runs Apple's `screencapture`
  straight to the clipboard, and no image passes through Flash.
- **Never record keys.** One keyboard tap, in one file, decides whether a key
  is swallowed or passed through. It never logs, stores or sends keystrokes.
- **No SIP changes, no injected code, no helper daemons.** One process,
  autostart through the standard login item, public frameworks plus three
  private interfaces looked up at run time (the Dock's request entry point for
  Mission Control and its siblings, a window-server property that hides the
  pointer behind hints, gesture event fields), each behind a fallback that
  only disables what needs it ([architecture](docs/architecture.md#coordinates-and-rendering)).
- **No preferences window, no accounts, no analytics, no crash reports.**
  Nothing reports on you: the requests a default install makes (GitHub's
  releases API, daily, for [updates](docs/updates.md); the ECB's daily
  exchange rates for inline currency answers; DuckDuckGo's public bang list
  when the flashlight opens) carry no data of yours, and the
  [privacy page](docs/privacy.md#network) lists every
  destination with the line that turns it off. OpenTelemetry export goes
  only to an endpoint you configure. The configuration file is the whole
  interface; `flash config check` validates it in CI.
- **Assemble, don't replace.** When a maintained tool already does the job
  (btop, newsboat, calcurse), Flash shows it in a popup instead of growing a
  copy of it.

## Privacy

Hints and clicks need Accessibility. Flash never reads screen pixels or asks
for Input Monitoring, and it sends no analytics, and no telemetry unless you
point its OpenTelemetry exporter at an endpoint. It checks GitHub daily for
its own releases (`[app] updates = "off"` stops it).
Optional features and bundled plugins can request other permissions; every
prompt, request and file is listed on the [privacy page](docs/privacy.md).

- **Screen.** Hints come from the Accessibility tree and window geometry. Flash
  never reads screen pixels. The optional `:screenshot screen` command runs macOS
  `screencapture` and asks for Screen Recording only when you use it.
- **Keyboard.** One session keyboard tap decides whether to swallow or pass
  each key. It never records what you type in other apps. Queries submitted
  in Flash's own command bar are kept in a local history.
- **Other prompts.** Listing browser tabs asks for Automation of that browser.
  The first flashlight search of Notes, Reminders or Contacts asks for
  Automation of Notes, or for Reminders or Contacts access. Showing the next
  meeting in the bar, or `calendar join`, asks for Calendars access. A
  command you configure yourself, such as a calendar CLI in a widget, triggers
  its own prompt, attributed to Flash. Releasing a stuck secure-input flag can
  also request Automation of its holding app or System Events. Restarting,
  shutting down, logging out or toggling dark mode from Flash asks for
  Automation of System Events, and emptying the Trash for Finder.
- **macOS settings.** Flash changes none beyond the menu bar's auto-hide
  while its status bar is on. The [startup commands](docs/startup.md) you
  list (`defaults write`, `killall Dock`) run once at each launch, as you,
  and change exactly what they change.
- **Network.** By default, `answers` fetches daily exchange rates from the
  ECB, `searchproviders` downloads DuckDuckGo's public bang list at most
  once a week when you open the flashlight. Search bangs open the site
  directly, never through a
  search engine's redirect. Feeds and remote tmux over SSH are off until you
  configure them. AI-provider quota reads start only when their status
  segments are displayed; they use the sign-in Claude Code, Codex or Grok
  already holds, talk to that provider alone, never refresh or store a
  token, and what they read is detailed in the privacy inventory.
  Configured third-party plugins download their pinned commit from GitHub;
  browser help serves a local loopback page; the `flash` command's socket is
  a local file only your account can use, never a network port. The OpenTelemetry receiver
  (loopback only, memory only) and exporter (to the endpoint you set) are off
  until you configure them. Disable any plugin with
  `[plugins] disabled = ["<id>"]`.
- **Local data.** Clipboard history, command history, ranking data and a copy
  of your Chrome and Firefox history (for the `browsers` history sources) stay in
  `~/Library/Application Support/Flash`, readable only by you. Clipboard
  history skips items that password managers mark as concealed or transient.

## How it compares

Flash covers ground that usually takes several apps. Each line is one of
those areas, the tools people use for it, and a page that says honestly
where they are better and how to move over.

| Area | In Flash | Tools it compares with |
| --- | --- | --- |
| Clicking by keyboard | Hints, search, grid, bisect, drag, selection | [Neru](docs/alternatives/neru.md) · [Homerow](docs/alternatives/homerow.md) · [Shortcat](docs/alternatives/shortcat.md) · [Scoot](docs/alternatives/scoot.md) · [Vimac](docs/alternatives/vimac.md) · [Mouseless](docs/alternatives/mouseless.md) · [Wooshy](docs/alternatives/wooshy.md) · [Superkey](docs/alternatives/superkey.md) · [warpd](docs/alternatives/warpd.md) · [Neverclick](docs/alternatives/neverclick.md) · [mousemaster](docs/alternatives/mousemaster.md) |
| Vim keys everywhere | NORMAL, INSERT, COMMAND and TERMINAL modes across every app | [Vimium](docs/alternatives/vimium.md) · [Surfingkeys](docs/alternatives/surfingkeys.md) · [Tridactyl](docs/alternatives/tridactyl.md) · [Vimium C](docs/alternatives/vimium-c.md) · [Vimari](docs/alternatives/vimari.md) · [kindaVim](docs/alternatives/kindavim.md) · [SketchyVim](docs/alternatives/sketchyvim.md) |
| Keyboard automation | Mappings to any command or executable, per app, and layers of your own (skhd modes, modal hotkeys) | [Hammerspoon](docs/alternatives/hammerspoon.md) · [Karabiner-Elements](docs/alternatives/karabiner-elements.md) · [skhd](docs/alternatives/skhd.md) · [Hyperkey](docs/alternatives/hyperkey.md) · [Leader Key](docs/alternatives/leader-key.md) · [Keyboard Maestro](docs/alternatives/keyboard-maestro.md) · [BetterTouchTool](docs/alternatives/bettertouchtool.md) |
| Search and launching | flashlight: apps, tabs, windows, tmux, emoji, math, currency, plugin data | [Raycast](docs/alternatives/raycast.md) · [Alfred](docs/alternatives/alfred.md) · [Spotlight](docs/alternatives/spotlight.md) · [LaunchBar](docs/alternatives/launchbar.md) · [Kando](docs/alternatives/kando.md) |
| Status bar | tmux-format templates fed by plugins, shell jobs and SwiftBar, xbar, i3blocks or waybar scripts | [SketchyBar](docs/alternatives/sketchybar.md) · [SwiftBar](docs/alternatives/swiftbar.md) · [xbar](docs/alternatives/xbar.md) · [Ice](docs/alternatives/ice.md) · [Bartender](docs/alternatives/bartender.md) · [Hidden Bar](docs/alternatives/hidden-bar.md) · [MeetingBar](docs/alternatives/meetingbar.md) · [Itsycal](docs/alternatives/itsycal.md) |
| Desktop widgets | The same templates, drawn below your windows | [Übersicht](docs/alternatives/uebersicht.md) · [conky](docs/alternatives/conky.md) |
| Terminal popups | Any TUI in a real PTY under a bar segment | None; Flash shows btop, newsboat or calcurse instead of rebuilding them |
| System monitoring | Bar values and widgets, thresholds that raise an alert, btop in a popup; no temperature or fan sensors | [iStat Menus](docs/alternatives/istat-menus.md) · [Stats](docs/alternatives/stats.md) · [iStatistica](docs/alternatives/istatistica.md) · [TG Pro](docs/alternatives/tg-pro.md) · [eul](docs/alternatives/eul.md) · [MenuMeters](docs/alternatives/menumeters.md) · [btop](docs/alternatives/btop.md) · [htop](docs/alternatives/htop.md) · [Activity Monitor](docs/alternatives/activity-monitor.md) · [Glances](docs/alternatives/glances.md) · [Netdata](docs/alternatives/netdata.md) · [coconutBattery](docs/alternatives/coconutbattery.md) · [AlDente](docs/alternatives/aldente.md) · [Macs Fan Control](docs/alternatives/macs-fan-control.md) · [Sensei](docs/alternatives/sensei.md) |
| Window switching | Every window, most recently used first, one hint label per row, `@windows` search; no thumbnails, no hold-to-cycle | [AltTab](docs/alternatives/alttab.md) · [Witch](docs/alternatives/witch.md) · [Contexts](docs/alternatives/contexts.md) · [rcmd](docs/alternatives/rcmd.md) |
| Clipboard history | `!clip`: pins, images, plain-text paste, terminal-aware paste | [Maccy](docs/alternatives/maccy.md) · [Paste](docs/alternatives/paste.md) · [Clipy](docs/alternatives/clipy.md) · [CopyQ](docs/alternatives/copyq.md) |
| Window placement | Named positions kept through display changes, rules, directional focus, full screen, and opt-in AeroSpace-style [tiling and workspaces](docs/tiling.md) | [AeroSpace](docs/alternatives/aerospace.md) · [yabai](docs/alternatives/yabai.md) · [Rectangle](docs/alternatives/rectangle.md) · [Amethyst](docs/alternatives/amethyst.md) · [Loop](docs/alternatives/loop.md) · [Magnet](docs/alternatives/magnet.md) · [Moom](docs/alternatives/moom.md) · [Swish](docs/alternatives/swish.md) · [Phoenix](docs/alternatives/phoenix.md) |
| Plugins | Sandboxed JSON-lines processes in any language, one set for all of the above | Raycast's store, Hammerspoon's Spoons |

What Flash will not do: read pixels, run on Linux or Windows, remap
hardware keys or expand text. The [alternatives index](docs/alternatives/README.md)
says more, [coming from Linux](docs/alternatives/README.md#coming-from-linux) has a
page for each i3, Hyprland, rofi or Waybar setup, the [comparison table and FAQ](docs/comparison.md) is the one-screen
summary, and [troubleshooting](docs/troubleshooting.md) starts with `flash resident doctor`.

## Status

Flash is used daily by its author on macOS 26 on Apple Silicon. CI builds and
validates every release as a universal binary with a macOS 13 minimum;
reports from macOS 13, 14, 15 and Intel Macs are welcome. Every push to
`main` that passes the full test and plugin gate publishes a build: a tagged
release when the version changed, the rolling `flash@nightly` cask otherwise.
Renamed configuration keys get no compatibility shims; `flash config check`
rejects the old ones, names the command an old name most likely meant, and the
[changelog](CHANGELOG.md) says what to write instead.
[Troubleshooting](docs/troubleshooting.md#known-limitations) lists what is a
limitation rather than a bug.

## Community

Bug reports with the app name and version, new plugins, and your bar and
widget setups are all welcome: open an
[issue](https://github.com/aymericbeaumet/flash/issues/new/choose) or send a
pull request adding your setup to [`docs/examples`](docs/examples). See
[CONTRIBUTING.md](CONTRIBUTING.md) before changing code, and
[SECURITY.md](SECURITY.md) for private reports. Development runs entirely
through mise: `mise run setup` bootstraps a checkout, `mise run check` runs the
required checks, and [development](docs/development.md#tasks) lists every task.

## Documentation

- **Using Flash:** [install and update](docs/install.md) ·
  [getting started](docs/getting-started.md) ·
  [configuration](docs/configuration.md) ·
  [full default reference](config.default.toml) · [commands](docs/commands.md) ·
  [normal mode](docs/normal-mode.md) · [flashlight](docs/flashlight.md) ·
  [windows](docs/windows.md) · [audio devices](docs/audio.md) ·
  [from Hammerspoon](docs/alternatives/hammerspoon.md) · [from Neverclick](docs/alternatives/neverclick.md) ·
  [from mousemaster](docs/alternatives/mousemaster.md) · [privacy](docs/privacy.md) ·
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
