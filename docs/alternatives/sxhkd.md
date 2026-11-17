# Flash and sxhkd

[sxhkd](https://github.com/baskerville/sxhkd) "is a simple X hotkey daemon
with a powerful and compact configuration syntax": it grabs keys and mouse
buttons from the X server and runs each binding's command "via SHELL -c
COMMAND", with chord chains, brace expansion, and prefixes that fire on
release or replay the key to the app. It is BSD-2-Clause C for X11 on Linux
and the BSDs, about 2,900 stars, 0.6.3 in September 2025, and the usual
keyboard half of a [bspwm](bspwm.md) setup. It does not run on macOS, where
skhd is the closest daemon ([skhd](skhd.md)). Flash
binds chords too, and its NORMAL sequences and [layers](../layers.md) are
where sxhkd's chains go.

| | sxhkd | Flash |
| --- | --- | --- |
| License, price | BSD-2-Clause, free | MIT, free |
| Platforms | X11 on Linux and the BSDs | macOS 13+ |
| Binds | Keys and pointer buttons (`button1` to `button24`) to shell commands | Keys to Flash commands or any argv; no mouse buttons |
| Chains | `;` chord chains, `:` chains that stay until aborted | NORMAL sequences; layers, one-shot or sticky |
| Expansion | `{a,b}`, ranges such as `{1-9}`, `_` for an empty element | None: one line per key |
| Release, replay | `@` runs on release, `~` replays the event to the app | Key down only; a mapped chord never reaches the app |
| Scope | Global | Global, per mode, and per app by bundle ID |
| Configuration | `sxhkdrc`; `SIGUSR1` reloads it | TOML, live reload on save, `flash config check` |
| Maintenance | 0.6.3, September 2025 | 1.1.0, October 2026 |

## Where sxhkd is stronger

- **The most compact syntax of any hotkey tool.** `super + {_,shift + }{1-9,0}`
  with `bspc {desktop -f,node -d} '^{1-9,10}'` binds twenty keys in two
  lines. TOML has no expansion, so a Flash file writes each key out.
- **Release and replay.** `@` runs a command when the key comes up, and `~`
  lets the focused app see the key as well. Flash acts on key down and
  swallows what it maps.
- **Pointer buttons are hotkeys**, with modifiers, for move and resize
  drags in a window manager. Flash binds keys only.
- **Small and independent.** It runs beside any X window manager, and its
  status FIFO (`-s`) lets a bar show a chain in progress.

## Where Flash is stronger

- **Plain keys, not only chords.** In NORMAL a binding can be `gt` or
  `<leader>of` with no modifier held, and a chord can start a sequence
  (`ctrl+w h`). Pause on a prefix and, after `[mode] which_key_ms`, a
  palette lists what can follow it, which no chord chain shows.
- **Bindings per app.** `[mode.apps."<bundle id>".all.mappings]` changes a
  chord in one app only; with sxhkd, a command has to ask `xdotool` which
  window is focused.
- **No shell per keypress.** An argv starting with `flash` runs in the
  resident's process, and any other is launched as argv, without a shell
  unless you write one.
- **A live reference.** `?` in NORMAL, or the [key mappings](/mappings)
  page, draws your keyboard with what each key does in each mode.

## Flash features you might like

- A layer with `sticky = false` is a `;` chain, and the default sticky
  layer is a `:` chain; Escape leaves either, as `-a Escape` aborts one.
- The pill shows a layer's `label` through `#{flash.mode}`, what the status
  FIFO fed a bar.
- `[mode] sequence_timeout_ms` is `-t` for NORMAL sequences; a layer waits
  until you leave it.
- Every binding is also a CLI call, so a script can run `flash normal <keys>`
  to press a NORMAL mapping by its keys.

## Moving from sxhkd

| sxhkd | Flash |
| --- | --- |
| `super + Return` / `urxvt` | `"alt+<return>" = ["flash", "app", "open", "--name=Terminal"]`, or any argv |
| `super + @space` / `dmenu_run` | `"alt+<space>" = ["flash", "mode", "flashlight"]` |
| `super + o ; f` | A one-shot layer on `alt+o` with an `f` mapping; in NORMAL, `"<leader>of"` too |
| `super + o : {h,l}` | A sticky layer; Escape leaves it |
| `super + {_,shift + }{1-9}` | One line per key |
| `@super + x` | None: nothing runs on release |
| `~button1`, `super + button1` | None: Flash binds no pointer buttons |
| `-t 2` | `[mode] sequence_timeout_ms = 2000` |
| `-s` status FIFO | `#{flash.mode}` in the [bar](../statusbar.md) |
| `pkill -USR1 -x sxhkd` | Saving the file, or `flash config reload` |
| `SXHKD_SHELL` | An explicit `["/bin/sh", "-c", "…"]` argv where a command needs a shell |

Super is Command on a Mac and most Command chords belong to apps, so these
use Option. A layer needs Flash's modes, which the first two chords turn on;
Flash then starts in NORMAL, where unmapped letters are swallowed until `i`
or a click ([advanced mode](../modes.md#advanced-mode)):

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+<return>" = ["flash", "app", "open", "--name=Terminal"]
"alt+<space>" = ["flash", "mode", "flashlight"]
"alt+o" = ["flash", "mode", "layer", "--name=open"]   # super + o ; …
"alt+<escape>" = ["flash", "config", "reload"]

[mode.layers.open]
label = "OPEN"
sticky = false

[mode.layers.open.mappings]
"f" = ["flash", "app", "open", "--name=Firefox"]
"m" = ["flash", "app", "open", "--name=Mail"]
"t" = ["flash", "mode", "terminal"]

[mode.normal.mappings]
"<leader>of" = ["flash", "app", "open", "--name=Firefox"]
"<leader>om" = ["flash", "app", "open", "--name=Mail"]

[mode.apps."org.mozilla.firefox".all.mappings]
"alt+r" = ["flash", "app", "reload"]
```

*Checked 2026-10-23 against the sxhkd [README](https://github.com/baskerville/sxhkd),
[sxhkd(1)](https://github.com/baskerville/sxhkd/blob/master/doc/sxhkd.1.asciidoc)
and bspwm's example [sxhkdrc](https://github.com/baskerville/bspwm/blob/master/examples/sxhkdrc).*
