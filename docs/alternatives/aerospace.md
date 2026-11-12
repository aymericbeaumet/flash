# Flash and AeroSpace

[AeroSpace](https://github.com/nikitabobko/AeroSpace) "is an i3-like tiling
window manager for macOS": tree-based tiling, its own emulation of virtual
workspaces, i3-style binding modes, a TOML config and a CLI. It is MIT Swift
for macOS 13+, about 23,000 stars, in public beta (v0.21.3 in July 2026),
needs no SIP change, and is not notarized. Flash's opt-in
[tiling](../tiling.md) follows the same model: the same tree, the same two
normalization rules, workspaces emulated by parking windows in a bottom
corner, one workspace pool across displays.

| | AeroSpace | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility; one private API (`_AXUIElementGetWindow`) | Accessibility; three private interfaces looked up at run time (the Dock's `CoreDockSendNotification`, a `CGS` connection property, gesture event fields), none for windows |
| Windows | Automatic tiling, tiles and accordion layouts, workspaces, multi-monitor pool | Opt-in tiling with tiles and accordion layouts, emulated workspaces and a multi-monitor pool; named positions, proportional frames, placement rules, directional focus when it is off |
| Rules | `on-window-detected`: any command, conditions on app, title, workspace | `[[tiling.rules]]`: float, or a workspace, by bundle ID and title |
| Modes | i3 binding modes in `aerospace.toml` | NORMAL, INSERT, COMMAND, TERMINAL for all input, with per-app actions; i3-style layers in `flash.toml` |
| Hints, bar | None; `exec-on-workspace-change` for bars | Hints in every app, status bar with `#{flash.workspace}`, widgets, popups, `core:workspace.changed` |
| Configuration | TOML, auto-reload option, CLI | TOML, live reload, CLI |
| Maintenance | Beta, releases every few weeks | 1.0.0, October 2026; tiling new since |

## Where AeroSpace is stronger

- **It is a dedicated, proven window manager.** Years of reports behind
  its dialog heuristics and app quirks; Flash's tiling is new and smaller.
- **More of the model**: per-monitor gaps, `on-window-detected` running any
  command, monitor patterns matching a display's name, and `list-windows`
  and `list-workspaces` queries for scripts. Flash's
  [plan](../tiling.md#not-yet) lists what it lacks.
- **A large user base and a documented stability policy** (no SIP, one
  private API, no ricing).

## Where Flash is stronger

- **Everything that is not tiling**: hints, modes, search, bar, widgets,
  popups, plugins, in the same process and file as the tiling.
- **The workspace in the bar without glue**: `#{flash.workspace}` and
  `#{flash.workspaces}` need no `exec-on-workspace-change` script.
- **A notarization path.**
- **Placement rules without a tiling model**, for people who want a few
  windows pinned and the rest left alone: leave `[tiling]` off.

## Moving from AeroSpace

| AeroSpace | Flash |
| --- | --- |
| `focus left` | `window focus --direction=left` |
| `move left` | `tile move --direction=left` |
| `swap left` | `tile swap --direction=left` |
| `join-with left` | `tile join --direction=left` |
| `layout tiles accordion` | `tile layout --type=toggle` |
| `layout horizontal vertical` | `tile layout --type=horizontal` or `--type=vertical` |
| `resize smart +50` | `tile resize --dimension=smart --amount=50` |
| `balance-sizes` | `tile balance` |
| `flatten-workspace-tree` | `tile flatten` |
| `layout floating tiling` | `tile float` |
| `fullscreen` | `tile fullscreen` |
| `workspace 1` | `workspace switch --name=1` |
| `workspace next`, `workspace prev` | `workspace next`, `workspace previous` |
| `workspace-back-and-forth` | `workspace back_and_forth` |
| `move-node-to-workspace 1` | `workspace move_window --name=1` |
| `move-workspace-to-monitor next` | `workspace move_to_monitor --direction=next` |
| `list-workspaces --all` | `workspace list` |
| `persistent-workspaces` | `[tiling] workspaces` |
| `workspace-to-monitor-force-assignment` | `[tiling.monitors]` |
| `gaps.inner.*`, `gaps.outer.*` | `[tiling.gaps]` |
| `accordion-padding` | `[tiling] accordion_padding` |
| `on-window-detected` with `layout floating` or `move-node-to-workspace` | `[[tiling.rules]]` with `float` or `workspace` |
| `[mode.main.binding]`, `mode service` | `[mode.all.mappings]`, a [layer](../layers.md) |

Turn AeroSpace off before turning `[tiling]` on: two tilers fight over every
window. The [tiling guide](../tiling.md) has a layer with these keys.

## Using both

Keep AeroSpace for tiling and workspaces, with Flash's `[tiling]` off. Give
Flash the hint, mode and bar keys, and leave AeroSpace's `alt`-based
bindings alone. AeroSpace pushes the
focused workspace into Flash's bar the moment it changes, with no polling
([pushed status values](../commands.md#pushed-status-values)):

```toml aerospace
# ~/.aerospace.toml
exec-on-workspace-change = ['/bin/bash', '-c',
  'flash status set --name=workspace --value="$AEROSPACE_FOCUSED_WORKSPACE"'
]
```

```toml
# ~/.config/flash/flash.toml
[statusbar.sources.workspace]

[statusbar]
template = "#[align=left]#[pill] #{flash.source.workspace} #[nopill]#[align=right]%H:%M"
```

Flash's placement rules and AeroSpace's tiling will fight over the same
window; use one or the other per app.

*Checked 2026-10-14 against the AeroSpace
[README](https://github.com/nikitabobko/AeroSpace) and
[guide](https://nikitabobko.github.io/AeroSpace/guide); the tiling model
against the guide on 2026-10-23.*
