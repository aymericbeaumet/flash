# Flash and Interception Tools

[Interception Tools](https://gitlab.com/interception/linux/tools) is "a
minimal composable infrastructure on top of libudev and libevdev": `udevmon`
watches for input devices and starts a job for each, `intercept` grabs a
device and writes its events to standard output, `uinput` writes events
back as a virtual device, and `mux` joins streams. Between them sits any
filter you like, as in `intercept -g $DEVNODE | caps2esc | uinput -d
$DEVNODE`; the official plugins are caps2esc, space2meta, hideaway and
dual-function-keys. It is GPL-3.0 C++, v0.6.8 from November 2021, which is
also its latest commit, and Linux only: macOS has no evdev, no udev and no
uinput. There, the remapping goes to [Karabiner-Elements](karabiner-elements.md)
or [kanata](kanata.md), and Flash takes the keys after them.

| | Interception Tools | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Linux | macOS 13+ |
| Works at | evdev devices, before X, Wayland or the console | One session tap in your login session |
| Model | Unix pipes of raw input events through filters you choose or write | Key presses to commands, by mode and app |
| Typical use | Caps Lock as Escape and Control (caps2esc), tap or hold keys (dual-function-keys), Space as Meta | Vim-style modes, hints, windows, a bar |
| Configuration | `udevmon.yaml` jobs, matched by device name or the events it emits | `flash.toml`, live reload, `flash config check` |
| Maintenance | v0.6.8, November 2021; stable | 1.1.0, October 2026 |

## Where Interception Tools is stronger

- **Filters in any language.** A plugin is a program that reads events on
  standard input and writes them out, so a two-line filter, a C program or
  a Rust crate all fit the same pipe. Flash has plugins too, but none sits
  in the input stream: its tap sees key presses, not modifier changes, and
  never rewrites a key.
- **caps2esc and dual-function-keys** give one key two jobs with timing
  you tune (`TAP_MILLISEC`, `HOLD_START`). macOS's own Modifier Keys
  setting turns Caps Lock into Escape, but not into Escape and Control.
- **Per device, everywhere.** `udevmon` matches each keyboard by name or by
  the events it can emit, hot-plugged ones included, and the result works
  in the console as well as the desktop.
- **Small and settled.** Four tools and a YAML file, unchanged since 2021.

## Where Flash is stronger

- **Modal editing beyond the editor.** caps2esc exists "for vi/Vim/NeoVim
  addicts", by its own description. Flash takes those keys to every app:
  `j` and `k` scroll or walk a list, `f` labels every link and button, `gt`
  changes tabs, `:` opens a command line, and INSERT types as usual.
- **No root, no grab.** Flash reads keys inside your session with the
  Accessibility grant; nothing runs as root or holds a device.
- **What a key does, per app.** `[mode.apps."<bundle id>"]` tables, where
  a pipe sees scancodes and no windows.

## Flash features you might like

- Escape cancels hints, the grid and the command line, and leaves a
  [layer](../layers.md), so a Caps Lock that sends Escape serves Flash too.
- `[startup] run` keeps press-and-hold off and fast key repeat in the same
  file, the `defaults write` lines Vim users on a Mac usually run by hand
  ([startup commands](../startup.md)).
- [HYPER](../hyper-mode.md): hold the leader for the function row and
  arrows on E, S, D and F, no device grab involved.

## Moving from Interception Tools

| Interception Tools | On a Mac |
| --- | --- |
| caps2esc, Escape on tap only | System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys: Caps Lock to Escape |
| caps2esc, Escape on tap and Control on hold | Karabiner-Elements or kanata |
| dual-function-keys, space2meta | kanata's `tap-hold`, or Karabiner-Elements' `to_if_alone` |
| hideaway | No Flash equivalent |
| `udevmon` device matching | Karabiner-Elements or kanata device filters |
| A custom filter in the pipe | A kanata or Karabiner rule; or, for actions rather than keys, a Flash mapping or [plugin](../plugins.md) |

A Vim user's Mac, with Caps Lock already sending Escape:

```toml
[startup]
run = [
  # Key repeat in 1/60 s ticks: 200 ms, then 33 ms.
  ["defaults", "write", "NSGlobalDomain", "InitialKeyRepeat", "-int", "12"],
  ["defaults", "write", "NSGlobalDomain", "KeyRepeat", "-int", "2"],
  ["defaults", "write", "NSGlobalDomain", "ApplePressAndHoldEnabled", "-bool", "false"],
]

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
```

The repeat values take effect at the next login. The two chords turn on
Flash's modes, so it starts in NORMAL ([advanced mode](../modes.md#advanced-mode)).
INSERT is left with a chord, not bare Escape: in INSERT only modified keys
reach Flash's mappings, because Escape belongs to the app you are typing in.

*Checked 2026-10-23 against the Interception Tools
[README](https://gitlab.com/interception/linux/tools), the
[caps2esc](https://gitlab.com/interception/linux/plugins/caps2esc) and
[dual-function-keys](https://gitlab.com/interception/linux/plugins/dual-function-keys)
READMEs, and Apple's guide to the
[modifier keys](https://support.apple.com/guide/mac-help/change-the-behavior-of-the-modifier-keys-mchlp1011/mac).*
