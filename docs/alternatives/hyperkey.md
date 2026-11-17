# Flash and Hyperkey

[Hyperkey](https://hyperkey.app) is "The extra macOS modifier key": it turns
Caps Lock, or any other modifier, into Hyper, all of ⌃⌥⌘⇧ at once, so you get
a modifier no app's own shortcuts use. It can also remap Caps Lock to another
key, and a quick press of the key can still toggle Caps Lock or send Escape.
It is free (it has been since 2022) and closed source, by Ryan Hanson, who
also makes [Rectangle](rectangle.md) and the paid [Superkey](superkey.md),
which includes everything Hyperkey does. Version 1.56 shipped on
22 November 2025, after two fixes earlier that month; it needs macOS 10.15 or
later.

Hyperkey and Flash do not overlap. Hyperkey decides what Caps Lock sends;
Flash decides what ⌃⌥⌘⇧ plus a key does. One naming trap: Flash's
[HYPER](../hyper-mode.md) mode is not the Hyper modifier. It is what happens
while you hold Flash's own hyper key, the NORMAL leader (`\`) by default.

| | Hyperkey | Flash |
| --- | --- | --- |
| License, price | Closed, free | MIT, free |
| Platforms | macOS 10.15+, Intel and Apple silicon | macOS 13+ |
| Permissions | Accessibility, asked at setup | Accessibility |
| Changes what a key sends | Yes: Caps Lock or another modifier to Hyper, or Caps Lock to another key | No |
| Binds actions | No: other apps record the Hyper chords | Yes: `cmd+ctrl+alt+shift+<key>` in `[mode.all.mappings]`, per mode and per app, and plain keys in NORMAL and layers |
| Configuration | A few settings in its window | One TOML file, live reload, `flash config check` |
| Maintenance | 1.56, November 2025; small fixes a few times a year | 1.1.0, October 2026 |

## Where Hyperkey is stronger

- **It makes the modifier.** Flash cannot turn Caps Lock into anything: its
  keyboard tap sees key presses, not modifier changes, and it never rewrites
  a key. Without Hyperkey, or another remapper, there is no Hyper chord for
  Flash to bind.
- **Every app gets it.** Rectangle, Keyboard Maestro and any other app with
  a shortcut field can record a Hyper chord, and nothing collides with it.
  Flash's bindings only serve Flash.
- **Nothing to learn.** Pick the key, tick a box, done. Flash is a file, a
  set of modes and many commands.
- **Older Macs.** It runs back to macOS 10.15; Flash needs 14.

## Where Flash is stronger

- **What the chord does.** Hyperkey stops at the modifier. Flash puts hints,
  the mouse grid, window placement, apps, tabs and the flashlight on
  ⌃⌥⌘⇧ plus a letter.
- **Fewer chords to remember.** Hyper becomes the way in rather than the
  whole keymap: one Hyper chord can enter NORMAL or a [layer](../layers.md),
  and the layer's keys need no modifier at all.
- **The same chord, per app.** `[mode.apps."<bundle id>".all.mappings]`
  gives a Hyper chord a different command in one app, or `false` to leave it
  to that app.
- **A held layer with no remapper.** Holding Flash's hyper key in NORMAL
  turns the number row into the brightness, Mission Control, media and volume
  keys, and `e` `s` `d` `f` into arrows.

## Flash features you might like

- Hyper chords in `[mode.all.mappings]` work while you type, in INSERT, as
  well as in NORMAL ([modifier chords](../mappings.md#modifier-chords)).
- A one-shot layer (`sticky = false`): Hyper and a letter, then one plain key,
  and you are back where you were.
- The commands Hyperkey users most often wire to other apps:
  `mouse target`, `window move --position=lefthalf`, `app open --name=…`.
- `?` in NORMAL opens the key mappings page; its modifier buttons show what
  each key does with a chord held, so the Hyper layer is drawn on your
  keyboard.

## Moving from Hyperkey

Nothing moves: Hyperkey keeps the key, and Flash binds what it sends.

| Hyperkey setup | Flash |
| --- | --- |
| Caps Lock as Hyper | Keep Hyperkey; Flash reads `cmd+ctrl+alt+shift+<key>` |
| Hyper chords recorded in Rectangle or a launcher | They can stay, or move to `[mode.all.mappings]` |
| Quick press as Escape | Keep it; to Flash it is Escape, which cancels hints and leaves a layer |
| A Hyper chord that opens an app | `"cmd+ctrl+alt+shift+s" = ["flash", "app", "open", "--name=Slack"]` |
| Running out of Hyper letters | One Hyper chord into a layer of plain keys |

```toml
# Hyperkey turns Caps Lock into cmd+ctrl+alt+shift; Flash binds what it sends.
[mode.all.mappings]
"cmd+ctrl+alt+shift+<space>" = ["flash", "mode", "normal"]
"cmd+ctrl+alt+shift+f" = ["flash", "mouse", "target"]
"cmd+ctrl+alt+shift+s" = ["flash", "app", "open", "--name=Slack"]
"cmd+ctrl+alt+shift+w" = ["flash", "mode", "layer", "--name=window"]

# One Hyper chord, then plain keys: the layer leaves after one of them.
[mode.layers.window]
sticky = false

[mode.layers.window.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"k" = ["flash", "window", "move", "--position=maximized"]
"c" = ["flash", "window", "move", "--position=centered"]
```

## Using both

This is the intended arrangement: keep Hyperkey running and give Flash the
chords.

- Bind the whole chord, all four modifiers. Flash registers it through macOS,
  so a chord with three of them is a different binding.
- If an app already recorded a Hyper chord, leave it there or move it, not
  both; `flash resident doctor` lists the chords another app holds.
- Hyperkey does not work in password fields, its page says, because macOS
  keeps those keys from other apps; a Hyper chord there does nothing until
  you leave the field.
- Moving to Superkey later changes nothing on Flash's side: it sends the
  same Hyper chords.

*Checked 2026-10-23 against [hyperkey.app](https://hyperkey.app), its
[update feed](https://hyperkey.app/downloads/updates.xml) and the
[Homebrew cask](https://formulae.brew.sh/cask/hyperkey).*
