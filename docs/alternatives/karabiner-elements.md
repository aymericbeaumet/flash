# Flash and Karabiner-Elements

[Karabiner-Elements](https://karabiner-elements.pqrs.org) is "A powerful and
stable keyboard customizer for macOS". It works below every app: it seizes the
keyboard and sends what your rules say through a virtual HID keyboard and
mouse, so macOS, and Flash, only ever see the remapped keys. It is free,
public domain (Unlicense), from pqrs.org, with about 23,000 GitHub stars and a
steady release train: 16.0.0 in May 2026, 16.3.0 on 6 September 2026. It
supports macOS 13 Ventura to 27, on Apple silicon only on 27.

Flash never changes what a key sends. It decides what a key does once it
arrives: a command, a mode, a layer. So the two do not compete, and most
Karabiner users keep it next to Flash and move only the rules that run
things.

| | Karabiner-Elements | Flash |
| --- | --- | --- |
| License, price | Unlicense (public domain), free | MIT, free |
| Platforms | macOS 13 to 27; Intel and Apple silicon, Apple silicon only on 27 | macOS 13+ |
| Permissions | A driver extension for its virtual keyboard and mouse, background items, Accessibility (for its core service since 16.0.0) and Input Monitoring | Accessibility, for its keyboard tap and the Accessibility tree; no driver, no Input Monitoring |
| Works at | The HID level, below macOS: what a key or mouse button sends | Above it: what a key, a chord or a sequence runs |
| Rules | Simple and complex modifications: `to_if_alone`, `to_if_held_down`, `to_delayed_action`, simultaneous keys; conditions on the frontmost app, the device, the input source, variables and, since 16.0.0, the focused element's role | Mappings per mode (NORMAL, INSERT, VISUAL, HYPER, HOLD, your layers) and per app; sequences, counts, repeat, a which-key palette |
| Actions | Other keys and mouse events, `shell_command`, `software_function` (open an app, move the pointer, sleep the Mac) | Every Flash command (hints, the grid, windows, tabs, apps, the flashlight, the bar) or any argv |
| Configuration | A settings window, rules imported from its gallery, `~/.config/karabiner/karabiner.json`, reloaded when it changes | One TOML file, live reload, `flash config check` |
| Maintenance | 16.3.0, September 2026; four releases since May 2026 | 1.1.0, October 2026 |

## Where Karabiner-Elements is stronger

- **It changes the key itself.** Caps Lock as Escape on a tap and Control on
  a hold, Caps Lock as Hyper, both Command keys together as a new key, `j`
  and `k` pressed at once as Escape: all of that happens before the session
  where Flash listens. Flash's tap only decides whether to swallow a key and
  where to route it. It sees key presses, not modifier changes, so a
  modifier tapped on its own means nothing to it.
- **Timing rules.** `to_if_alone`, `to_if_held_down`, `to_delayed_action` and
  simultaneous keys make a tap-hold and chord engine. Flash has one
  tap-or-hold key, its hyper key: a tap is the NORMAL leader, a hold is
  [HYPER](../hyper-mode.md), and only in NORMAL.
- **Per-device rules.** One rule for the built-in keyboard, another for an
  external one, by vendor and product. Flash does not tell keyboards apart.
- **Mouse buttons and other devices.** Extra trackball buttons, mouse motion
  turned into scrolling or keys, consumer keys. Flash synthesizes clicks and
  moves; it does not rewrite a device's buttons.
- **Rules that look at the focused field.** Since 16.0.0 a condition can read
  the focused element's role through Accessibility, so a key can behave one
  way in a text area and another elsewhere. Flash keeps that decision in its
  modes: you enter INSERT, a focused field never decides it for you.
- **A gallery and a debugger.** Ready-made rules to import, and
  Karabiner-EventViewer to see exactly what each key sends.

## Where Flash is stronger

- **What happens after the key.** Karabiner's actions are keys, mouse events
  and shell commands. Flash's are labelled hints in every app, the mouse grid,
  window placement and focus, tab and app commands that resolve in each app,
  the flashlight, the bar and popups.
- **Modes instead of variables.** A Karabiner modal layer is a set of rules
  guarded by `variable_if`, with other rules setting and clearing the
  variable. In Flash, NORMAL, INSERT and named [layers](../layers.md) are the
  model: a pill in the bar names the mode, Escape leaves a layer, unbound keys
  are swallowed instead of typed, and counts and sequences work inside.
- **Plain letters.** NORMAL holds the keyboard until you enter INSERT, so a
  binding needs no modifier: `f` clicks a label, `<leader>om` opens Messages.
- **A binding reads like a binding.** One TOML line per key instead of a
  nested JSON manipulator, and `flash config check` reports a bad key or an
  unknown command with its line and column before you reload.
- **No system extension.** Flash runs on the Accessibility grant alone; there
  is no driver to approve and no root service.

## Flash features you might like

- [HYPER](../hyper-mode.md): hold the leader (`\` by default) in NORMAL and
  the number row becomes the function row (brightness, Mission Control,
  media, volume) and `e` `s` `d` `f` become the arrows, with no remapping
  rule. `[mode.hyper.mappings]` changes any of them.
- `mouse target`, `mouse grid` and `mouse pointer`, where Karabiner's mouse
  keys rule moves the pointer a step at a time ([hints](../hints.md),
  [mouse grid](../mouse-grid.md)).
- `[startup] run` sets key repeat and the standard-function-keys
  preference from the same file, with `defaults write`
  ([startup commands](../startup.md)).
- `?` in NORMAL opens the key mappings page: your keyboard drawn with what
  each key does in the mode you pick, modifier layers included.

## Moving from Karabiner-Elements

Keep the remapping in Karabiner. Move the rules that launch, click or switch
something.

| Karabiner-Elements | Flash |
| --- | --- |
| Caps Lock to Escape (a simple modification) | Stays in Karabiner, or macOS's own Modifier Keys setting |
| Caps Lock as Escape on a tap, Control on a hold (`to_if_alone`) | Stays in Karabiner |
| Caps Lock as Hyper | Stays in Karabiner; bind the chords it sends, `"cmd+ctrl+alt+shift+t"`, in `[mode.all.mappings]` |
| `shell_command` that opens an app | `["flash", "app", "open", "--name=<app>"]` on a chord or a NORMAL key |
| `shell_command` that runs `flash mouse target` | The same command as a Flash chord, dispatched in process instead of through a shell |
| `frontmost_application_if` | `[mode.apps."<bundle id>".<scope>.mappings]` ([app-specific mappings](../configuration.md#app-specific-mappings)) |
| A modal layer from `set_variable` and `variable_if` | A `[mode.layers.<name>]` table, entered by `mode layer --name=<name>`; Escape leaves it |
| Vi arrows on a held key | HYPER's arrows from NORMAL, or `key arrow --direction=left` in a layer; while you type in INSERT, keep the Karabiner rule |
| Mouse keys | `mouse pointer`, `mouse nudge`, the grid and hints |
| Simultaneous keys, per-device rules, mouse buttons | Stay in Karabiner |

```toml
# Karabiner keeps Caps Lock: Escape on a tap, Hyper (cmd+ctrl+alt+shift) on a hold.
[mode.all.mappings]
"cmd+ctrl+alt+shift+<space>" = ["flash", "mode", "normal"]
"cmd+ctrl+alt+shift+f" = ["flash", "mouse", "target"]
"cmd+ctrl+alt+shift+g" = ["flash", "mouse", "grid"]
"cmd+ctrl+alt+shift+t" = ["flash", "app", "open", "--name=Ghostty"]
"cmd+ctrl+alt+shift+w" = ["flash", "mode", "layer", "--name=window"]

# A Karabiner layer built from set_variable and variable_if, as a Flash layer
[mode.layers.window]
label = "WINDOW"

[mode.layers.window.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"m" = ["flash", "window", "move", "--position=maximized"]
"n" = ["flash", "window", "move", "--screen=+1"]
```

## Using both

This is the usual arrangement, and the two do not get in each other's way:

- Map the key Karabiner produces, not the physical one. With Caps Lock as
  Hyper, Flash sees `cmd+ctrl+alt+shift+<key>`; with Caps Lock as Escape,
  Flash sees Escape, which cancels hints and leaves a layer.
- A rule that consumes a chord keeps it from Flash. Leave the chords you bind
  in Flash out of your complex modifications; `flash resident doctor` lists
  the chords another app already holds.
- Karabiner's variables and Flash's modes are separate state. A Karabiner
  layer active while Flash is in NORMAL means two tables reading the same
  keys; enter one at a time, or move the layer into Flash.
- Keep `shell_command` for things only a shell does. A rule that runs
  `flash <topic> <action>` works, and is the quickest way to start, but the
  same chord in `flash.toml` skips the shell.

*Checked 2026-10-23 against
[karabiner-elements.pqrs.org](https://karabiner-elements.pqrs.org), its
[installation](https://karabiner-elements.pqrs.org/docs/getting-started/installation/),
[manipulator](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/)
and [configuration file](https://karabiner-elements.pqrs.org/docs/manual/misc/configuration-file-path/)
documentation, and the [releases](https://github.com/pqrs-org/Karabiner-Elements/releases)
on GitHub.*
