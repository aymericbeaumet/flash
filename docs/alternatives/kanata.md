# Flash and kanata

[kanata](https://github.com/jtroo/kanata) is "a cross-platform software
keyboard remapper for Linux, macOS and Windows": `defsrc` and `deflayer`
tables, `tap-hold` and its variants, `layer-while-held` and `layer-switch`,
one-shot keys, chords, sequences, tap-dance, caps-word, macros and a TCP
server for scripts. It is LGPL-3.0 Rust, inspired by KMonad, about 8,000
stars, v1.12.0 in July 2026 (a 1.13.0 prerelease in October), and in
Homebrew. Of the Linux remappers it is the one that comes with you: on a
Mac it runs on Karabiner's DriverKit virtual keyboard, and Flash binds what
it sends. The two do different jobs, so keep kanata.

| | kanata | Flash |
| --- | --- | --- |
| License, price | LGPL-3.0, free | MIT, free |
| Platforms | Linux, Windows, macOS | macOS 13+ |
| Works at | Below the apps: it grabs the keyboard and types through a virtual device | Above them: one session tap that routes or swallows key presses |
| Tap and hold | `tap-hold`, `tap-hold-press`, `tap-hold-release`, home-row mods, tap-dance | No; the NORMAL leader alone is tap for sequences, hold for HYPER |
| Layers | `layer-while-held`, `layer-switch`, one-shot, per-key transparency | Layers of commands, sticky or one-shot; HYPER while the leader is held |
| Per-app behaviour | Through the TCP server and companions such as kanata-vk-agent | `[mode.apps."<bundle id>"]` tables |
| macOS requirements | Karabiner driver v6.2.0, run with `sudo` in a terminal | Accessibility |
| Configuration | `.kbd` S-expressions, live reload, `--check`, an online simulator | `flash.toml`, live reload, `flash config check` |
| Maintenance | v1.12.0, July 2026; active | 1.1.0, October 2026 |

## Where kanata is stronger

- **It changes what a key is.** Caps Lock as Escape on tap and Control on
  hold, home-row modifiers, a symbols layer on a thumb key, chords of two
  letters: kanata rewrites the key before any app sees it. Flash's tap sees
  key presses, not modifier changes, and never rewrites a hardware key.
- **One configuration on every computer.** The same `.kbd` file drives
  Linux, Windows and the Mac; Flash's file is macOS only.
- **Firmware-grade timing**: `tap-hold-release`, `defhands` for
  opposite-hand holds, `sequence-timeout`, tap-dance, `caps-word`, dynamic
  macros and Unicode output.
- **A test bench.** `kanata --check` and the online simulator replay
  input against a configuration before it touches your keyboard.

macOS sets the terms: kanata needs the Karabiner DriverKit
VirtualHIDDevice driver at the version each release names (v6.2.0 for
1.12.0), runs as root in a terminal window of its own, cannot read a mouse
as input there, and is maintained by someone who, by his own release notes,
owns no Mac.

## Where Flash is stronger

- **It knows what is on screen.** kanata decides what a key sends; Flash
  decides what it does in the app you are in: `]t` is the next tab in a
  browser, Finder or tmux, `f` labels every button and link, and windows,
  the bar and the flashlight answer the same keys.
- **Per-app keys without a companion.** A `[mode.apps."<bundle id>"]`
  table changes a binding while that app is focused; kanata needs a
  process watching the frontmost app and driving its TCP server.
- **No driver, no root.** Flash needs the Accessibility grant and nothing
  else, so it installs where a virtual HID driver is not allowed.
- **A map you can read.** `?` in NORMAL opens the [key mappings](/mappings)
  page, which draws your keyboard for every mode and layer.

## Flash features you might like

- [HYPER](../hyper-mode.md): hold the NORMAL leader and the number row is
  the Apple function row, with arrows on the physical E, S, D and F keys; a
  navigation layer that needs no driver.
- [Layers](../layers.md) with `sticky = false` are kanata's one-shot layer
  for commands rather than keys.
- NORMAL sequences (`<leader>gs`) with a which-key palette after
  `[mode] which_key_ms`, where kanata uses `sldr` and `defseq`.
- `[keyboard] layout = "colemak"` when kanata types your Colemak over a
  U.S. input source: hint labels then use the letters your home row types.

## Running kanata next to Flash

kanata owns what each key sends; Flash binds the result. A Caps Lock that
taps Escape and holds Hyper (Control, Option, Shift and Command, `lmet`
being Command on a Mac):

```text
(defcfg process-unmapped-keys yes)
(defsrc caps)
(defalias hyp (tap-hold 200 200 esc (multi lctl lalt lsft lmet)))
(deflayer base @hyp)
```

reaches Flash as `cmd+ctrl+alt+shift+…`, which an all-mode chord takes in
every mode. Flash can also switch kanata's layers as apps come forward,
from an event [monitor](../monitors.md#runs-and-events) and kanata's TCP
server, started with `--port 127.0.0.1:7070` (a bare port listens on every
address):

```toml
[mode.all.mappings]
"cmd+ctrl+alt+shift+f" = ["flash", "mouse", "target"]
"cmd+ctrl+alt+shift+g" = ["flash", "mouse", "grid", "--bisect"]
"cmd+ctrl+alt+shift+<space>" = ["flash", "mode", "flashlight"]
"cmd+ctrl+alt+shift+w" = ["flash", "window", "switch"]
"cmd+ctrl+alt+shift+t" = ["flash", "mode", "terminal"]

[monitors.kanata-layer]
event = "core:focus.changed"
run = ["~/.config/flash/kanata-layer.sh"]
```

```sh
#!/bin/sh
# ~/.config/flash/kanata-layer.sh: Flash sets FLASH_EVENT_BUNDLE_ID.
case "$FLASH_EVENT_BUNDLE_ID" in
  org.mozilla.firefox | com.google.Chrome) layer=browser ;;
  *) layer=base ;;
esac
printf '{"ChangeLayer":{"new":"%s"}}\n' "$layer" | nc -w 1 127.0.0.1 7070
```

`ChangeLayer` is in kanata 1.12.0's documented protocol; the script is a
sketch to adapt, and `deflayer browser` has to exist.

## Moving from kanata

| kanata | Flash |
| --- | --- |
| `defsrc`, `deflayer` remaps, `tap-hold`, home-row mods | Stay in kanata, or move to [Karabiner-Elements](karabiner-elements.md) |
| Caps Lock to Escape alone | System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys also does it, without a driver |
| `layer-while-held nav` with arrows | Keep it, or HYPER in NORMAL: hold the leader, arrows on E S D F |
| `layer-switch` to a layer of actions | A Flash [layer](../layers.md), entered with `mode layer --name=` |
| `one-shot` of a layer | A layer with `sticky = false` |
| `sldr` and `defseq` | NORMAL sequences under `[mode.normal.mappings]` |
| `cmd` actions (`danger-enable-cmd yes`, the `cmd_allowed` build) | A mapping's argv, run as you rather than as root |
| kanata-vk-agent, TCP `ChangeLayer` for app-aware layers | `[mode.apps."<bundle id>"]` for Flash's keys; the monitor above for kanata's |
| `lrld` live reload, `--check` | Saving the file reloads it; `flash config check` |

NORMAL and layers are Flash's modes, off until an all-mode chord runs
`mode normal` or `mode leave` ([advanced mode](../modes.md#advanced-mode));
the chords above work without them.

*Checked 2026-10-23 against the kanata
[README](https://github.com/jtroo/kanata),
[configuration guide](https://github.com/jtroo/kanata/blob/main/docs/config.adoc)
and the [v1.12.0 release notes](https://github.com/jtroo/kanata/releases/tag/v1.12.0).*
