# Flash and ydotool

[ydotool](https://github.com/ReimuNotMoe/ydotool) is a "Generic Linux
command-line automation tool (no X!)": it writes keyboard and mouse events
to a virtual `uinput` device through its `ydotoold` daemon, so it works on
Wayland, on X11, on a text console and in framebuffer apps alike. Since its
1.0 rewrite in C99 it has `key` (by keycode), `type`, `click`, `mousemove`
and `stdin`, and leaves chaining and sleeps to the shell. It is AGPL-3.0,
about 2,400 stars, v1.0.4 in January 2023, with commits until December
2025. It is Linux-only: macOS has no `uinput`. Flash covers the part of a
ydotool script that acts on the desktop, by command rather than by keycode.

| | ydotool | Flash |
| --- | --- | --- |
| License, price | AGPL-3.0, free | MIT, free |
| Platforms | Linux, anything that reads evdev input | macOS 13+ |
| How events are made | A virtual input device, below the display server | Events posted by the resident under its Accessibility grant |
| Keys | `key 29:1 46:1 46:0 29:0` (raw keycodes, press and release), `type` text | `key send --keys=cmd+c`, `key sequence`, `key arrow`; commands such as `clipboard copy` |
| Pointer | `click` with a button bitmask, `mousemove` relative or `--absolute` | `mouse button`, `nudge`, `warp`, `target`, `grid`, `pointer`; no absolute coordinates |
| Setup | `ydotoold` running, with access to `/dev/uinput` | The Accessibility grant |
| Maintenance | v1.0.4, January 2023; commits until December 2025 | 1.1.0, October 2026 |

## Where ydotool is stronger

- **Everywhere on Linux.** One virtual device works under every Wayland
  compositor, X11 and the console, with no protocol the compositor must
  offer. That is what makes it the Wayland answer to xdotool.
- **It types text** (`ydotool type`), which no Flash command does from its
  command line.
- **Keycodes are layout-proof.** `key 56:1` is the physical key whatever
  layout is active; Flash's `key send` names the key it means instead.
- **Absolute moves.** `mousemove --absolute -x 100 -y 100` puts the pointer
  on a coordinate; Flash only moves to targets, cells, edges and saved
  positions.
- **Below the window server.** macOS has nothing like `uinput` for a CLI.
  The only way under WindowServer is a DriverKit virtual HID device, which
  Karabiner-Elements installs and [kanata](kanata.md) reuses.

## Where Flash is stronger

- **Commands, not keycodes.** `29:1 46:1 46:0 29:0` is Control-C on Linux;
  on a Mac the same intent is `flash clipboard copy`, which asks the focused
  app for its copy, terminals included, with no chord to remember.
- **No daemon or device permissions.** ydotool needs `ydotoold` and write
  access to `/dev/uinput`; Flash's resident is already running and holds the
  one grant input synthesis needs.
- **Targets by label.** A script can open `flash mouse target` and let you
  pick, or `flash mouse grid`, instead of computing where a button is.
- **Desktop verbs beside the keys**: `window move`, `app open`, `tab next`,
  `screen lock`, `volume up`, all from the same CLI.

## Flash features you might like

- `flash mouse button --state=down` and `--state=up` press and release at
  the pointer, as `ydotool click 0x40` and `0x80` do; `mouse repeat` clicks
  where Flash last clicked.
- `flash mouse nudge --direction=left --distance=100` is one axis of a
  relative `mousemove`.
- `printf '%s' "$text" | pbcopy && flash clipboard paste` stands in for
  `ydotool type`, through the app's own paste.
- `flash normal <keys>` presses a NORMAL mapping by its keys from a script
  ([`:normal`](../commands.md#normal-and)).

## Moving from ydotool

| ydotool | Flash |
| --- | --- |
| `key 29:1 46:1 46:0 29:0` (Control-C) | `flash clipboard copy`, or `flash key send --keys=cmd+c` |
| `key 56:1 62:1 62:0 56:0` (Alt-F4) | `flash window close`, or `flash app quit` |
| `key 28:1 28:0` (Return) | `flash key send --keys=<return>` |
| `type 'echo hello'` | `pbcopy` then `flash clipboard paste`; saved text through `@snippets` |
| `click 0xC0` (left click) | `flash mouse button --state=down`, then `--state=up` |
| `click 0xC1` (right click) | `flash mouse target --secondary` on a label |
| `mousemove -x -100 -y 100` | `flash mouse nudge --direction=left --distance=100`, then `--direction=down` |
| `mousemove --absolute -x 100 -y 100` | No coordinates: `flash mouse warp --area=screen --edge=top` (a side or the centre), or a saved `mouse position` |
| `stdin` | No equivalent |

Compositor binds that ran ydotool, as Flash chords:

```toml
[mode.all.mappings]
"ctrl+alt+c" = ["flash", "clipboard", "copy"]
"ctrl+alt+v" = ["flash", "clipboard", "paste"]
"ctrl+alt+q" = ["flash", "window", "close"]
"ctrl+alt+j" = ["flash", "key", "arrow", "--direction=down"]
"ctrl+alt+p" = ["flash", "mouse", "pointer"]
```

*Checked 2026-10-23 against the ydotool
[README](https://github.com/ReimuNotMoe/ydotool) and its releases.*
