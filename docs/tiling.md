# Tiling and workspaces

Flash can tile windows the way [AeroSpace](alternatives/aerospace.md) does:
each workspace is a tree of windows laid out in containers, every display
shows one workspace, and the windows of the others are moved off screen.
It runs inside the resident, through Accessibility, with no SIP change and
no extra process. It is off by default.

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4"]

[tiling.gaps]
inner = 8
outer = 8
```

Saving the file starts tiling: every window Flash's window catalog knows
joins the workspace its display shows and takes a tile there. Turning it off
again, or quitting Flash, brings every hidden window back on screen. Run
`flash config check` to validate the section; `config.default.toml` lists
every key.

No key is bound by default. The [layer](layers.md) below is a starting
point, entered with `alt+t` and left with Escape:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; layers need them
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+t" = ["flash", "mode", "layer", "--name=tile"]

[mode.layers.tile.mappings]
"h" = ["flash", "window", "focus", "--direction=left"]
"j" = ["flash", "window", "focus", "--direction=down"]
"k" = ["flash", "window", "focus", "--direction=up"]
"l" = ["flash", "window", "focus", "--direction=right"]
"shift+h" = ["flash", "tile", "move", "--direction=left"]
"shift+j" = ["flash", "tile", "move", "--direction=down"]
"shift+k" = ["flash", "tile", "move", "--direction=up"]
"shift+l" = ["flash", "tile", "move", "--direction=right"]
"r" = ["flash", "tile", "layout", "--type=toggle"]
"v" = ["flash", "tile", "layout", "--type=vertical"]
"s" = ["flash", "tile", "layout", "--type=horizontal"]
"f" = ["flash", "tile", "fullscreen"]
"<space>" = ["flash", "tile", "float"]
"<equal>" = ["flash", "tile", "balance"]
"<minus>" = ["flash", "tile", "resize", "--dimension=smart", "--amount=-50"]
"<plus>" = ["flash", "tile", "resize", "--dimension=smart", "--amount=50"]
"1" = ["flash", "workspace", "switch", "--name=1"]
"2" = ["flash", "workspace", "switch", "--name=2"]
"shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"shift+2" = ["flash", "workspace", "move_window", "--name=2"]
"tab" = ["flash", "workspace", "back_and_forth"]
```

Every command is also a CLI call (`flash tile move --direction=left`) and a
command-line entry (`:tile move --direction=left`).

## The tree

A workspace's windows are the leaves of a tree. Each container lays its
children out as `tiles`, side by side, or as an `accordion`, stacked with
each one showing `accordion_padding` points of the others, and runs
`horizontal` or `vertical`. Two rules keep the tree simple after every
change, as in AeroSpace: a container left with one child is replaced by
that child (the root may hold a single window), and a container nested in
another runs the other way.

A new window takes a tile after the focused window, in its container, on the
workspace its display shows. A workspace's root runs along the display's long
side unless `orientation` says otherwise; `layout` sets its first layout.

| Command | What it does |
| --- | --- |
| `tile move --direction=<left\|right\|up\|down>` | Moves the focused window past its neighbor; at the edge of its container, out into the parent; at the edge of the workspace, the root turns to that axis |
| `tile swap --direction=…` | Swaps the focused window with the nearest tiled window in that direction |
| `tile join --direction=…` | Puts the focused window and its neighbor in a new container that runs the other way |
| `tile layout --type=<tiles\|accordion\|horizontal\|vertical\|toggle>` | Sets the focused window's container; `toggle` switches tiles and accordion |
| `tile resize --dimension=<width\|height\|smart> --amount=<points>` | Grows (or, negative, shrinks) the focused window along an axis; `smart` is its container's |
| `tile balance` | Gives every window of the workspace an equal share |
| `tile flatten` | Puts every window of the workspace in one container |
| `tile float` | Takes the focused window out of the tree, or tiles it again |
| `tile fullscreen` | Makes the focused window fill its workspace within the outer gaps, or ends it |

Moving focus is `window focus --direction=`, which reads the windows' frames
([windows](windows.md)), so it crosses containers and displays the way the
tiles look. Windows on hidden workspaces are never its targets.

`[tiling.gaps]` sets `inner` (between windows) and `outer` (to the edges of
the usable frame, the Dock and the [status bar](statusbar.md) band left out);
`inner_horizontal`, `inner_vertical`, `outer_left`, `outer_right`,
`outer_top` and `outer_bottom` override one side. Each is 0–200 points.

## Workspaces

Every display shows one workspace. `workspaces` lists the ones always
offered, in order, for `#{flash.workspaces}` and `workspace next`; others
are made by `workspace switch --name=<name>` and dropped once they are
empty and hidden. A name is one word, at most 32 characters.

| Command | What it does |
| --- | --- |
| `workspace switch --name=<workspace>` | Shows the workspace and focuses its last focused window: where it is already shown, on its pinned display, else on the focused display |
| `workspace next`, `workspace previous` | The next or previous listed workspace on the focused display, wrapping, skipping the ones other displays show |
| `workspace back_and_forth` | The workspace focused before this one |
| `workspace move_window --name=<workspace>` | Sends the focused window there, hidden unless a display shows that workspace |
| `workspace move_to_monitor --direction=<next\|previous>` | Shows the focused workspace on the next or previous display, swapping it with the one shown there; a pinned workspace stays put |
| `workspace list` | One line per workspace: its name, its window count, the display showing it, `*` on the focused one |

`[tiling.monitors]` pins a workspace to one display: `"main"`, `"secondary"`
(the first other display, left to right), or a display's number from 1,
counted left to right:

```toml
[tiling.monitors]
"9" = "secondary"
"web" = 1
```

macOS has no API for a third-party app to switch or create Spaces without
SIP changes, so Flash emulates workspaces as AeroSpace does: the windows of a
hidden workspace are moved off the bottom-right corner of the display it
was last shown on, with their size kept, or off the bottom-left corner when
another display lies beyond the bottom-right. macOS keeps a sliver of every
window on screen, about a point here; arrange displays so each has a free
bottom corner, and a Dock that hides at the bottom covers the sliver. An app
that pulls its parked window back on screen gets it parked again once;
one that insists keeps it there.

Focusing a hidden window (Command-Tab, `window switch`, a click in the Dock)
shows its workspace on its pinned display or the focused one, as in
AeroSpace.

### Display changes

A workspace remembers the display it was last shown on, by display UUID.
When a display goes away, its workspace is hidden with its windows; when the
display comes back, it shows that workspace again. A newly connected display
shows the first free workspace from `workspaces`, a workspace pinned to it,
or a new numbered one. Displays are read again on every pass of the
[display recovery](windows.md#display-changes) Flash already runs, so a
resolution or Dock change retiles at once.

## Floating windows and rules

Dialogs, sheets and other windows that are not `AXStandardWindow` float:
Flash keeps them in their workspace, hides and shows them with it, and never
resizes them. `tile float` floats a tiled window or tiles a floating one.

`[[tiling.rules]]` decide for a new window, the first match winning:

```toml
[[tiling.rules]]
bundle_id = "com.apple.finder"
title_contains = "Info"   # optional, letter case ignored
float = true

[[tiling.rules]]
bundle_id = "com.tinyspeck.slackmacgap"
workspace = "chat"
```

A rule applies once, when Flash first sees the window, like the
[placement rules](windows.md#place-windows-as-they-appear), so a window that
sets its title late may miss a `title_contains` rule. While tiling is on,
`[[window_rules]]` and window layout tracking stand aside: tiling owns where
windows go.

## The mouse and other tools

Dragging a tiled window by hand and letting go with the pointer over
another tile of its workspace swaps the two, as yabai's
`mouse_drop_action swap` does; letting go on another display moves it to
the workspace shown there. Anywhere else, once the mouse button is up, it
goes back to its tile. The drop is judged by where the pointer is when the
button comes up, against the tiles as they were laid out, so a window
dropped on its own tile, in a gap, or on a sibling of its accordion stays
put.

A tiled window resized by hand keeps the edge you dragged: the split that
edge sits on moves, the window across it giving or taking the difference,
as dragging a border does in i3, and the rest of the workspace stays. An
edge at the workspace's boundary has nothing across it and snaps back; so
does a window in an accordion, whose siblings share its area. Each side of
a split keeps at least 5% of it.

A floating window keeps whatever frame you give it. `window move` on a
tiled window is undone the same way; float it first. Flash's tiling and
another tiler (AeroSpace, yabai, Amethyst, Rectangle's automatic layouts)
fight over the same windows: run one.

## The bar and plugins

`#{flash.workspace}` is the focused workspace and `#{flash.workspaces}` every
listed one, space separated; both are empty while tiling is off.

```toml
[statusbar]
template = "#[align=left]#[pill] #{flash.workspace} #[nopill] #{flash.workspaces}#[align=right]%H:%M"
```

Plugins and [monitors](monitors.md) that listen for `core:workspace.changed`
receive `{workspace, previous?, workspaces}` whenever the focused workspace
changes, the equivalent of AeroSpace's `exec-on-workspace-change` and
yabai's `space_changed` signal.

## Compared with AeroSpace and yabai

| Concept | AeroSpace | yabai | Flash |
| --- | --- | --- | --- |
| Layout model | i3-like tree: tiles and accordion, h/v | bsp, stack, float per Space | AeroSpace's tree: tiles and accordion, h/v |
| Normalization | Flatten one-child containers, opposite orientation | Not a tree of containers | The same two rules, always on |
| Workspaces | Emulated, windows parked in a bottom corner | Native Spaces | Emulated, parked in a bottom corner |
| Multi-monitor | One workspace pool, `workspace-to-monitor-force-assignment` | Spaces per display | One pool, `[tiling.monitors]` (main, secondary, index) |
| Floating | Dialog heuristics, `on-window-detected` | `yabai -m rule` | Non-standard windows, `[[tiling.rules]]` |
| Gaps | `gaps.inner.*`, `gaps.outer.*` | `window_gap`, padding | `[tiling.gaps]` |
| Binding modes | `[mode.*.binding]` | skhd modes | [Layers](layers.md) |
| Workspace events | `exec-on-workspace-change` | Signals | `core:workspace.changed`: monitors, `flash events watch` |
| Bar | External (SketchyBar) | External | Built in: `#{flash.workspace}` |
| CLI | `aerospace …` | `yabai -m …` | `flash tile …`, `flash workspace …` |
| Mouse | Drag to move between monitors | Modifier drag and resize, drop to swap | Drag between displays, drop on a tile to swap, resize by edge |

### Out of scope, and why

- **Anything yabai needs SIP for**: creating, moving or destroying Spaces,
  window shadows, opacity, animations, scratchpads, window layers, sticky
  windows and arbitrary picture-in-picture. Those come from a scripting
  addition injected into Dock.app with System Integrity Protection partly
  off; Flash runs on a stock, managed Mac and never asks for that.
- **Tiling native Spaces.** Accessibility lists only the active Space's
  windows and no public API moves a window between Spaces, so a workspace is
  Flash's own, as in AeroSpace. One native Space per display works best;
  windows on other Spaces join once Flash sees them.
- **Reading pixels.** Flash never captures the screen, so there are no
  window thumbnails or animated transitions drawn from window contents.
- **A second process.** The CLI is the resident's `flash` command, over the
  resident's one [socket](ipc-protocol.md) like every other command;
  `flash events watch --name=core:workspace.changed` streams the workspace
  changes yabai's signals and AeroSpace's `exec-on-workspace-change` report.

## Limits

- Apps that refuse a frame (a minimum size, a terminal snapping to its cell
  grid) keep their own; the other tiles do not grow around them.
- Native full-screen windows belong to macOS: leave full screen before
  tiling a window, or use `tile fullscreen`.
- Mission Control shows parked windows small, at the display's corner;
  "Group windows by application" in Mission Control's settings helps.
- Restarting Flash forgets the trees: windows tile again in the order the
  catalog lists them.
- A hidden app's windows (Command-H) keep their tiles, leaving the space
  empty until the app is shown again; a minimized window leaves its tile and
  takes a new one when it comes back.

## Not yet

These are planned, in roughly this order:

- **Modifier-drag move and resize** as in yabai, from anywhere in a window.
- **Persistence across restarts**: each workspace's tree and which display
  showed it, saved on quit and matched to windows by app and title on launch.
- **Per-display gaps** (AeroSpace's `monitor.<pattern>` values) and
  accordion padding per workspace.
- **`workspace summon`** (bring a workspace to the focused display from
  another) and **focus follows mouse**.
- **Window queries**: `workspace list --format=json` with each workspace's
  windows, for scripts.
- **One window catalog**: the window switcher and display recovery read
  their own snapshots today; tiling already reads the navigation catalog,
  and the other two should too.

## Keeping layouts across restarts

With `[tiling] persist = true` (the default), Flash saves workspace trees,
weights, floating windows and display assignments in
`~/Library/Application Support/Flash/tiling.json`. It restores windows by app
and window number, falling back to a title hash and the nearest previous frame
when an app has restarted. Unmatched windows join the workspace shown on their
display. Explicit placement and floating rules take precedence.

As windows arrive, the stored split takes shape again. A tile command or manual
move/resize ends restoration for that workspace, preserving the new layout.
Writes are atomic, private, and coalesced on the window layout queue. A malformed
file is ignored. Set `persist = false` to stop saving and remove the saved layout.
Tiling itself stays off until you set `enabled = true`.
