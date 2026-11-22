# Layers

A layer is a key table of your own, what skhd's modes, Hammerspoon's
`hs.hotkey.modal` and i3's binding modes are elsewhere: a resize layer whose
`h` `j` `k` `l` move the focused window, a media layer, a launcher layer, a
layer that runs your own scripts. While a layer is on, only its keys act;
Escape leaves it.

## Make your own layer

This builds a `window` layer step by step. Every step goes in
`~/.config/flash/flash.toml`, and saving the file applies it.

Layers are one of Flash's [modes](modes.md), which stay off until a shortcut
in [`[mode.all.mappings]`](config:mode.all.mappings) runs `mode normal` or
`mode leave` ([advanced mode](modes.md#advanced-mode)). If your file has none
yet, step 3 adds one.

**1. Declare the layer.** A `[mode.layers.<name>]` table creates it. The
name is 1–32 characters of `a-z`, `0-9`, `_` and `-`, and cannot be a
built-in mode or scope (`normal`, `insert`, `command`, `terminal`, `hyper`,
`hold`, `visual`, `text`, `disabled`, `all`). `label` is what the mode pill shows while you are in it.

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.layers.window]
label = "WINDOW"   # the name in capitals by default
```

**2. Give it keys.** `[mode.layers.<name>.mappings]` is written like any
other [mapping table](mappings.md): a key or sequence on the left, a
command on the right.

```toml
[mode.layers.window.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"k" = ["flash", "window", "move", "--position=tophalf"]
"j" = ["flash", "window", "move", "--position=bottomhalf"]
"f" = ["flash", "window", "move", "--position=maximized"]
"c" = ["flash", "window", "move", "--position=centered"]
"n" = ["flash", "window", "move", "--screen=+1"]
"<return>" = ["flash", "mode", "leave"]
```

**3. Bind a key that enters it.** `mode layer --name=<name>` enters a
layer. Bind it in NORMAL, or in [`[mode.all.mappings]`](config:mode.all.mappings)
to reach it from INSERT too. The first two all-mode lines turn the modes on;
skip them if your file already has such a shortcut:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+w" = ["flash", "mode", "layer", "--name=window"]

[mode.normal.mappings]
"<leader>w" = ["flash", "mode", "layer", "--name=window"]
```

The same command works from a shell, a script or another tool:
`flash mode layer --name=window`.

**4. Decide how it ends.** By default a layer stays on after each key, so
`h` then `n` moves the window left, then to the next display. Escape, or a
key mapped to `mode leave` like `<return>` above, returns to the mode you
entered from. For a layer that runs one key and leaves, set
`sticky = false`:

```toml
[mode.layers.window]
label = "WINDOW"
sticky = false   # one key, then back where you were
```

**5. Check it.** A mistake is reported when the file reloads, and
`flash config check` lists the same diagnostics from a terminal. Then:

- the [key mappings](/mappings) page shows the layer as a mode of its own,
  with its keyboard drawn;
- entering the layer turns the pill and the window border orange and shows
  its `label`;
- pausing after entry lists its keys; pausing on a sequence lists what can
  follow ([`[mode] which_key_ms`](config:mode.which_key_ms));
- `flash resident status` reports the layer's name as `mode`.

## Options

| Key | Default | Meaning |
| --- | --- | --- |
| [`label`](config:mode.layers.resize.label) | the name in capitals | The pill's text while the layer is on, also `#{flash.mode}` in the [status bar](status-format.md) |
| `sticky` | `true` | Stay on after each mapping (`true`), or leave as one runs (`false`) |
| [`mappings`](config:mode.layers.resize.mappings) | none | The layer's keys, as a `[mode.layers.<name>.mappings]` table |

## What a key can run

A layer's mappings take every form other tables take:

| Value | Runs |
| --- | --- |
| `["flash", "<topic>", "<action>", ...]` | A Flash [command](commands.md), in-process |
| `["/usr/bin/pmset", "displaysleepnow"]` | Any other argv launches that program; use `["/bin/sh", "-c", "..."]` for pipes or redirection |
| `["flash", "mode", "layer", "--name=<other>"]` | Another layer; leaving it returns where this one would |
| `{ command = [...], repeat = true }` | A sequence whose last key repeats without its prefix |
| `false` | Nothing: hides an all-mode chord while the layer is on |

Keys can be single keys (`"h"`), chords (`"shift+h"`) or sequences
(`"gg"`), with the same syntax as [every mapping](mappings.md). Counts work:
`3l` runs `l` three times. Registers work too.

## How a layer behaves

- Only the layer's mappings act, then [`[mode.all.mappings]`](config:mode.all.mappings)'s;
  NORMAL's keys do not. Every other key and chord is swallowed, as in
  NORMAL, so nothing types into the app. `<leader>` is NORMAL's prefix and
  is rejected in a layer table, and NORMAL's Vim keys are not read there:
  `q`, `@`, `m`, `'` and `` ` `` are swallowed unless the layer maps them,
  never a macro or a mark.
- Escape leaves, back to the mode the layer was entered from: NORMAL, or
  INSERT when an all-mode chord entered it there. A layer entered from HYPER
  or HOLD returns to NORMAL, and one entered from another layer returns
  where that one would. `mode leave` does the same; `mode normal` and
  `mode insert` go where they say. Map `"<escape>"` in the table to give
  Escape another command (the layer then needs another way out), and write
  `"<key>" = false` to hide an all-mode chord inside the layer.
- A layer stays after each mapping (`sticky = true`, the default, as in i3).
  With `sticky = false` it is one-shot: it leaves as one of its mappings
  runs, so the command runs in the mode the layer was entered from. A mode
  command (`mode insert`, `mode command`, another layer) decides the mode
  itself.
- The pill shows `label` in orange, the window border turns orange, and
  `#{flash.mode}` reads the label; the pill keeps the width of the base
  modes' labels. `flash resident status` reports the layer's name as `mode`
  and `mapping_scope`, which is why no layer can take a built-in mode's
  name.
- A layer captures as NORMAL does. The session tap swallows its keys, its
  own modified chords are its Carbon registrations, and switching apps keeps
  it. HYPER is NORMAL's leader hold, so the hyper key is one more key of the
  layer. `mode hold` (⌘⌃H) grabs from a layer as from NORMAL, and the drop
  lands in NORMAL. A click, with the mouse, `f` or `F`, keeps the layer,
  on an input as anywhere else. The command line opened in a layer closes
  back to the layer's base mode.
- Entering a layer needs advanced mode, as NORMAL does. A mapping that names
  an undeclared layer is reported when the file loads and does nothing;
  `flash mode layer` with an unknown name exits 1. Saving the file without
  the layer you are in leaves it.
- Layers are global: `[mode.apps."<bundle-id>"]` has no layer tables, and
  plugins add no keys to them.

## Examples

A resize layer that stays until Escape or Return:

```toml
[mode.normal.mappings]
"<leader>r" = ["flash", "mode", "layer", "--name=resize"]

[mode.layers.resize]
label = "RESIZE"

[mode.layers.resize.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"f" = ["flash", "window", "move", "--position=maximized"]
"n" = ["flash", "window", "move", "--screen=+1"]
"<return>" = ["flash", "mode", "leave"]
```

A one-shot media layer:

```toml
[mode.normal.mappings]
"<leader>m" = ["flash", "mode", "layer", "--name=media"]

[mode.layers.media]
sticky = false

[mode.layers.media.mappings]
"p" = ["flash", "key", "system", "--key=media_play"]
"n" = ["flash", "key", "system", "--key=media_next"]
"m" = ["flash", "volume", "mute"]
```

A launcher: one key opens or focuses an app, then the layer is gone.

```toml
[mode.all.mappings]
"cmd+ctrl+o" = ["flash", "mode", "layer", "--name=open"]

[mode.layers.open]
label = "OPEN"
sticky = false

[mode.layers.open.mappings]
"b" = ["flash", "app", "open", "--name=Safari"]
"t" = ["flash", "app", "open", "--name=Ghostty"]
"m" = ["flash", "app", "open", "--name=Mail"]
"n" = ["flash", "app", "open", "--name=Notes"]
```

A layer of your own scripts and programs:

```toml
[mode.normal.mappings]
"<leader>s" = ["flash", "mode", "layer", "--name=system"]

[mode.layers.system]
sticky = false

[mode.layers.system.mappings]
"d" = ["/usr/bin/pmset", "displaysleepnow"]
"b" = ["/bin/sh", "-c", "~/bin/backup.sh >> ~/backup.log 2>&1"]
"n" = ["flash", "notify", "send", "--title=Break", "--body=Stand up"]
```

Layers inside layers: `r` in the window layer enters the resize layer, and
Escape there returns to NORMAL, where the window layer was entered from.

```toml
[mode.layers.window.mappings]
"r" = ["flash", "mode", "layer", "--name=resize"]
```

The [tiling](tiling.md) guide has an i3-style layer for its keys.
