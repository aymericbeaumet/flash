# Flash and i3blocks

[i3blocks](https://github.com/vivien/i3blocks) is "The hacker-friendly
`status_command` for Sway and i3": "a feed generator for text based status
bars" that runs your commands at intervals, on real-time signals or on
clicks, and turns their output into i3bar blocks. Each block is an ini
section (`command`, `interval`, `signal`, `instance`, `format`), and a
script may print `full_text`, `short_text` and a colour, or JSON. It is
GPL-3 C, about 2,500 stars, 1.5 in August 2019, with the last commit in
November 2023: finished rather than abandoned. It feeds i3bar and swaybar,
which do not exist on macOS. Flash's [status bar](../statusbar.md) reads
an i3blocks script unchanged with `output = "i3blocks"`, so the blocks
travel and only their scheduling moves into `flash.toml`.

| | i3blocks | Flash |
| --- | --- | --- |
| License, price | GPL-3, free | MIT, free |
| Platforms | Wherever i3bar or swaybar run: X11 and Wayland | macOS 13+ |
| A block | An ini section with `command`, `interval`, `signal` | `[statusbar.sources.<name>]` with `command`, `interval`, `output = "i3blocks"` |
| Output kept | `full_text`, `short_text`, `color`, `background`, JSON keys, `urgent` (exit 33) | The first line, `full_text`; style it in the template |
| Scheduling | Seconds, `once`, `repeat`, `persist`, `SIGRTMIN+n` | Seconds, `0` for once, `#()` jobs for long-running scripts, `flash status refresh` |
| Clicks | Button and coordinates in the script's environment | A click range bound to any command |
| Configuration | `~/.config/i3blocks/config` | TOML, live reload |
| Maintenance | 1.5, August 2019; stable | 1.1.0, October 2026 |

## Where i3blocks is stronger

- **The script sees the click.** `$button`, `$x` and `$y` arrive in its
  environment, so one script toggles on a left click and opens something on
  a right one; a `persist` block reads its clicks on stdin. Flash runs one
  command per click range and passes no button.
- **The whole i3bar block.** `short_text` when space runs out, a colour or
  urgency decided by the script, `min_width`, Pango markup, and `format=json`
  carrying state from one run to the next. Flash keeps the text, and the
  template decides the style.
- **Signals.** `pkill -RTMIN+10 i3blocks` from any key binding refreshes a
  block. macOS has no real-time signals, so nothing that relies on them can
  carry over.
- **Tiny and done.** A small C program with a stable format, as useful on a
  2019 setup as today.

## Where Flash is stronger

- **The same scripts on a Mac.** A block that prints its value on the first
  line needs no change; `env` gives it `instance` (and the legacy
  `BLOCK_INSTANCE`) as i3blocks would.
- **Refresh by name.** `flash status refresh --name=vpn` from a hotkey, a
  monitor or a script replaces the signal number, and a run already going
  is followed by one more.
- **Values you do not have to script.** CPU, memory, disks, network and
  battery come from the sysinfo plugin, beside your blocks.
- **Numbers become history and alerts.** `history = 30` keeps a block's
  numeric output for a sparkline, and a [monitor](../monitors.md) alerts
  when it crosses a threshold, which is what exit code 33 told i3bar.

## Flash features you might like

- `#[popup=<name>]` under a block opens a pager or a TUI on hover, for the
  details that never fitted in `full_text`.
- `#{p8:flash.source.vpn}` pads a value to eight cells, `#[shrink]` cuts it
  first when the bar is full: `min_width` and `short_text`, in the template.
- Sources run only while the bar or a widget shows them, and keep their last
  good value when a run fails.
- The same source can sit on the bar and in a [desktop widget](../widgets.md).

## Moving from i3blocks

| i3blocks | Flash |
| --- | --- |
| `[weather]` | `[statusbar.sources.weather]` |
| `command=~/bin/weather` | `command = ["~/bin/weather"]` and `output = "i3blocks"`; shell syntax needs `["/bin/sh", "-c", "…"]` |
| `interval=3600` | `interval = 3600` |
| `interval=once` | `interval = 0` |
| `interval=repeat`, `interval=persist` | A `#(~/bin/script)` job in the template |
| `signal=10`, `pkill -RTMIN+10 i3blocks` | `flash status refresh --name=weather` |
| `instance=BAT0` | `env = { instance = "BAT0", BLOCK_INSTANCE = "BAT0" }` |
| `color=#F79494`, or a colour on the third line | `#[fg=#F79494]#{flash.source.weather}#[default]` |
| `short_text`, `min_width` | `#[shrink]…#[noshrink]`, `#{p8:…}` |
| `$button` | `#[range=user\|weather]…#[norange]` and `weather = […]` in `[statusbar.click]` |
| Exit code 33 | A monitor with `value = "#{flash.source.battery}"` and a threshold |
| `format=json`, `markup=pango` | Not read: print `full_text` first |
| `bar { status_command i3blocks }` | `[statusbar] enabled = true` |

Scripts that read Linux interfaces need a macOS rewrite of those lines,
not of their output: `acpi -b` becomes `pmset -g batt`, `/sys/class/net`
becomes `ifconfig` or `networksetup`. The battery and network blocks are
usually better replaced by the plugin values.

```toml
[statusbar]
enabled = true
template = "#[align=right]#{flash.source.vpn} · #[range=user|weather]#{flash.source.weather}#[norange] · %a %H:%M"

[statusbar.sources.weather]
command = ["/bin/sh", "-c", "curl -Ss 'https://wttr.in?0&T&Q' | cut -c 16- | head -2 | xargs echo"]
interval = 3600
output = "i3blocks"

[statusbar.sources.vpn]
command = ["~/.config/i3blocks/vpn"]
interval = 0
output = "i3blocks"
env = { instance = "utun4", BLOCK_INSTANCE = "utun4" }

[statusbar.click]
weather = "https://wttr.in"
```

`interval = 0` runs the VPN block once; a VPN script's up and down hooks
can call `flash status refresh --name=vpn`, as they would have sent the
signal.

*Checked 2026-10-23 against the i3blocks [README](https://github.com/vivien/i3blocks),
its source (`block.c`, for the environment it exports) and the
[i3bar protocol](https://i3wm.org/docs/i3bar-protocol.html).*
