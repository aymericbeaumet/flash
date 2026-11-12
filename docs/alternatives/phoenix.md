# Flash and Phoenix

[Phoenix](https://github.com/kasper/phoenix) is "A lightweight macOS window
and app manager scriptable with JavaScript": you write `~/.phoenix.js` (or
TypeScript compiled to it), bind keys and system events to functions, and
drive screens, Spaces, the mouse, apps and windows from a small API, with
modals for text and input, notifications, storage and external tasks. It
lives in the menu bar or as a background daemon. Phoenix is MIT
Objective-C and JavaScript by Kasper Hirvikoski, about 4,500 GitHub stars.
The current release, 4.0.1 from June 2024, needs macOS 10.14 or later; the
unreleased 5.0.0 on `master` (last commit August 2025) raises that to macOS
11 and drops moving windows between Spaces on recent macOS, which Apple
closed to third-party apps.

Phoenix users write their window manager; Flash users configure one. The
two meet where Phoenix runs `flash`.

| | Phoenix | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 10.14+ (4.0.1) | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Model | A JavaScript program: `Key`, `Event`, `Window`, `Screen`, `Space`, `App`, `Mouse`, `Modal`, `Task`, `Timer`, `Storage` | Commands and declarative tables: mappings, `[[window_rules]]`, monitors, opt-in tiling |
| Windows | Any frame you compute, neighbours by direction, focus, minimize, full screen, close; Spaces queries | Named positions, proportional frames, display moves, focus by direction, minimize, restore, close, native full screen, slots kept through display changes |
| Events | Apps, windows, screens, Spaces, mouse, sleep and wake, as callbacks | [Monitors](../monitors.md#runs-and-events) on apps, focus, displays, Spaces, sleep, idle, USB and times of day, each running a command |
| Configuration | `~/.phoenix.js`, reloaded on change | One TOML file, live reload, `flash config check` |
| Maintenance | 4.0.1, June 2024; 5.0.0 unreleased, last commit August 2025 | 1.1.0, October 2026 |

## Where Phoenix is stronger

- **It is a program.** A key handler can look at the screen, count the
  windows, read storage and decide where each one goes; a layout is a
  function. Flash has no scripting language: a mapping runs one command,
  and a monitor runs a command list.
- **Window events.** `windowDidOpen`, `windowDidMove`, `windowDidResize`
  and `windowDidClose` reach your code. Flash's monitors see apps, focus
  and displays; for new windows it has `[[window_rules]]`, which match by
  bundle ID and title and place a window once.
- **Modals and input.** `Modal.build` draws text anywhere and can ask for
  input; Flash's surfaces are fixed (the centred alert, the bar, popups).
- **Mouse events** (`mouseDidMove`, clicks and drags) as callbacks.
- **Older macOS**, from 10.14 with the current release.

## Where Flash is stronger

- **Nothing to write.** Window slots, rules, display recovery and focus by
  direction are there on the first day, validated by `flash config check`
  before they run.
- **Layouts that survive display changes.** A window in a slot or a
  proportional frame keeps it when displays come and go, and returns to its
  own display ([display changes](../windows.md#display-changes)); in
  Phoenix you handle `screensDidChange` yourself.
- **Actively maintained**, with hints, NORMAL mode, the flashlight, the bar,
  widgets, popups and plugins in the same process.
- **Plugins in any language** over JSON lines, sandboxed by default, for
  what a mapping cannot express.

## Flash features you might like

- `window move --x=10% --y=10% --width=80% --height=80%` does the frame
  arithmetic you would write against `screen.flippedVisibleFrame()`.
- `[[window_rules]]` replace the common `windowDidOpen` handler that moves
  an app's new window to its place.
- A monitor on `core:displays.changed` or `core:system.woke` runs any
  command, Phoenix's `screensDidChange` and `deviceDidWake` as
  configuration.
- `window switch` (`:ls`) lists every window with a hint label, without a
  modal of your own.

## Moving from Phoenix

| Phoenix | Flash |
| --- | --- |
| `Key.on('h', ['alt', 'cmd'], …)` | `"alt+cmd+h" = [...]` in `[mode.all.mappings]` |
| `window.setFrame(…)` from the screen's visible frame | `window move --x=…% --y=…% --width=…% --height=…%` |
| `window.maximise()` | `window move --position=maximized` |
| `window.minimise()`, `unminimise()` | `window minimize`, `window restore` |
| `window.setFullScreen(true)` | `window fullscreen --state=on` |
| `window.close()` | `window close` |
| `window.focusClosestNeighbour('west')` | `window focus --direction=left` |
| Moving a window to another screen | `window move --screen=+1` |
| `App.launch('Safari')`, `app.focus()` | `app open --name=Safari` |
| `Event.on('windowDidOpen', …)` placing a window | `[[window_rules]]` with `bundle_id`, `title_contains` and a `position` |
| `Event.on('screensDidChange')`, `'spaceDidChange'`, `'appDidLaunch'`, `'deviceDidWake'` | Monitors on `core:displays.changed`, `core:space.changed`, `core:apps.launched`, `core:system.woke` |
| `Phoenix.notify('…')` | `notify send --title=… --body=…` |
| `Modal.build({ text: … })` | `alert show --message=…` |
| `Mouse.move(point)` | `mouse warp --area=window --edge=center` and the other edges |
| `Task.run(path, args, …)` | A mapping or monitor whose argv is that program |
| `Space` methods, `space.moveWindows` | Not available; with `[tiling]` on, `workspace move_window` |
| `Timer.every(…)` | Not available as a timer; a monitor on `core:clock.minute` with `at` for times of day |
| `Storage`, custom logic in a handler | Not available; a plugin or a script |

A typical `.phoenix.js` start, as configuration:

```toml
[mode.all.mappings]
"alt+cmd+h" = ["flash", "window", "move", "--position=lefthalf"]
"alt+cmd+l" = ["flash", "window", "move", "--position=righthalf"]
"alt+cmd+k" = ["flash", "window", "move", "--position=maximized"]
"alt+cmd+j" = ["flash", "window", "move", "--x=10%", "--y=10%", "--width=80%", "--height=80%"]
"alt+cmd+n" = ["flash", "window", "move", "--screen=+1"]
"alt+ctrl+h" = ["flash", "window", "focus", "--direction=left"]
"alt+ctrl+l" = ["flash", "window", "focus", "--direction=right"]

[[window_rules]]
bundle_id = "com.apple.Terminal"
position = "lefthalf"

[monitors.docked]
event = "core:displays.changed"
message = "Displays changed"
```

## Using both

Keep the parts of `.phoenix.js` that are really programs, and let them call
Flash for the rest. `Task.run` needs an absolute path: the CLI inside the
app is `/Applications/Flash.app/Contents/MacOS/flash`, and a Homebrew
install also puts `flash` on your `PATH`.

```javascript
const flash = (...args) =>
  Task.run('/Applications/Flash.app/Contents/MacOS/flash', args, () => {});

Key.on('h', ['alt', 'cmd'], () => flash('window', 'move', '--position=lefthalf'));
Event.on('screensDidChange', () => flash('alert', 'show', '--message=Displays changed'));
```

Give each chord one owner: a key both Phoenix and Flash bind works for only
one of them, and `flash resident doctor` lists any Flash hotkey another app
holds. Leave Flash's `[tiling]` off if Phoenix arranges windows: a tiled
window goes back to its tile after any other tool moves it.

*Checked 2026-10-23 against the Phoenix
[README](https://github.com/kasper/phoenix),
[changelog](https://github.com/kasper/phoenix/blob/master/CHANGELOG.md),
[API documentation](https://kasper.github.io/phoenix/) and
[releases](https://github.com/kasper/phoenix/releases).*
