# Flash and Qtile

[Qtile](https://qtile.org) is "a full-featured, hackable tiling window
manager written and configured in Python": `config.py` declares keys with
`lazy` commands, groups, layouts and a bar of built-in widgets, it "runs as
an X11 WM or a Wayland compositor", and its command shell and "complete
remote scriptability" reach every object it manages. It is MIT, about 5,300
stars, v0.37.1 in September 2026, with a team of maintainers and steady
releases. It has no macOS build. On a Mac, Flash keeps the parts a Qtile
config is mostly made of (key chords and modes, groups as workspaces, a
dropdown terminal, a bar) in a TOML file, and tiles with an opt-in
[tree](../tiling.md) instead of Qtile's layout classes.

| | Qtile | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux, X11 or Wayland | macOS 13+ |
| Layouts | Columns, Max, MonadTall, Stack, TreeTab, Bsp and more; your own in Python | One tree: tiles or accordion, horizontal or vertical |
| Keys | `Key`, `KeyChord`, chord modes with `mode=True`, chains | Chords in every mode, NORMAL keys and sequences, layers |
| Groups | Groups with `matches`, `ScratchPad` and `DropDown` | Emulated workspaces, `[[tiling.rules]]`, persistent popups |
| Bar | `bar.Bar` of Python widgets | Built-in bar of tmux formats, plugin values and command sources |
| Configuration | `config.py`, `lazy.reload_config()`, `qtile cmd-obj`, `qtile shell` | `flash.toml`, applied on save, `flash config check`, `flash <topic> <action>` |
| Maintenance | v0.37.1, September 2026; active | 1.1.0, October 2026; tiling is new |

## Where Qtile is stronger

- **Python all the way down.** A key can call any function, a hook can
  react to any event, a widget can draw anything, and a layout is a class
  you can write. Flash's file is data; behaviour beyond its commands lives
  in plugins, which are separate processes and cannot change how windows
  are laid out.
- **Many layouts, per group.** Qtile ships a dozen, from MonadTall to
  TreeTab. Flash has tiles and accordion.
- **Groups the window manager really switches**, with `DropDown`s that hold
  any program's window. macOS gives no public API to switch Spaces, so
  Flash parks hidden windows off screen, and its popups run terminal
  programs only.
- **The compositor decides where a window appears.** On macOS a tiler moves
  windows after they show up, through Accessibility; an app that insists on
  its size keeps it.
- **Tested remote control**: everything `qtile cmd-obj` reaches is the same
  object graph the config uses.

## Where Flash is stronger

- **Modes that hold the keyboard.** A Qtile chord without `mode=True` still
  sends unrelated keys to the focused window. A Flash [layer](../layers.md)
  swallows every key it does not map, so nothing leaks into the app, and it
  takes counts (`3l`) and sequences.
- **Keys beyond windows.** NORMAL mode labels every button and link for a
  click, scrolls and switches tabs in any app, and has a command line with
  completion.
- **It runs on the Mac you work on**, through Accessibility, with no SIP
  change and no X server.
- **Popups under bar labels**: btop or a calendar hanging from a segment,
  which a Qtile widget would have to draw itself.

## Flash features you might like

- `KeyChord(..., mode=True, name="Windows")` is a layer with a `label`;
  the bar's pill shows it as Qtile's Chord widget does.
- A chord without a mode, which resets after its key, is a layer with
  `sticky = false`.
- A persistent [popup](../popups.md) is a `DropDown`: `mode terminal
  --name=term` shows and hides the same running process.
- `@windows` in the flashlight and `window switch` find a window by title
  across groups.

## Moving from Qtile

| Qtile | Flash (`[tiling] enabled = true`) |
| --- | --- |
| `Key([mod], "h", lazy.layout.left())` | `"alt+h" = ["flash", "window", "focus", "--direction=left"]` in `[mode.all.mappings]` |
| `lazy.layout.shuffle_left()` | `tile move --direction=left` |
| `lazy.layout.grow_left()` | `tile resize --dimension=width --amount=-50` |
| `lazy.layout.normalize()` | `tile balance` |
| `lazy.next_layout()` | `tile layout --type=toggle` |
| `lazy.window.toggle_floating()`, `toggle_fullscreen()` | `tile float`, `tile fullscreen` |
| `lazy.window.kill()` | `window close` |
| `lazy.group["2"].toscreen()`, `lazy.window.togroup("2")` | `workspace switch --name=2`, `workspace move_window --name=2` |
| `Group("web", matches=[Match(wm_class="firefox")])` | `[[tiling.rules]]` with `bundle_id = "org.mozilla.firefox"` and `workspace = "web"` |
| `floating_layout` rules | `[[tiling.rules]]` with `float = true` |
| `ScratchPad`, `DropDown("term", …)`, `dropdown_toggle("term")` | `[popup.term]` with `persistent = true`, `mode terminal --name=term` |
| `KeyChord([mod], "z", […], mode=True, name="Windows")` | `[mode.layers.windows]` with `label = "WINDOWS"` |
| `lazy.spawncmd()` | `mode command` (`:` in NORMAL) or `mode flashlight` |
| `widget.GroupBox()`, `widget.Clock(format=…)` | `#{flash.workspaces}`, `%H:%M` in `[statusbar] template` |
| `@hook.subscribe.setgroup` | A monitor or plugin on `core:workspace.changed` |
| `lazy.reload_config()` | Saving the file |
| `qtile cmd-obj …` | `flash <topic> <action>` |

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "web"]

[[tiling.rules]]
bundle_id = "org.mozilla.firefox"
workspace = "web"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+h" = ["flash", "window", "focus", "--direction=left"]
"alt+l" = ["flash", "window", "focus", "--direction=right"]
"alt+j" = ["flash", "window", "focus", "--direction=down"]
"alt+k" = ["flash", "window", "focus", "--direction=up"]
"alt+shift+h" = ["flash", "tile", "move", "--direction=left"]
"alt+shift+l" = ["flash", "tile", "move", "--direction=right"]
"alt+n" = ["flash", "tile", "balance"]
"alt+<tab>" = ["flash", "tile", "layout", "--type=toggle"]
"alt+w" = ["flash", "window", "close"]
"alt+shift+f" = ["flash", "tile", "fullscreen"]
"alt+t" = ["flash", "tile", "float"]
"alt+r" = ["flash", "mode", "flashlight"]
"alt+<return>" = ["flash", "app", "open", "--name=Terminal"]
"alt+1" = ["flash", "workspace", "switch", "--name=1"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"alt+<backtick>" = ["flash", "mode", "terminal", "--name=term"]
"alt+z" = ["flash", "mode", "layer", "--name=windows"]

[mode.layers.windows]
label = "WINDOWS"

[mode.layers.windows.mappings]
"g" = ["flash", "tile", "resize", "--dimension=smart", "--amount=40"]
"s" = ["flash", "tile", "resize", "--dimension=smart", "--amount=-40"]
"n" = ["flash", "tile", "balance"]
"m" = ["flash", "tile", "fullscreen"]

[popup.term]
command = ["$SHELL", "-l"]
size = "90%x40%"
persistent = true

[statusbar]
enabled = true
template = "#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.workspaces}#[align=right]%Y-%m-%d %a %H:%M"
```

The first two chords turn on Flash's modes, which layers belong to: Flash
then starts in NORMAL and swallows keys it has no mapping for, until `i` or
a click hands them to the app ([advanced mode](../modes.md#advanced-mode)).
The `alt+…` chords are system-wide, so Option no longer types accented
letters with those keys. Bundle identifiers replace `wm_class`:
`osascript -e 'id of app "Firefox"'` prints one.

*Checked 2026-10-23 against the Qtile [README](https://github.com/qtile/qtile),
its default `config.py`, releases, and the documentation's
[keys](https://docs.qtile.org/en/latest/manual/config/keys.html) and
[groups](https://docs.qtile.org/en/latest/manual/config/groups.html) pages.*
