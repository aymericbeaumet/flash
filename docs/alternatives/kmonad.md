# Flash and KMonad

[KMonad](https://github.com/kmonad/kmonad) is "The Onion of Keyboard
Management Tools, available on GNU/Linux, Windows, and MacOS!": QMK-style
features on any keyboard, from `defsrc`, `deflayer` and `defalias` blocks
in a Lisp-like `.kbd` file. Layers, `tap-hold` and its `tap-next` and
`tap-hold-next-release` cousins, `multi-tap`, `sticky-key`, `tap-macro`,
compose sequences and `cmd-button`s are its vocabulary. It is MIT Haskell,
about 5,100 stars, 0.4.5 in May 2026, with a contributed library of
keyboard configurations. It runs on a Mac, with effort; kanata, which it
inspired, is the smoother path there ([kanata](kanata.md)). Either way,
Flash sits above it: KMonad decides what a key sends, Flash what it does.

| | KMonad | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux, Windows, macOS | macOS 13+ |
| Works at | Below the apps: grabs the keyboard, emits through uinput, a Windows hook or Karabiner's virtual HID device | Above them: routes or swallows key presses from one session tap |
| Multi-use keys | `tap-hold`, `tap-next`, `tap-hold-next-release`, `multi-tap`, `sticky-key` | None; the leader alone taps for sequences and holds for HYPER |
| Layers | `layer-toggle`, `layer-switch`, `layer-delay`, `layer-next` | Layers of commands, sticky or one-shot, and HYPER |
| macOS setup | Build with `stack`, install the DriverKit extension, start its daemon with `sudo`, run as root, grant Input Monitoring | Install the cask, grant Accessibility |
| Configuration | `.kbd` file, `fallthrough`, `allow-cmd` | `flash.toml`, live reload, `flash config check` |
| Maintenance | 0.4.5, May 2026 | 1.1.0, October 2026 |

## Where KMonad is stronger

- **Keyboard firmware without new firmware.** A Space Cadet Shift, Caps
  Lock as Escape and Control, a numbers layer on a thumb key, a
  double-tap that jumps to a layer: KMonad rewrites the key itself. Flash
  sees presses only, never modifier changes, and rewrites nothing.
- **`around` and `tap-macro`** compose keys into new ones, and compose-key
  sequences type characters your layout lacks.
- **Every operating system you use**, from one file, with a body of shared
  layouts in kmonad-contrib.

On macOS its own guide is frank about the cost. Since Leopard,
intercepting key events needs root, so `kmonad` runs under `sudo`; since
Catalina the app that starts it needs Input Monitoring. It emits keys
through Karabiner's DriverKit VirtualHIDDevice, documented for macOS 13 to
15 with driver 5.0.0, whose daemon you start yourself, and it is compiled
from source with `stack`.

## Where Flash is stronger

- **Actions, not keycodes.** A `cmd-button` runs a shell command; a Flash
  mapping runs a command that resolves in the focused app (`x` closes a
  browser tab or, after asking, a tmux window) or any program you name,
  in your session rather than as root.
- **Context.** Bindings per app by bundle ID, hints on what is on screen,
  window placement and the bar, all reachable from the keys KMonad hands up.
- **No privileged process.** Flash asks for Accessibility only and never
  for Input Monitoring ([privacy](../privacy.md#keyboard)).
- **Discoverable.** Pause on `<leader>` and a palette lists what follows;
  `?` draws every mode on your keyboard.

## Flash features you might like

- [HYPER](../hyper-mode.md) is a `layer-toggle` for commands: hold the
  NORMAL leader, and its table, the Apple function row by default, acts
  until you let go.
- `sticky = false` on a [layer](../layers.md) is `layer-next` for Flash
  commands: one key, then back.
- Counts: `3]t` moves three tabs, as a `tap-macro` would spell out.
- `defaults write` lines in `[startup] run` set key repeat from the same
  file ([startup commands](../startup.md)).

## Moving from KMonad

| KMonad | Flash |
| --- | --- |
| `defsrc` / `deflayer` remaps, `tap-hold`, `multi-tap`, `sticky-key` | Keep KMonad, or move them to [kanata](kanata.md) or [Karabiner-Elements](karabiner-elements.md) |
| `(iokit-name …)` input, `(kext)` or dext output | Nothing to configure: Flash reads what macOS delivers |
| `layer-toggle nav` with `hjkl` arrows | HYPER mappings while the leader is held, in NORMAL |
| `layer-switch` to a command layer | `mode layer --name=<layer>` |
| `layer-next` | A layer with `sticky = false` |
| `cmd-button "…"` with `allow-cmd true` | A mapping: `["flash", "<topic>", "<action>"]` or any argv |
| `fallthrough true` | Built in: Flash only acts on keys it maps (in NORMAL, it swallows the rest) |
| Compose sequences | macOS's own: hold a letter for its accents, or Option dead keys |

KMonad's command buttons as NORMAL sequences, typed after the leader (`\`):

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>m" = ["flash", "volume", "mute"]
"<leader>b" = ["flash", "app", "open", "--name=Safari"]
"<leader>t" = ["flash", "app", "open", "--name=Terminal"]
"<leader>l" = ["flash", "screen", "lock"]
```

The two chords turn on Flash's modes: it starts in NORMAL, where keys you
have not mapped do nothing, and `i` or a click types again
([advanced mode](../modes.md#advanced-mode)).

*Checked 2026-10-23 against the KMonad
[README](https://github.com/kmonad/kmonad),
[installation guide](https://github.com/kmonad/kmonad/blob/master/doc/installation.md)
and [configuration tutorial](https://github.com/kmonad/kmonad/blob/master/keymap/tutorial.kbd).*
