# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Important defaults:

- `gg` scrolls to top.
- `G` scrolls to bottom.
- `g1` through `g9` select indexed tabs when the focused source supports it.
- `n` sends Cmd-N to open a new window.
- `r` reloads the current app view with Cmd-R.
- `R` force-reloads with Cmd-Shift-R, matching browser hard reload semantics.
- `f`, `rf`, `df`, and `mf` target discovered clickable elements.
- `F`, `rF`, `dF`, and `mF` use mouse grid mode for precise screen positions.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.
