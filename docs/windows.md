# Window navigation and placement

Flash can focus a nearby window, place the focused window, and apply an
opt-in placement rule when a matching window appears. Window operations use
macOS Accessibility; apps that do not expose a usable window may not respond.

## Focus a nearby window

```sh
flash window_focus --direction=left
flash window_focus --direction=right
flash window_focus --direction=up
flash window_focus --direction=down
```

The direction is relative to the focused window. These commands can also be
used in `[mode.*.mappings]`. Use `:flashlight @windows` when you know a window's
title instead of its position.

## Place the focused window

`window_move` supports named positions, a complete proportional frame, and
relative display moves:

```sh
flash window_move --position=lefthalf
flash window_move --x=10% --y=10% --width=80% --height=80%
flash window_move --screen=+1
```

See [commands](commands.md) for the available positions and frame
semantics. `window_minimize`, `window_restore`, and `window_fullscreen` control
native window state.

## Place windows as they appear

Add `[[window_rules]]` entries to `flash.toml`:

```toml
[[window_rules]]
bundle_id = "com.apple.Terminal"
position = "lefthalf"

[[window_rules]]
bundle_id = "org.mozilla.firefox"
title_contains = "Downloads"
position = "righthalf"
screen = 1

[[window_rules]]
bundle_id = "com.apple.TextEdit"
x = 10
y = 10
width = 80
height = 80
```

`bundle_id` matches the app exactly; `title_contains` matches without regard
to letter case. The first matching rule wins in file order. A rule takes
either `position` or all four numeric percentages; `screen` is an integer
relative display offset with the same meaning as `window_move --screen`. Run
`flash config_check` to validate the rules.

Placement rules are opt-in and event-driven. Flash evaluates a newly observed
window once for the current configuration, so moving it by hand afterward does
not fight an automatic resize. Saving the config evaluates existing
non-minimized windows with frames on connected displays against the changed
rules too. macOS Accessibility does not identify which Space each window is on.
