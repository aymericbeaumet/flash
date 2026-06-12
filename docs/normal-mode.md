# Normal Mode

Normal mode mappings are owned by `Sources/flash/App/NormalMode.swift` and the
default mapping list in `Sources/flash/Config/Config.swift`.

Important defaults:

- `gg` scrolls to top.
- `G` scrolls to bottom.
- `g1` through `g9` select indexed tabs when the focused source supports it.
- `[t` / `]t` cycle previous/next tab.
- `[h` / `]h` navigate target page history back/forward.
- `[a` / `]a` cycle previous/next app in MRU order.
- `n` sends Cmd-N to open a new window.
- `r` reloads the current app view with Cmd-R.
- `R` force-reloads with Cmd-Shift-R, matching browser hard reload semantics.
- `f`, `sf`, and `df` target discovered clickable elements, then enter insert
  mode as explicit mouse interactions.
- `mf` moves the cursor to a discovered target.
- `F`, `sF`, and `dF` use mouse grid mode for precise screen clicks, then enter
  insert mode.
- `mF` moves the cursor with mouse grid mode.
- `:mappings` opens the resolved mapping table, including expanded leader
  bindings and argv mappings.
