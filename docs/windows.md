# Window navigation and placement

Flash can focus a nearby window, place the focused window, and apply an
opt-in placement rule when a matching window appears. Window operations use
macOS Accessibility; apps that do not expose a usable window may not respond.

For automatic tiling and workspaces, AeroSpace-style, see
[tiling](tiling.md); while it is on, it owns where windows go and the
placement rules below stand aside.

## Focus a nearby window

```sh
flash window focus --direction=left
flash window focus --direction=right
flash window focus --direction=up
flash window focus --direction=down
```

The direction is relative to the focused window. These commands can also be
used in `[mode.*.mappings]`.

```sh
flash window focus --direction=next      # the window below the focused one in the stacking order
flash window focus --direction=previous  # the one above it
flash window focus --direction=behind    # the frontmost window below it that it overlaps
```

The stacking order is WindowServer's on-screen window list, read on the main
thread and matched to the cataloged Accessibility windows by owner and frame;
`next` and `previous` wrap around it.

```sh
flash window next      # the focused app's next window (NORMAL ]w)
flash window previous  # its previous window (NORMAL [w)
```

These cycle only the focused app's windows, through Accessibility rather than
the app's Cmd-` shortcut, so apps without one cycle too. Raising a window
lifts it to the top of the stacking order, so a run of presses keeps the
order its first press read, wrapping, until a window opens or closes; a press
made before focus reports the last raise continues from that raise.

## Switch to any window

```sh
flash window switch
```

To find a window by typing instead, `:flashlight @windows <words>` searches
the same list by title and app name ([flashlight](flashlight.md)).

`window switch`, or `:ls` (`:buffers`, `:files`) on the command line, opens
the window switcher: every window of every app, most recently used first, minimized windows,
hidden apps' windows and windows on other Spaces included. Each row shows
the app's icon and name, the window's title, a hint label, and a badge when
the window is `minimized`, its app `hidden`, or the window on an
`other Space`. There are no thumbnails: Flash never reads screen
pixels, so it has no picture of a window to show.

| Key | What it does |
| --- | --- |
| A row's hint label | Switch to that window at once |
| Tab, Down or Right | The next window |
| Shift-Tab, Up or Left | The previous window |
| Return | Switch to the selected window |
| Escape, or a click | Close the list; nothing changes |

The list opens on the window you were in before this one, so Return flips
between the two most recent windows, and it stays up until a label, Return
or Escape. No chord opens it by default: like every unmapped chord,
Option-Tab is swallowed in NORMAL and reaches the app in INSERT, and
Command-Tab stays macOS's app switcher. Bind it to a key like any command:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>w" = ["flash", "window", "switch"]
```

`window last` skips the list: it focuses the window you were in before this
one straight away, as tmux's `last-window` does. NORMAL's `ctrl+w p` runs
it, as Vim's previous-window key, and pressing it again flips back.

Choosing a window unhides its app, unminimizes the window, raises it as its
app's main window and activates the app, bringing that one window forward
rather than all of the app's. A window on another Space takes you to that
Space when macOS follows the activation there (System Settings, Desktop &
Dock, "When switching to an application, switch to a Space with open windows
for the application"). The window is checked first: one that closed since the
list opened focuses nothing, never another window of the app. The mode is
unchanged: NORMAL stays NORMAL and INSERT stays INSERT.

The list is prepared before you ask for it, so it draws within a frame of the
key: Flash records which window has focus as macOS reports each focus change
and app activation, and reads each app's windows through Accessibility on a
background queue: at launch, when an app launches, when one of its windows
opens, closes, is minimized or retitled (for the apps Flash observes, every
app focused since it started), and when the active Space changes. Opening
the switcher reads only that memory; nothing is scanned on the keypress. Two
limits follow from what macOS exposes:

- Accessibility lists an app's windows on the active Space, plus its
  minimized ones. A window on another Space is listed once Flash has seen it
  since it started: you focused it, or its Space was active.
- Flash's keyboard tap sees key presses, not modifier changes, so releasing
  a modifier does not choose a window. The list stays up until a label,
  Return or Escape, which is why no hold-to-cycle chord opens it by default.

## Place the focused window

`window move` supports named positions, a complete proportional frame, and
relative display moves:

```sh
flash window move --position=lefthalf
flash window move --x=10% --y=10% --width=80% --height=80%
flash window move --screen=+1
```

`--screen=+1` moves the window to the next display as they are arranged,
left to right then top to bottom, wrapping after the last; `--screen=-1`
walks back. See [commands](commands.md) for the available positions and frame
semantics. `window minimize`, `window restore`, and `window fullscreen` control
native window state.

### How windows move

`window move`, placement rules and display recovery place a window the same
way, through Accessibility, on a queue of their own so a slow app never holds
the keyboard:

1. Flash takes the frontmost app's focused window (else its main window, else
   its first) in one request, and reads the window's frame.
2. It computes the slot from the display's usable frame, less any status bar
   band, and writes only what differs: nothing when the window is already
   there; the position alone between slots of one size (left half to right
   half); the size alone between slots sharing a top-left corner (maximized
   to left half); otherwise both, shrinking before moving or moving before
   growing, so the window never hangs off the display where macOS would clamp
   it. A window arriving from another display gets size, position, then size
   again, since its first resize can be clamped to the display it leaves.
3. It reads the frame back and rewrites what is still off, at most twice. A
   window its app keeps elsewhere (a terminal sizing to its cell grid, a
   dialog with a minimum size) is logged as `[window] unconverged`.

Apps with `AXEnhancedUserInterface` on animate programmatic resizes, slowly.
Flash turns it on for Chromium, Electron and Flutter apps to read their
content, so it switches it off around the writes and back on after, then
checks the frame once more, since some apps lay the window out again when it
returns. Firefox's equivalent mode is switched off before any write (see
[architecture](architecture.md)). An app that does not answer Accessibility
costs one timeout (1.5 s), not one per attribute.

Each move logs `[window] placed` at `debug` with the writes it took and
its timings; `mise run bench:log-summary` tabulates them by app (see
[performance](performance.md#window-moves)).

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
relative display offset with the same meaning as `window move --screen`. Run
`flash config check` to validate the rules.

Placement rules are opt-in and event-driven. Flash checks each window once
against the current configuration, when it first sees it: a window no rule
matches then stays where you put it, even if its title later changes to one a
rule names, and moving it by hand afterward never fights an automatic resize.
An app that sets its window's title only after the window appears may miss a
`title_contains` rule for that reason; a rule without `title_contains` still
places it. Saving the config evaluates existing
non-minimized windows with frames on connected displays against the changed
rules too. macOS Accessibility does not identify which Space each window is on.

## Display changes

A window in a named position (`lefthalf`, `maximized`, the quarters,
`centered`) or a proportional frame keeps that layout through every display
change: a display unplugged or plugged in, displays rearranged, a resolution
or scale changed, the lid closed or opened, displays sleeping and waking, and
the Dock or the status bar changing the usable area.

- While the display it was placed on is away, the window keeps its layout on
  the display macOS moved it to.
- When that display comes back, the window goes back to it, in the same
  layout, as macOS returns windows to a reconnected display. Displays are
  told apart by their UUID, so one that reconnects under a new display ID is
  still the same display.
- Placing the window again, or moving it to another display, makes that
  display its own.
- Moving or resizing it by hand to any other frame ends the layout: Flash
  leaves a free-form window where you put it.

The layout follows every window Flash placed (`window move`, a placement
rule), and every window found sitting in a slot, placed before Flash started
or by another tool, once Flash reads it: at
launch, when an app launches or quits, when the active Space changes, and
when the window is focused.

Flash applies the layouts in passes from 80 ms to 3 s after macOS reports the
change, reading the displays again each time: AppKit reports before its
screens settle, and apps keep moving their windows for seconds after a
reconnect. A change while the Mac sleeps or the screen is locked waits for
the session, then applies as measured from the displays from before it. A
minimized window takes its layout when it is focused again.

A window in no layout that no longer fits a connected display is scaled onto
the display it lands on: macOS moves background windows itself and often
leaves the frontmost one at the old size. A window parked off every display
stays there.

Limits: Accessibility lists only the active Space's windows, so a window on
another Space is followed only once Flash has seen it, and an app that moves
its window again after the last pass keeps that frame. Native full screen
windows belong to macOS.
