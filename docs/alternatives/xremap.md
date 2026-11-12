# Flash and xremap

[xremap](https://github.com/xremap/xremap) "is a key remapper for Linux.
Unlike `xmodmap`, it supports app-specific remapping and Wayland." It reads
evdev and writes uinput, so the same YAML works on X11 and Wayland: a
`modmap` for key-to-key changes and dual-role keys, a `keymap` for combos
and sequences (`C-x C-c`), with `application`, `window`, `device` and
`mode` filters, virtual modifiers, `launch` for commands, and an Emacs
example with mark mode. It is MIT Rust, about 2,200 stars, v0.15.15 in
October 2026 with releases every few weeks. It runs on Linux, with notes for
FreeBSD, and not on macOS. Its two halves land in different places there:
rewriting keys goes to [Karabiner-Elements](karabiner-elements.md) or
[kanata](kanata.md), and app-specific shortcuts to Flash's per-app tables.

| | xremap | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux (X11, Wayland compositors), FreeBSD notes | macOS 13+ |
| Remaps keys | `modmap`, `keymap`, `exact_match`, multi-purpose keys | No; it binds keys to commands |
| Per app | `application: { only: … }` by app class, `window` by title regex | `[mode.apps."<bundle id>"]` by bundle ID |
| Modes | `set_mode`, `mode:` filters | NORMAL, INSERT, layers |
| Sequences | Nested `remap` with `timeout_millis` | NORMAL sequences with `sequence_timeout_ms` and a which-key palette |
| Configuration | YAML or JSON, generated from Ruby or Python if you like; `--watch` for new devices | `flash.toml`, live reload, `flash config check` |
| Maintenance | v0.15.15, October 2026; frequent releases | 1.1.0, October 2026 |

## Where xremap is stronger

- **It rewrites what every app receives.** `CapsLock: Esc`, a held key as
  all four modifiers, `Ctrl-P: Up` in one browser: xremap changes the key
  itself, before the app. Flash's tap sees key presses, not modifier
  changes, and never rewrites a hardware key.
- **Filters Flash does not have**: window titles by regex, specific
  devices, left and right modifiers apart (`Ctrl_R-C`), and modes that
  switch whole keymaps.
- **Configuration as data.** JSON-compatible YAML that a Ruby or Python
  DSL can generate, and a single static binary.
- **Wayland and X alike**, which on Linux is the hard part; macOS has one
  input path, so the equivalent problem does not arise.

## Where Flash is stronger

- **Commands, not keystrokes.** An xremap rule maps a combo to another
  combo the app happens to understand. A Flash mapping names what you want
  (`tab next`, `app find`, `window move --position=lefthalf`), and each app
  performs it its own way.
- **Bundle IDs are stable.** No `--list-windows` hunt, and nothing that
  stops working on one desktop: `osascript -e 'id of app "Slack"'` prints
  the identifier a table matches.
- **Emacs keys are already there.** macOS text fields take Control-A, E,
  F, B, N, P, K and more by themselves, the bindings xremap's Emacs example
  adds on Linux.
- **The rest of the desktop**: hints, windows, the flashlight, the bar,
  from the same file.

## Flash features you might like

- A Flash [layer](../layers.md) is an xremap mode for commands: `mode layer
  --name=<name>` enters it, Escape leaves, and the pill names it.
- `"<key>" = false` in a per-app table removes a binding in that app only,
  as `application: { not: … }` excludes one.
- `[mode] sequence_timeout_ms` and `which_key_ms` for `C-x`-style
  prefixes in NORMAL.
- `flash resident status --json` reports `focused_app`, the bundle ID per-app
  tables match.

## Moving from xremap

| xremap | Flash |
| --- | --- |
| `modmap: CapsLock: Esc` | System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys |
| Multi-purpose keys (`alone` / `held`) | Karabiner-Elements or kanata |
| `keymap` combo to combo, all apps | Usually nothing: use the command (`["flash", "tab", "next"]`) |
| `application: { only: Slack }` | `[mode.apps."com.tinyspeck.slackmacgap".all.mappings]` |
| `launch: ["bash", "-c", "…"]` | A mapping whose argv is the program, `["/bin/sh", "-c", "…"]` for shell syntax |
| `set_mode` and `mode:` | A layer with its own table |
| `C-x C-c` sequences | `"ctrl+x ctrl+c"` in `[mode.normal.mappings]` |
| `--watch` for new keyboards | Nothing to do: Flash reads every keyboard |
| `{ action: reload }` | Saving the file reloads it |

A per-app combo, and a launcher:

```toml
[mode.apps."com.tinyspeck.slackmacgap".all.mappings]
"ctrl+j" = ["flash", "key", "arrow", "--direction=down"]
"ctrl+k" = ["flash", "key", "arrow", "--direction=up"]

[mode.all.mappings]
"cmd+ctrl+t" = ["flash", "app", "open", "--name=Terminal"]
```

Pressing an arrow is a synthesized key, Flash's escape hatch for the cases
no command covers; Flash's own defaults bind commands, never chords. These
chords act without NORMAL; sequences need it
([advanced mode](../modes.md#advanced-mode)).

*Checked 2026-10-23 against the xremap
[README](https://github.com/xremap/xremap), its releases, and Apple's
[Mac keyboard shortcuts](https://support.apple.com/en-us/102650).*
