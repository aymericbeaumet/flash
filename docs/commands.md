# Commands

Run `flash <verb>` from a terminal or put the same argv in a mapping. Open
`:help` or `flash help_show` for the installed command inventory.

```bash
flash mouse_target                       # current-context click (terminal links add Shift)
flash mouse_target --modifiers=cmd+shift # new-context gesture for every target
flash mouse_target --secondary           # right-click
flash mouse_target --double              # double-click
flash mouse_target --middle              # middle-click
flash mouse_target --triple              # triple-click
flash mouse_target --move                # move the pointer only
flash mouse_target --drag                # pick a grab point, then a drop point
flash mouse_grid --drag                  # drag between two grid positions
flash mouse_target --select              # click a start point, shift-click an end point
flash mouse_grid --select                # select text between two grid positions
flash mouse_target --multi               # click several targets; Escape ends the session
flash mouse_repeat                       # re-click the last committed point
flash mouse_target --adjust              # refine the click point before committing
flash mouse_target --search              # type visible text to pick the target (seek & click)
flash mouse_target --scope=screen        # hints across every app on the screen
flash mouse_dock                         # hint the Dock's items
flash mouse_statusbar                    # hint the menu-bar status items
flash mouse_pointer                      # freestyle cursor control (hjkl, m/,/. click, v drag)
flash scroll_target                      # pick which scroll area the scroll keys drive
# In the flashlight, "@menus print" finds and runs the frontmost app's menu items.
flash mouse_grid                         # target any screen position (keyboard-shaped grid)
flash mouse_grid --bisect                # halve the screen with h/j/k/l, quarter it with y/u/b/n
flash mouse_grid --zoom-to-depth=2       # start two steps deep under the pointer
flash app_open --name=Firefox            # open or focus an app
flash window_move --position=lefthalf    # tile the focused window
flash window_move --x=10% --y=10% --width=80% --height=80% # proportional frame
flash enter_command_mode                 # open the command line
flash leave_mode                         # leave insert or close the command panel
flash help_show                          # show built-in help
flash plugins                            # inspect plugins
flash about                              # open the About Flash window
flash quit                               # stop the resident app
```

## Status, doctor and config checks

Three CLI queries report instead of act. They are not verbs: no mapping can run
them, and plugins cannot register verbs with their names.

```bash
flash status                 # mode, key capture, input source, config, plugins
flash status --json          # the same as versioned JSON
flash doctor                 # check permissions, capture, config, hotkeys, plugins
flash doctor --json
flash config_check           # validate the active config file, offline
flash config_check --file=~/dotfiles/flash.toml
```

`flash status` asks the running resident. `--json` prints this object; the keys
are fixed for `"schema": 1`:

| Key | Value |
| --- | --- |
| `schema` | `1` |
| `version`, `build` | The app's version and build number |
| `mode` | `disabled`, `insert`, `normal`, `command` or `terminal` |
| `hint_session` | `idle`, `discovering`, `labels`, `grid`, `search`, `adjusting` or `pointer` |
| `focused_app` | The focused app's bundle identifier, or `null` |
| `accessibility` | Whether Flash has the Accessibility grant |
| `capture` | How hint keys arrive: `tap`, or `key_window` without a tap or under secure input |
| `secure_input` | Whether secure input is on (a password field has focus) |
| `input_source` | The selected input source's ID |
| `keyboard_layout` | `[app] keyboard_layout` as configured |
| `reference_layout` | The layout keys are read on, or `null` while they read as typed |
| `config_path`, `config_diagnostics` | The config file and how many problems it has |
| `plugins` | `{ "loaded", "ready", "error" }` counts |
| `statusbar`, `autostart` | `[statusbar] enabled` and `[app] autostart` |

`flash doctor` runs every check `:doctor` runs and prints one line per check:
Accessibility, the keyboard tap, secure input (and which app holds it), the
app's code signature (an ad-hoc signature can lose the Accessibility grant on
update), other Flash residents, config diagnostics, hotkeys another app
registered first, plugin health, hint and grid keys the current keyboard layout
cannot type, and Screen Recording when the `screenshot` plugin runs. It exits 1
when a check fails; warnings do not change the exit code.

`flash config_check` does not contact the resident. It loads the bundled
defaults and the file (`--file`, else the path Flash would load) exactly as the
resident does, prints each problem as `path:line:col: message`, and exits 1
when there is any, or 2 when the file cannot be read. Environment overrides are
not applied.

Arguments use `--name=value` for values and bare flags such as `--secondary` or `--restore-mode` for booleans.

`mouse_grid` takes the click flags of `mouse_target` except `--adjust` and
`--search`, plus `--bisect` and `--zoom-to-depth=N` (N ≥ 1), which combine with
every click flag. The screen splits like the left half of the keyboard; see
[normal mode](normal-mode.md#mouse-grid) for its keys.

`window_move` accepts named positions (`topleft`, `topright`, `bottomleft`,
`bottomright`, `lefthalf`, `righthalf`, `tophalf`, `bottomhalf`, `maximized`,
or `centered`) or a complete proportional frame. Proportional frames require
`--x`, `--y`, `--width`, and `--height` together, each with a `%` suffix. `x`
and `y` are offsets from the top-left of Flash's usable screen area, including
its status-bar reservation on each display where the bar is configured to
render. Flash retains that geometry as window intent: an explicit
`--screen=+1` move, a resolution or usable-area change, and display
attachment/removal all reapply it against the destination screen. Every slot
lands on whole points, each edge rounded on its own, so neighbouring slots share
an edge. A display change that arrives while the Mac is locked or asleep (a wake
at a different desk) is applied once the session is back; a window whose frame
could not be read then is restored as soon as it can be, or when focused. A
window already sitting in a proportional frame one of your `window_move`
mappings declares is recognized after Flash restarts.
