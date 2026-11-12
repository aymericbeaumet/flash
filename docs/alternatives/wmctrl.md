# Flash and wmctrl

[wmctrl](https://github.com/Conservatory/wmctrl), by Tomas Styblo, is "a
command that can be used to interact with an X Window manager that is
compatible with the EWMH/NetWM specification": `-l` lists windows with
their desktop, PID and geometry, `-a` activates one by title, `-r … -e`
moves and resizes it, `-b` toggles states such as fullscreen, sticky or
above, `-s` switches desktops. It is GPL-2.0-or-later C. The last release,
1.07, dates from January 2005 and its original homepages are gone; the
Conservatory fork gathered the patches people had carried (iconify,
stacking order, the current desktop) with a last commit in 2018, and
Debian ships a 2024 git snapshot. Homebrew builds it for macOS against
libX11, where it reaches only X11 windows. Flash's `window` and
`workspace` commands are the Mac equivalents for the focused window.

| | wmctrl | Flash |
| --- | --- | --- |
| License, price | GPL-2.0-or-later, free | MIT, free |
| Platforms | Any EWMH window manager on X11 | macOS 13+ |
| Which window | Any: by title substring, class (`-x`), id (`-i`), `:ACTIVE:` or `:SELECT:` | The focused window; others through the switcher, `@windows` or `app open` |
| Queries | `-l` windows, `-d` desktops, `-m` window manager | `workspace list` with `[tiling]`, `resident status --json`; no window list for scripts |
| Placement | `-e gravity,x,y,w,h` in pixels; `-b` states (maximized, fullscreen, sticky, above, shaded) | Named positions, percentages of the usable frame, `--screen=+1`, full screen; rules when windows appear |
| Maintenance | 1.07, 2005; patches in forks and distributions | 1.1.0, October 2026 |

## Where wmctrl is stronger

- **Every window is addressable.** `wmctrl -r Firefox -e …` moves a window
  you are not looking at, and `-l -p -G` prints them all with PIDs and
  geometry for a script to parse. Flash acts on the focused window, and a
  JSON window list is still [planned](../tiling.md#not-yet).
- **States macOS keeps to itself.** Sticky (on every desktop), above
  (always on top), shaded, skip-taskbar: EWMH lets a client ask for them.
  On macOS a window's level and its Spaces belong to WindowServer; only
  yabai's scripting addition, with SIP partly off, reaches them.
- **Window-manager agnostic.** One tool works with any EWMH window manager,
  and it never needs a daemon.
- **It sets things**: titles (`-N`), the number of desktops (`-n`), the
  desktop geometry.

## Where Flash is stronger

- **Placement that lasts.** `window move --position=lefthalf` is remembered
  and reapplied when a display is unplugged, rearranged or comes back
  ([display changes](../windows.md#display-changes)); `wmctrl -e` writes
  pixels once.
- **Rules without a script.** `[[window_rules]]` place a window the first
  time it appears, matched by bundle ID and title
  ([placement rules](../windows.md#place-windows-as-they-appear)); wmctrl
  acts only when a script calls it.
- **Finding a window by eye.** `window switch` (`:ls`) lists every window,
  minimized and on other Spaces included, with one label per row.
- **Directional focus** (`window focus --direction=left`), `window last`
  and, with `[tiling]` on, workspaces.

## Flash features you might like

- `window move --x=10% --y=10% --width=80% --height=80%` sizes against the
  usable frame, Dock and status bar excluded, on whichever display the
  window is on.
- `desktop toggle` is `wmctrl -k toggle`; `appwindows show` is App Exposé
  for the focused app.
- `#{flash.workspace}` in the [bar](../statusbar.md), with
  [tiling](../tiling.md) on, replaces a script that reads `wmctrl -d`.

## Moving from wmctrl

| wmctrl | Flash |
| --- | --- |
| `wmctrl -a firefox` | `flash app open --name=Firefox`; a window by title: `window switch` or `@windows` |
| `wmctrl -c :ACTIVE:` | `flash window close` |
| `wmctrl -r :ACTIVE: -Y` | `flash window minimize`; `window restore` brings it back |
| `wmctrl -r :ACTIVE: -e 0,0,0,960,1080` | `flash window move --position=lefthalf` |
| `-b toggle,maximized_vert,maximized_horz` | `flash window move --position=maximized` |
| `-b toggle,fullscreen` | `flash window fullscreen` |
| `-b add,above`, `-b add,sticky` | Not available on macOS without SIP changes |
| `wmctrl -d`, `wmctrl -s 1` | `flash workspace list`, `flash workspace switch --name=2` with `[tiling]` on |
| `wmctrl -r :ACTIVE: -t 2` | `flash workspace move_window --name=3` |
| `wmctrl -k toggle` | `flash desktop toggle` |
| `wmctrl -m` | `flash resident status` |
| `wmctrl -l -x` to find a class | `flash resident status --json`: `focused_app` is the bundle ID rules match |
| A script placing windows at login | `[[window_rules]]` |

```toml
[[window_rules]]
bundle_id = "org.mozilla.firefox"
position = "righthalf"

[[window_rules]]
bundle_id = "com.apple.Terminal"
x = 10
y = 10
width = 80
height = 80

[mode.all.mappings]
"ctrl+alt+h" = ["flash", "window", "move", "--position=lefthalf"]
"ctrl+alt+l" = ["flash", "window", "move", "--position=righthalf"]
"ctrl+alt+m" = ["flash", "window", "move", "--position=maximized"]
"ctrl+alt+n" = ["flash", "window", "move", "--screen=+1"]
"ctrl+alt+d" = ["flash", "desktop", "toggle"]
"ctrl+alt+w" = ["flash", "window", "switch"]
```

*Checked 2026-10-23 against the
[wmctrl(1) man page](https://manpages.debian.org/testing/wmctrl/wmctrl.1.en.html)
in Debian, the [Conservatory fork](https://github.com/Conservatory/wmctrl)
and [Repology](https://repology.org/project/wmctrl/information).*
