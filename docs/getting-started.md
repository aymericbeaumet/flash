# Getting started

Flash starts with one hotkey and grows one table at a time. Everything here
is also in the browser help (`flash help_show`), with your own mappings filled in.

## 1. One hotkey

On first launch Flash creates `~/.config/flash/flash.toml` with one mapping:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
```

Press **⌘⇧Space**, then type the letters on the control you want. Press Escape
to cancel. Open the file from the menu-bar icon (**Open Configuration**);
changes apply as soon as you save.

## 2. Grid and search

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]                               # hints
"cmd+shift+alt+space" = ["flash", "mouse_grid"]                             # keyboard grid
"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "] # search
```

In the grid, `1` is the top-left cell and `b` the bottom-right one. Each key
zooms into its cell with the same keys, and the last step clicks. Backspace
steps back, Tab moves to the next display; see [the grid keys](normal-mode.md#mouse-grid).

Keep the trailing space in `--input=:flashlight `: it opens search directly.
Try `@emojis.glyphs fire` or `1234 euros in dollars`.

Pick hotkeys that are free on your Mac. macOS uses Control-Space and
Control-Option-Space to switch input sources, and many editors use
Control-Space for completion.

## 3. Normal mode

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]
```

While NORMAL is active, keys that are not mapped are captured instead of typed.
Press ⌘⌃I, click into a text field, pick an input with `f`, or open Find
(`/`) or a new tab (`t`) to type again.
NORMAL stays active across app and tab switches. See
[normal mode](normal-mode.md) for every binding.

## 4. Status bar and widgets

```toml
[statusbar]
enabled = true

[widgets.system]
anchor = "top_right"
template = """
CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer] #[spark]#{flash.plugin.cpu.history}#[nospark]
MEM #[meter=20]#{flash.plugin.memory.percent}#[nometer]
#{flash.plugin.processes.top_cpu}
"""
```

The bar takes the top of the screen, so macOS auto-hides its own menu bar while
it is enabled. Widgets sit on the desktop, below your windows. Start from the
[status bar example](examples/statusbar/README.md) or the
[widget examples](examples/widgets/README.md), and see
[widgets](widgets.md) for a conky migration table.

## 5. Remap or remove anything

Every default binding can be changed or removed, including the ones plugins add:

```toml
[mode.normal.mappings]
"t" = false                                          # remove a default
"gs" = ["flash", "mouse_target", "--scope=screen"]   # add your own
```

`flash config_check` validates the file without the app running, so it fits in
a dotfiles CI job.

## 6. Plugins

Write a plugin in any language, or pin someone else's to a commit. Start with
the [plugin cookbook](plugin-cookbook.md).

## Coming from Linux?

| You used | In Flash |
| --- | --- |
| keynav, warpd grid | `mouse_grid`, keyboard-shaped, with `--bisect` |
| Vimium, qutebrowser hints | `mouse_target`, in every app |
| warpd normal mode | `mouse_pointer` |
| conky | [desktop widgets](widgets.md) |
| polybar, waybar | `[statusbar]` with tmux formats |
| rofi, dmenu | flashlight |
| i3, sway, Hyprland modes | NORMAL / INSERT / COMMAND / TERMINAL with `[mode.*.mappings]` |
| i3 `move`, Hyprland dispatchers | `window_move` |
| swaymsg, hyprctl | `flash <verb>`, `flash status --json` |
| dotfiles | one `flash.toml`, live reload, `flash config_check` |

## Quit and uninstall

Quit from the menu-bar icon or with `flash quit`. Set `[app] autostart = false`
to stop Flash from starting at login, and `[app] menu_bar_icon = false` to hide
the icon.

```sh
brew uninstall --cask --zap flash@nightly
```

`--zap` also removes your configuration, logs, and local data.

