# Flash and polybar

[polybar](https://github.com/polybar/polybar) is "A fast and easy-to-use
tool for creating status bars", made "without the need of having a black
belt in shell scripting": an ini file of bars and modules, built-in modules
for CPU, memory, battery, network, ALSA and PulseAudio, i3 and bspwm
workspaces, a tray and MPD, `custom/script` and `custom/ipc` modules for
everything else, and `%{A1:…:}` action tags for clicks. It is MIT C++ for
X11, about 15,400 stars, 3.7.2 in August 2024, with the last commit in
September 2025. It has no macOS port or Homebrew formula: it docks into an
X11 desktop, which macOS does not have. [SketchyBar](sketchybar.md) is the scriptable macOS bar; Flash's
[status bar](../statusbar.md) covers the common polybar setup with
plugins instead of modules and runs your scripts as sources.

| | polybar | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | X11 (Linux and the BSDs) | macOS 13+ |
| Placement | Any number of bars, top or bottom, per monitor, any size | One bar in the top band of each display, or the primary one |
| Built-in data | Internal modules: date, CPU, memory, filesystem, battery, network, backlight, volume, workspaces, window title, MPD, tray | The sysinfo plugin (CPU, memory, disks, network, battery), the focused app, top processes, calendar, workspaces with tiling |
| Scripts | `custom/script` (`exec`, `interval`, `tail`), `custom/ipc` hooks | Named sources and `#()` jobs; `output = "i3blocks"` and `"waybar"` for other bars' scripts |
| Clicks, scroll | `click-left`, `scroll-up` and `%{A1:…:}` on any text | `#[range=user\|name]` spans bound in `[statusbar.click]`; clicks only |
| Configuration | `config.ini`, `polybar-msg cmd restart` | TOML, live reload |
| Maintenance | 3.7.2, August 2024; quiet since 2025 | 1.1.0, October 2026 |

## Where polybar is stronger

- **Bars where you want them.** Bottom bars, several bars per monitor,
  fixed widths, offsets and per-bar fonts. macOS has one menu bar band per
  display; Flash's bar takes that band, auto-hiding the native menu bar,
  and offers nothing else.
- **A tray.** polybar hosts the X system tray. macOS status items belong to
  the native menu bar; Flash cannot embed them, so they show when the native
  bar is revealed at the top edge, and `mouse menubar` labels them.
- **Scroll actions and button numbers.** `scroll-up`, `double-click-left`
  and `%{A3:…:}` for a right-click. Flash runs one action per range on a
  click, and a right-click on the bar pins a popup.
- **Ramps, icons and formats per state.** `<ramp-capacity>`, `label-charging`,
  `format-disconnected` and fonts per module. Flash draws text, meters and
  sparklines, with tmux conditionals for states.
- **A long tail of community scripts** in polybar-scripts, written for
  Linux tools (`pactl`, `nmcli`, `playerctl`) that macOS does not have.

## Where Flash is stronger

- **No scripts for the usual modules.** The sysinfo plugin samples CPU,
  memory, disks, network and battery in-process, on one clock that pauses
  while the displays sleep, and only while something shows them.
- **Hover popups with real programs.** `#[popup=btop]` opens btop in a PTY
  under the label; a `custom/script` click would have to launch a terminal.
- **Keyboard access to the bar.** `f` in NORMAL labels every link and click
  range on the bar too.
- **One file** for the bar, its click actions, desktop widgets and the
  keys that drive them.

## Flash features you might like

- `#[meter=10]#{flash.plugin.sysinfo.cpu_percent}#[nometer]` and
  `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` for polybar's
  `<bar-load>` and `<ramp-coreload>`.
- `flash status set` and `flash status refresh`, the two halves of
  `polybar-msg action`, from any script or hotkey
  ([pushed status values](../commands.md#pushed-status-values)).
- [Desktop widgets](../widgets.md) from the same template, for what used to
  be a second, bottom bar of figures.
- `#(script)` publishes each complete line a running job prints, which is
  what `tail = true` gives a polybar script
  ([jobs and sources](../status-format.md#jobs-sources-and-flash-styles)).

## Moving from polybar

| polybar | Flash |
| --- | --- |
| `[bar/main]`, `monitor =` | `[statusbar] enabled = true`, `monitor = "all"` or `"primary"` |
| `modules-left`, `modules-center`, `modules-right` | `#[align=left]`, `#[align=centre]`, `#[align=right]` in `template` |
| `internal/date` with `date = %H:%M` | `%H:%M` written in the template |
| `internal/cpu`, `internal/memory` | `#{flash.plugin.sysinfo.cpu_percent}`, `#{flash.plugin.sysinfo.memory_percent}` |
| `internal/fs` on `/` | `#{flash.plugin.sysinfo.disks_percent}` |
| `internal/battery` | `#{flash.plugin.sysinfo.power_percent}`, `power_state` |
| `internal/network` | `#{flash.plugin.sysinfo.network_address}`, `network_down_bps` |
| `internal/i3`, `internal/bspwm`, `internal/xworkspaces` | `#{flash.workspace}` and `#{flash.workspaces}` with `[tiling]` on |
| `internal/xwindow` | `#{flash.focused_app_name}`, the app rather than the window title |
| `custom/script` with `exec` and `interval` | `[statusbar.sources.<name>]` with `command` and `interval` |
| `tail = true` | A `#(script)` job |
| `env-FOO = bar` | `env = { FOO = "bar" }` on the source |
| `custom/ipc` with `hook-0`, `polybar-msg action "#name.hook.0"` | `flash status refresh --name=<source>`, or a source without a command and `flash status set` |
| `%{A1:pavucontrol:}VOL%{A}` | `#[range=user\|vol]VOL#[norange]` and `vol = [...]` in `[statusbar.click]` |
| `%{F#f00}…%{F-}` | `#[fg=#ff0000]…#[default]` |
| `label-maxlen = 30` | `#{=30:…}`, or `#[shrink]` to cut first on overflow |
| `internal/tray` | Not available |

```toml
[statusbar]
enabled = true
template = """
#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.focused_app_name}
#[align=right]#[range=user|vol]VOL #{flash.source.volume}#[norange]
 · CPU #[meter=8]#{flash.plugin.sysinfo.cpu_percent}#[nometer]
 · #{?#{e|<:#{flash.plugin.sysinfo.power_percent},20},#[fg=red],}BAT #{flash.plugin.sysinfo.power_percent}%%#[default]
 · %a %d %H:%M
"""

[statusbar.sources.volume]
command = ["/usr/bin/osascript", "-e", "output volume of (get volume settings)"]
interval = 30

[statusbar.click]
vol = ["flash", "volume", "mute"]
```

Newlines in the template are ignored, so each line above continues the
bar where the last one stopped; `%%` is a literal percent sign. A hotkey running
`sh -c 'flash volume up; flash status refresh --name=volume'` updates the
value at once, as a polybar hook would.

*Checked 2026-10-23 against the polybar [README](https://github.com/polybar/polybar),
its releases, and the wiki pages for
[custom/script](https://github.com/polybar/polybar/wiki/Module:-script),
[custom/ipc](https://github.com/polybar/polybar/wiki/Module:-ipc) and
[formatting](https://github.com/polybar/polybar/wiki/Formatting).*
