# Flash and keyd

[keyd](https://github.com/rvaiya/keyd) is "a key remapping daemon for
linux" that remaps "using kernel level input primitives (evdev, uinput)",
so one `/etc/keyd/default.conf` works in X, Wayland and the virtual
console alike. Its ini-style files hold `[ids]` for the keyboards they
apply to, a `[main]` layer and layers of your own, with `overload()`,
`oneshot()`, `layer()`, `toggle()`, `swap()`, chords such as `j+k = esc`,
macros and `command()`. It is MIT C, about 6,100 stars, v2.6.0 in December
2025, by the author of [warpd](warpd.md). It is Linux only and has no macOS
port. On a Mac its job splits in two: what a key sends goes to
[Karabiner-Elements](karabiner-elements.md) or [kanata](kanata.md), and
what a key does goes to Flash.

| | keyd | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux | macOS 13+ |
| Works at | The kernel input layer: evdev in, uinput out, before any display server | One session tap in your login session |
| Dual-role keys | `overload()`, `overloadt()`, `overloadi()`, `lettermod()`, `timeout()` | None; the leader alone taps for sequences and holds for HYPER |
| Layers | Stacked layers, modifier layers (`[capslock:C]`), `oneshot`, `toggle`, `swap` | Command layers, sticky or one-shot, and HYPER in NORMAL |
| Per keyboard, per app | `[ids]` per device; `keyd-application-mapper` for X, sway and GNOME | Every keyboard alike; `[mode.apps."<bundle id>"]` per app |
| Configuration | ini files, `keyd reload`, `keyd check` | `flash.toml`, live reload, `flash config check` |
| Maintenance | v2.6.0, December 2025 | 1.1.0, October 2026 |

## Where keyd is stronger

- **It rewrites keys.** `capslock = overload(control, esc)` is the reason
  most people install it, and `lettermod()` makes home-row modifiers
  usable. Flash's tap sees key presses, not modifier changes, and never
  rewrites a hardware key; on macOS that needs a virtual HID driver such as
  Karabiner's.
- **Below the display server.** keyd's layers work in a virtual console
  too, so a broken desktop never strands your layout. Flash runs inside
  your session, and macOS's secure input hides password fields from every
  event tap, its own included.
- **Modifier layers.** `[capslock:C]` makes Caps Lock a Control that
  types arrows on `hjkl`, stacking with the other modifiers; no macOS
  setting does that.
- **Per-device files**, a `keyd monitor` to read key names, `keyd listen`
  for layer changes and `keyd input` to type text from a script.

## Where Flash is stronger

- **Commands that know the app.** keyd's application mapper rewrites
  `alt.]` to `C-tab` for one window class; a Flash mapping runs `tab next`,
  which a browser, Finder or tmux each perform their own way.
- **Bundle IDs, not window classes.** Per-app tables follow the focused
  app's identifier, the same on every Mac, with no mapper process watching
  the window manager.
- **What keyd never covered**: hints on every control, window placement,
  the flashlight, a bar and popups, from the same keys.
- **No root daemon.** Flash runs as you with the Accessibility grant; keyd
  runs as root, so its `command()` actions do too, as its man page warns.

## Flash features you might like

- [HYPER](../hyper-mode.md) is keyd's nav layer without a driver, in
  NORMAL: hold the leader (`\`) and the arrows sit on E, S, D and F, or on
  `hjkl` with the mappings below.
- `[keyboard] layout = "colemak"` (or `dvorak`, `bepo`) for keyd users who
  include a shipped layout: Flash's hint letters and grid follow it, while
  macOS's input source does the typing.
- `which_key_ms`: pause on a prefix and the keys that can follow it appear.
- `[startup] run` sets key repeat (`defaults write NSGlobalDomain KeyRepeat`
  and `InitialKeyRepeat`) from the file ([startup commands](../startup.md)).

## Moving from keyd

| keyd | On a Mac |
| --- | --- |
| `capslock = esc` | System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys, no tool needed |
| `capslock = overload(control, esc)`, `lettermod()` | Karabiner-Elements or kanata |
| `[ids]` per keyboard | Karabiner-Elements or kanata device rules |
| `layer(nav)` with `h = left` … | Flash HYPER, held from NORMAL; in INSERT the leader types itself |
| `oneshot(<layer>)` of commands | A Flash layer with `sticky = false` |
| `toggle(<layer>)` | A sticky Flash layer, left with Escape |
| `j+k = esc` chords | No chords in Flash; kanata has them |
| `command(…)` | A Flash mapping's argv, run as you |
| `keyd-application-mapper` `[chromium]` sections | `[mode.apps."com.google.Chrome".all.mappings]` |
| `keyd reload`, `keyd check` | Saving the file reloads it; `flash config check` |

keyd's nav layer and an application-mapper section, in Flash:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.hyper.mappings]
"h" = ["flash", "key", "arrow", "--direction=left"]
"j" = ["flash", "key", "arrow", "--direction=down"]
"k" = ["flash", "key", "arrow", "--direction=up"]
"l" = ["flash", "key", "arrow", "--direction=right"]

[mode.apps."com.google.Chrome".all.mappings]
"alt+<rbracket>" = ["flash", "tab", "next"]
"alt+<lbracket>" = ["flash", "tab", "previous"]
```

HYPER belongs to NORMAL, which the first two chords turn on: Flash then
starts in NORMAL, swallowing keys it does not map until `i` or a click
([advanced mode](../modes.md#advanced-mode)). An arrow from `key arrow` is
a synthesized key, Flash's escape hatch; its own defaults bind commands.

*Checked 2026-10-23 against the keyd [README](https://github.com/rvaiya/keyd),
[keyd(1)](https://github.com/rvaiya/keyd/blob/master/docs/keyd.scdoc) and
[keyd-application-mapper(1)](https://github.com/rvaiya/keyd/blob/master/docs/keyd-application-mapper.scdoc).*
