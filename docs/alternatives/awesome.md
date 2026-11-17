# Flash and awesome

[awesome](https://awesomewm.org) is "a highly configurable, next generation
framework window manager for X": its C core exposes a Lua API, and `rc.lua`
builds everything on it, from keys (`awful.key`) and tags to the wibar, its
widgets, client rules and the notifications of its own `naughty` daemon. It
is GPL-2.0, about 7,000 stars; the last release, 4.3, dates from January
2019, and development continues on `master`, with commits in 2026, which
its README shows how to package as `awesome-git`. It is an X11 window manager with no macOS
port. The macOS tool closest to its spirit, Lua driving the desktop, is
[Hammerspoon](hammerspoon.md); Flash takes the keyboard-driven half (keys,
tags as workspaces, a bar, rules) as configuration rather than code.

| | awesome | Flash |
| --- | --- | --- |
| License, price | GPL-2.0, free | MIT, free |
| Platforms | X11 on Linux and the BSDs | macOS 13+ |
| Model | Tags (a window can carry several, a screen can show several) with layouts: tile, fair, spiral, max, magnifier, floating | Opt-in tree tiling with emulated workspaces, one per display |
| Keys | `awful.key` tables, `awful.keygrabber` for modal keys, a hotkeys popup | Chords in every mode, NORMAL keys and sequences, layers, a which-key palette |
| Bar, widgets | `awful.wibar` and `wibox` widgets in Lua | Built-in bar and desktop widgets in tmux formats |
| Notifications | `naughty`, a notification daemon of its own | macOS Notification Center; `notify send` posts to it |
| Configuration | `rc.lua`, `awesome -k` checks it, `awesome-client` runs Lua live | `flash.toml`, applied on save, `flash config check`, `flash <topic> <action>` |
| Maintenance | 4.3, January 2019; `master` active | 1.1.0, October 2026; tiling is new |

## Where awesome is stronger

- **The whole desktop is a Lua program.** Widgets, layouts, rules and key
  handlers are code with access to every client, tag and screen, and
  `awesome-client` runs more of it live. Flash is configured in data; what
  it cannot express needs a plugin, and no plugin can draw a widget or a
  layout.
- **Tags, not workspaces.** A window on two tags at once, a screen showing
  three tags together: Flash has one workspace per display and a window in
  exactly one.
- **It draws.** Titlebars, wibars, wiboxes anywhere on screen and
  notification popups styled in `theme.lua`. On macOS only WindowServer
  composites, and only Notification Center shows notifications, so Flash's
  drawing stops at its own bar, widgets, popups and alerts.
- **Real tags and placement at map time.** macOS offers no public API to
  switch Spaces; Flash parks hidden windows off screen and moves new windows
  after they appear, through Accessibility.

## Where Flash is stronger

- **Modal keys without writing a keygrabber.** A [layer](../layers.md) is a
  table in the file; it swallows what it does not map, takes counts, and
  Escape leaves it.
- **Hints and Vim keys in every app.** `f` labels every button and link of
  the focused window; `j`, `k`, `gt` and `/` scroll (or move a list's
  selection), switch tabs and find wherever you are.
- **Data that validates.** `flash config check` reports a mistake as
  `file:line:col` without starting anything, and a key's command is the same
  `flash <topic> <action>` a script runs.
- **A Mac without SIP changes or an X server.**

## Flash features you might like

- `?` opens the live [key mappings](/mappings) page, and pausing on a
  prefix shows a which-key palette: the hotkeys popup, generated from what
  is bound rather than from descriptions.
- `[statusbar.sources.<name>]` is `awful.widget.watch`: a command, an
  interval, and the output in the bar.
- [Monitors](../monitors.md) post a macOS notification with `notify = true`
  when a value crosses a threshold, where a `naughty.notify` call in a timer
  used to.
- [Hammerspoon](hammerspoon.md) can run beside Flash for the Lua you still
  want, calling `flash <topic> <action>` from its own code.

## Moving from awesome

| awesome | Flash |
| --- | --- |
| `awful.key({ modkey }, "j", function () awful.client.focus.byidx(1) end)` | `"alt+j" = ["flash", "window", "focus", "--direction=next"]` in `[mode.all.mappings]` |
| `awful.client.focus.bydirection("left")` | `window focus --direction=left` |
| `awful.layout.inc(1)` | `tile layout --type=toggle`, with `[tiling] enabled = true` |
| `awful.client.floating.toggle`, `c.fullscreen = not c.fullscreen` | `tile float`, `tile fullscreen` (`window fullscreen` for native full screen) |
| `c:kill()` | `window close` |
| `c.minimized = true` | `window minimize`; `window restore` brings it back |
| `awful.tag({ "1", "2", … }, s, …)` | `[tiling] workspaces = ["1", "2", …]` |
| `tag:view_only()`, `c:move_to_tag(tag)` | `workspace switch --name=2`, `workspace move_window --name=2` |
| `awful.tag.viewtoggle` (several tags at once) | Not available |
| Rules with `properties = { floating = true }` or `{ tag = "2" }` | `[[tiling.rules]]` with `float = true` or `workspace = "2"`; `[[window_rules]]` for a position without tiling |
| `awful.wibar`, `wibox.widget.textclock()` | `[statusbar]` with `%H:%M` in the template |
| `awful.widget.watch("cmd", 5)` | `[statusbar.sources.<name>]` with `command` and `interval = 5` |
| `naughty.notify({ title = … })` | `flash notify send --title=…` |
| `awful.keygrabber` modal keys | A layer |
| `hotkeys_popup.show_help` | `?` in NORMAL, or `flash mappings show` |
| `awful.spawn("firefox")` | `"alt+b" = ["flash", "app", "open", "--name=Firefox"]` |
| `awesome-client 'awesome.restart()'` | Save the file, or `flash config reload` |
| `awesome -k` | `flash config check` |

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4"]

[[tiling.rules]]
bundle_id = "org.mozilla.firefox"
workspace = "2"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+j" = ["flash", "window", "focus", "--direction=next"]
"alt+k" = ["flash", "window", "focus", "--direction=previous"]
"alt+<space>" = ["flash", "tile", "layout", "--type=toggle"]
"alt+ctrl+<space>" = ["flash", "tile", "float"]
"alt+shift+f" = ["flash", "tile", "fullscreen"]
"alt+shift+c" = ["flash", "window", "close"]
"alt+n" = ["flash", "window", "minimize"]
"alt+1" = ["flash", "workspace", "switch", "--name=1"]
"alt+2" = ["flash", "workspace", "switch", "--name=2"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"alt+shift+2" = ["flash", "workspace", "move_window", "--name=2"]
"alt+r" = ["flash", "mode", "flashlight"]
"alt+m" = ["flash", "mode", "layer", "--name=media"]

[mode.layers.media]
sticky = false

[mode.layers.media.mappings]
"p" = ["flash", "key", "system", "--key=media_play"]
"n" = ["flash", "key", "system", "--key=media_next"]
"m" = ["flash", "volume", "mute"]

[statusbar.sources.load]
command = ["/bin/sh", "-c", "sysctl -n vm.loadavg | awk '{print $2}'"]
interval = 5

[statusbar]
enabled = true
template = "#[align=left]#[pill] #{flash.workspace} #[nopill] #{flash.workspaces}#[align=right]load #{flash.source.load} · %a %H:%M"
```

The `mode normal` and `mode insert` chords switch Flash's modes on, which
the media layer needs; Flash then starts in NORMAL and swallows unmapped
keys until `i` or a click ([advanced mode](../modes.md#advanced-mode)).

*Checked 2026-10-23 against the awesome
[README](https://github.com/awesomeWM/awesome), its releases, and the
[rc.lua documentation](https://awesomewm.org/apidoc/documentation/05-awesomerc.md.html).*
