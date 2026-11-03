# Flash and Bartender

[Bartender](https://www.macbartender.com) ("Own your menu bar") is the
long-running commercial menu bar manager: it hides, reveals, reorders,
spaces and styles the native menu bar's items, shows them on triggers, and
lets you reach them from the keyboard. Ben Surtees wrote it and sold it in
early 2024 to Applause Group, a sale users learned of only from a changed
signing identity, and which he explained and apologised for in June 2024
([TidBITS](https://tidbits.com/2024/06/05/bartender-developer-explains-and-apologizes-for-quiet-acquisition/)).
Bartender 7, announced on 14 September 2026, is built for macOS 27 and costs
$24.99 once; its licence also activates Bartender 6, the version for macOS
26 and 15. Bartender Pro, $19.99 a year, covers every future version and
adds Top Shelf, a shelf at the notch with clipboard history, file storage,
Now Playing and widgets. New users get a four-week trial.

Flash takes a different route with the same band of the screen: its
[status bar](../statusbar.md) draws there, and the native menu bar
auto-hides beneath it, every item in place, until the pointer reaches the
top edge.

| | Bartender | Flash |
| --- | --- | --- |
| License, price | Closed; Bartender 7 $24.99 once, Bartender Pro $19.99 a year; four-week trial | MIT, free |
| Platforms | Bartender 7: macOS 27; Bartender 6: macOS 26 and 15 | macOS 13+ |
| Permissions | Accessibility; Screen Recording optional in Bartender 7 (app icons stand in for item images without it) | Accessibility; status items are located from WindowServer geometry, never captured |
| The native menu bar | Hidden items, the Bartender Bar panel, reordering, spacing, spacers and labels; notch handling; styles from glass to gradients; presets swapped by hotkey, trigger or display setup | Auto-hidden as a whole while Flash's bar is on; ordered by macOS |
| Triggers and custom items | Show items on battery, Wi-Fi, location, time or a script; items built from scripts, with click actions | Conditionals in the template, polled or pushed sources, event monitors, click ranges and popups |
| Keyboard | Command Bar: search and trigger items, switch presets; quick reveal and custom hotkeys | `mouse menubar` labels, `@menus` search, hints on the bar, NORMAL mode |
| Automation | Shortcuts, AppleScript, Siri | `flash <topic> <action>` from any shell; `flash status set` |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | Bartender 7, September 2026; Applause Group | 1.1.0, October 2026 |

## Where Bartender is stronger

- **The most complete native menu bar manager.** Triggers, presets that
  swap the whole layout when you dock or undock, spacing, spacers and
  labels, a separately themed Bartender Bar, and handling for the items the
  notch would cover. Flash manages none of that: it hides the native bar as
  a whole, never one item, and has no presets.
- **The Command Bar finds items by name**, runs them and switches presets
  from one hotkey. Flash labels the items that are on screen; it cannot
  reveal an item another app keeps hidden.
- **System automation.** Shortcuts, AppleScript and Siri can drive it, and
  its triggers include location and time without writing anything.
- **Top Shelf** in Pro: a notch shelf for files and AirDrop, Now Playing,
  calendar alerts, widgets and AI agent progress. Flash draws nothing at the
  notch and has no file shelf.
- **A product timed to macOS releases**, with a company behind it and
  Bartender 7 built for macOS 27; it now keeps its full feature set without
  Screen Recording.

## Where Flash is stronger

- **Free, open source, and a file.** The bar, its sources, popups, click
  actions and keys live in `flash.toml`, which you can diff, keep in your
  dotfiles and check with `flash config check`. Bartender's setup lives in
  its settings window.
- **Nothing to hide.** With `[statusbar] enabled = true` the band shows
  what your template puts there, and the native items wait under it. There
  is no layout to keep tidy as apps add icons.
- **Triggers as text.** A conditional shows a segment only when it
  matters, and [monitors](../monitors.md) on `core:power.changed`,
  `core:network.changed` or `core:displays.changed` run any command when the
  Mac's state changes, including `flash status set` to change what the bar
  says.
- **A public privacy inventory.** Flash sends no analytics, and
  [privacy](../privacy.md) lists every permission prompt, network
  destination and stored file. Bartender's 2024 change of hands also brought
  the Amplitude analytics framework, added without notice and reported
  removed in 5.0.53 (TidBITS); its current builds are not covered here.
- **The keyboard reaches everything else too**: hints in every app,
  NORMAL mode, the flashlight, windows and popups share the same file.

## Flash features you might like

- `flash status set --name=focus --value=Writing` from a Shortcut's Run
  Shell Script action pushes a value into the bar at once, nothing polled:
  Bartender's Shortcuts trigger, in reverse.
- A source reads a script written for SwiftBar or xbar unchanged with
  `output = "xbar"` ([swiftbar](swiftbar.md)); `[statusbar.click]` binds a
  click on its segment to a URL or a Flash command.
- `!clip` in the flashlight is the clipboard history Bartender Pro puts in
  the Command Bar ([clipboard](../clipboard.md)).
- `#{flash.calendar.next}` shows the next meeting and `calendar join` joins
  it; a monitor on `#{flash.calendar.next_minutes}` with `notify = true`
  posts the reminder to Notification Center
  ([calendar](../calendar.md#an-alert-before-it-starts)).
- `media status` says what the running media apps play, and the volume.

## Moving from Bartender

| Bartender | Flash |
| --- | --- |
| Hidden items, the Bartender Bar | `[statusbar] enabled = true`; reaching the top edge reveals the native bar, every item in place |
| Quick reveal hotkey | Not available; reach the top edge |
| Command Bar search of items | `mouse menubar` labels the items on screen; `@menus` searches the focused app's menu commands |
| Show the battery when unplugged | `#{?#{==:#{flash.plugin.sysinfo.power_state},discharging},…,}` in the template |
| Triggers on Wi-Fi or a display setup | A `[monitors.<name>]` on `core:network.changed` or `core:displays.changed` with a `run` |
| A custom item from a script, with a click action | `[statusbar.sources.<name>]` and a `#[range=user\|<name>]` span bound in `[statusbar.click]` |
| Presets and profiles | Not available: one template per configuration |
| Menu bar styles | `#[pill]`, `#[fg=…,bg=…]` and meters in the template, for Flash's bar |
| Shortcuts and AppleScript actions | `flash <topic> <action>` from Run Shell Script; `flash status set` to push a value |
| Clipboard history in the Command Bar (Pro) | `!clip` |
| Top Shelf files and AirDrop | Not available |

```toml
[statusbar]
enabled = true
template = "#[align=left]#[pill]#{flash.mode}#[nopill]#[align=right]#{?#{==:#{flash.plugin.sysinfo.power_state},discharging},#[popup=power]BAT #{flash.plugin.sysinfo.power_label}#[nopopup] · ,}#{?flash.source.focus,#{flash.source.focus} · ,}%H:%M"

# Pushed, never polled: `flash status set --name=focus --value=Writing`
# from a Shortcut's Run Shell Script action.
[statusbar.sources.focus]

[popup.power]
text = "#{flash.plugin.sysinfo.power_details}"

[mode.all.mappings]
"cmd+ctrl+b" = ["flash", "mouse", "menubar"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

## Using both

They split the work cleanly when Flash's bar is off: Bartender owns the
native menu bar, its triggers and presets, and Flash adds hints, NORMAL mode
and `mouse menubar` on whatever Bartender leaves on screen. Give the
Command Bar and Flash's mappings different chords; Flash binds no chord in
every mode by default except `cmd+ctrl+h` (HOLD).

With Flash's bar on, Bartender still manages the native bar that slides in
at the top edge, but its styles, spacing and presets dress a band Flash
covers most of the time. Keep Bartender if you rely on its triggers for
native items or on Top Shelf; otherwise its job mostly goes away.

*Checked 2026-10-23 against [macbartender.com](https://www.macbartender.com),
the [Bartender 7](https://www.macbartender.com/Bartender7/) and
[Bartender 6](https://www.macbartender.com/Bartender6/) pages, the
[Meet Bartender 7](https://www.macbartender.com/Bartender7/Blog/meet-bartender-7/)
post, [MacRumors](https://www.macrumors.com/2026/05/12/bartender-pro/) on
Bartender Pro, and [TidBITS](https://tidbits.com/2024/06/05/bartender-developer-explains-and-apologizes-for-quiet-acquisition/)
on the 2024 sale.*
