# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Important defaults:

- `gg` scrolls to top.
- `G` scrolls to bottom.
- `g1` through `g9` select indexed tabs when the focused source supports it.
- `n` sends Cmd-N to open a new window.
- `f`, `rf`, `df`, and `mf` target discovered clickable elements.
- `s`, `rs`, `ds`, and `ms` use snipe mode for precise screen positions.
