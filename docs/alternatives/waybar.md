# Flash and Waybar

[Waybar](https://github.com/Alexays/Waybar) is a "Highly customizable
Wayland bar for Sway and wlroots-based compositors": a JSONC config of
modules styled with GTK CSS, workspace and window modules for Sway,
Hyprland, river, niri and others, battery, network, PulseAudio,
WirePlumber, MPRIS, Bluetooth, a tray, an idle inhibitor, and `custom`
modules fed by any script, with `return-type: json`, `signal` refreshes and
`on-click` actions. It is MIT C++, about 12,100 stars, 0.15.0 in February
2026, with commits in October 2026. It runs on Wayland compositors, none of
which exists on macOS. Flash's [status bar](../statusbar.md) reads your
custom modules' JSON as it is, and its plugins cover the built-in modules;
[SketchyBar](sketchybar.md) is the macOS bar to look at if the styling
matters most.

| | Waybar | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland compositors | macOS 13+ |
| Placement | Top, bottom, left or right, per output, several bars | The top band of each display, or the primary one |
| Styling | GTK CSS: classes, hover states, padding, borders, fonts | Colours and attributes in the template, meters, sparklines, pills |
| Custom modules | `exec`, `interval`, `signal`, `return-type: json` with `text`, `tooltip`, `class`, `percentage` | Sources with `output = "waybar"`, which keeps `text` |
| Actions | `on-click`, `on-click-right`, `on-scroll-up`, menus | Click ranges in `[statusbar.click]`, hover and pinned popups |
| Configuration | `config.jsonc` and `style.css`, reloaded on `SIGUSR2` | TOML, live reload |
| Maintenance | 0.15.0, February 2026; active | 1.1.0, October 2026 |

## Where Waybar is stronger

- **CSS.** Classes from a script's `class`, `:hover` rules, margins,
  rounded module backgrounds, per-module fonts. Flash's bar is a row of
  monospaced cells with colours and attributes.
- **Anywhere on any output.** Bottom and side bars, several per output.
  macOS gives one band at the top of each display, which Flash takes over
  while auto-hiding the native menu bar.
- **The tray, and compositor modules.** Waybar hosts StatusNotifier items
  and talks to Sway, Hyprland or niri directly. macOS keeps status items in
  its own menu bar, which Flash cannot embed; `mouse menubar` labels them
  when the native bar is revealed.
- **Tooltips, icons and scroll.** `format-icons` by `percentage`, tooltips
  from the JSON, `on-scroll-up` for volume. Flash drops `tooltip`, `class`
  and `percentage`, and binds clicks, not scrolls.
- **Hardware modules macOS keeps closed**, temperature among them: Flash
  reads no SMC sensor.

## Where Flash is stronger

- **Your custom scripts keep working.** `output = "waybar"` reads the last
  JSON line and keeps its `text`, without Pango markup, so a script needs
  no rewrite as long as it runs on macOS.
- **Refresh by name, not by signal.** `flash status refresh --name=updates`
  replaces `pkill -RTMIN+8 waybar`, which could not work anyway: macOS has
  no real-time signals.
- **Popups that run programs.** `#[popup=btop]` opens btop in a real
  terminal under the label, where a Waybar tooltip shows text.
- **Hints on the bar.** `f` in NORMAL labels every click range and link of
  the bar, so it never needs the pointer.
- **No scripts for CPU, memory, disk, network or battery**: one sandboxed
  plugin samples them while a surface shows them.

## Flash features you might like

- `#{?flash.caffeinate,AWAKE,}` with a click range on `caffeinate toggle`
  is Waybar's `idle_inhibitor`.
- A text popup with `text = "#{flash.calendar}"` is the clock's calendar
  tooltip, and stays readable in a pager.
- A source without a command, set by `flash status set --name=… --value=…`,
  is a module a script pushes into
  ([pushed status values](../commands.md#pushed-status-values)).
- [Desktop widgets](../widgets.md) draw the same template on the desktop.

## Moving from Waybar

| Waybar | Flash |
| --- | --- |
| `"modules-left"`, `"modules-center"`, `"modules-right"` | `#[align=left]`, `#[align=centre]`, `#[align=right]` |
| `"output": "DP-1"`, `"position": "top"` | `[statusbar] monitor = "all"` or `"primary"`; the top only |
| `"custom/updates": { "exec": …, "interval": 3600 }` | `[statusbar.sources.updates]` with `command` and `interval` |
| `"return-type": "json"` | `output = "waybar"` |
| `"signal": 8` and `pkill -RTMIN+8 waybar` | `flash status refresh --name=updates` |
| A continuous script without `interval` | A `#(script \| jq --unbuffered -r .text)` job, which shows the latest line it printed |
| `"exec-if"` | A test inside the script |
| `"on-click": "…"` | `#[range=user\|updates]…#[norange]`, and `updates = […]` in `[statusbar.click]` |
| `"format": "{} "` | Text around `#{flash.source.updates}` in the template |
| `clock` with `"tooltip-format": "<tt>{calendar}</tt>"` | `%H:%M` and a `[popup.calendar]` with `text = "#{flash.calendar}"` |
| `cpu`, `memory`, `disk`, `battery`, `network` | `#{flash.plugin.sysinfo.cpu_percent}`, `memory_percent`, `disks_percent`, `power_percent`, `network_address` |
| `sway/workspaces`, `hyprland/workspaces` | `#{flash.workspaces}` with `[tiling]` on |
| `idle_inhibitor` | `#{flash.caffeinate}` and `caffeinate toggle` |
| `style.css` `#custom-updates { color: … }` | `#[fg=…]…#[default]` around the value |
| `tray`, `temperature`, `on-scroll-up` | Not available |

```toml
[statusbar]
enabled = true
template = """
#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.workspaces}
#[align=centre]#[shrink]#{flash.focused_app_name}#[noshrink]
#[align=right]#[range=user|updates]#{flash.source.updates}#[norange]
 · #[range=user|awake]#{?flash.caffeinate,AWAKE,idle}#[norange]
 · #[popup=calendar]%a %d %b %H:%M#[nopopup]
"""

[statusbar.sources.updates]
command = ["~/.config/waybar/scripts/updates.sh"]
interval = 3600
output = "waybar"

[statusbar.click]
updates = ["flash", "status", "refresh", "--name=updates"]
awake = ["flash", "caffeinate", "toggle"]

[popup.calendar]
text = "#{flash.calendar}"
```

The template's newlines are dropped, so each line continues the bar.
`#{flash.workspaces}` stays empty until [tiling](../tiling.md) is on.

*Checked 2026-10-23 against the Waybar [README](https://github.com/Alexays/Waybar),
its releases and the
[waybar-custom(5)](https://github.com/Alexays/Waybar/blob/master/man/waybar-custom.5.scd)
man page.*
