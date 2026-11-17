# Flash and Rectangle

[Rectangle](https://github.com/rxhanson/Rectangle) is "a window management
app for macOS based on Spectacle": move and resize windows with keyboard
shortcuts and snap areas, halves, thirds, quarters, maximize, and since 2.0
on-demand rows and columns. It is MIT Swift for macOS 14+, about 30,000
stars, very active (v2.0.3 in October 2026), with Accessibility as its only
permission and a paid Rectangle Pro for layouts and sync. Its window actions
are the ones Flash's `window move` also offers.

| | Rectangle | Flash |
| --- | --- | --- |
| License, price | MIT, free; Pro paid | MIT, free |
| Platforms | macOS 14+ (v1.100 for 10.15 to 13) | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Windows | Shortcuts and snap areas: halves, thirds, quarters, maximize, display moves, on-demand tiling, cycling | Named positions, proportional frames, placement rules by app and title, directional focus, minimize and restore, native full screen |
| Spaces | None (no public API) | None |
| Configuration | GUI; JSON import and export; `rectangle://execute-action` URLs | TOML, live reload, `flash window move` CLI |
| Hints, modes, bar | None | Yes |
| Maintenance | v2.0.3, October 2026 | 1.0.0, October 2026 |

## Where Rectangle is stronger

- **Snap areas with the mouse**, animations, cycling through sizes on
  repeated presses, and a GUI with every shortcut visible.
- **Rectangle Pro** adds whole-workspace layouts, stashing and iCloud sync.
- **Thirds, sixths and display moves** cover more positions out of the
  box.
- **Older macOS** through v1.100.

## Where Flash is stronger

- **Placement rules**: a matching window is placed once when it appears,
  then left alone.
- **Directional focus** (`window focus --direction=left`) and stack
  cycling, which Rectangle does not do.
- **The same file holds hints, modes and the bar.**

## Flash features you might like

- `window move --position=lefthalf|righthalf|tophalf|bottomhalf|topleft|
  ...|maximized` and `--x=10% --y=10% --width=80% --height=80%`
  ([windows](../windows.md)).
- `window minimize`, `window restore`, `window fullscreen --state=on`.
- `[[window_rules]]` placement by app and title, once per window
  ([windows](../windows.md#place-windows-as-they-appear)).

## Moving from Rectangle

| Rectangle | Flash |
| --- | --- |
| ⌃⌥← left half | `"ctrl+alt+left" = ["flash", "window", "move", "--position=lefthalf"]` |
| ⌃⌥→ right half | `--position=righthalf` |
| ⌃⌥↩ maximize | `--position=maximized` |
| ⌃⌥C center | `--position=centered` |
| Thirds | `--x=0% --width=33%` and so on |
| Next display | `--screen=+1`, `--screen=-1` for the previous one |
| Snap areas | Not available |
| `rectangle://execute-action?name=left-half` | `flash window move --position=lefthalf` |

```toml
[mode.all.mappings]
"ctrl+alt+left" = ["flash", "window", "move", "--position=lefthalf"]
"ctrl+alt+right" = ["flash", "window", "move", "--position=righthalf"]
"ctrl+alt+return" = ["flash", "window", "move", "--position=maximized"]
```

Both can run together if their shortcuts differ; many people keep Rectangle
for snap areas and let Flash do the rest.

*Checked 2026-10-14 against the Rectangle
[README](https://github.com/rxhanson/Rectangle).*
