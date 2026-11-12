# Flash and KRunner

[KRunner](https://userbase.kde.org/Plasma/Krunner) is KDE Plasma's search
and run box, "launched with Alt-F2 or Alt-SPACE": type an application, a
window's title, a virtual desktop or an activity, `= sqrt(4) + 32` for the
calculator, `27.8 km` for conversions, `gg:KDE` or `wp:krunner` for your
web shortcuts, or a shell command to run it. Runners are plugins, and since
Plasma 5 they can be separate programs in any language speaking D-Bus
(`org.kde.krunner1`). The KRunner framework is LGPL, v6.31.0 in October
2026, and the app ships with Plasma 6.8, released on 14 October 2026, the
first Plasma that runs as a Wayland session only. It exists wherever Plasma
does and nowhere on macOS. The [flashlight](../flashlight.md) is the
nearest thing on a Mac, with Spotlight ([launchers](spotlight.md)) as the
system's own.

| | KRunner | Flash |
| --- | --- | --- |
| License, price | LGPL framework, part of Plasma; free | MIT, free |
| Platforms | KDE Plasma (Linux, the BSDs), Wayland | macOS 13+ |
| Finds | Apps, windows, virtual desktops, activities, sessions, and whatever its runners add | Apps, tabs, windows, tmux windows, files by name, notes, reminders, contacts, menus, processes, system actions, emoji, clipboard |
| Answers | Calculator (`=`), unit conversion, more as runners | Arithmetic, units, currencies, colours, world clocks |
| Web | Web shortcuts you define in System Settings (`gg:`, `wp:`) | About 14,500 `!bangs` from DuckDuckGo's and Kagi's lists |
| Commands | Any shell command, in a terminal or as another user | `:` for Flash's commands, `:!cmd` for the shell |
| Extending | C++ runners, D-Bus runners in any language | Plugins in any language over JSON lines |
| Maintenance | Plasma 6.8, October 2026; active | 1.1.0, October 2026 |

## Where KRunner is stronger

- **It is the desktop's own search.** Runners come from Plasma and KDE
  apps, so activities, virtual desktops and session switching are results
  like any other. Flash reaches macOS's equivalents only where an API or a
  plugin exposes them.
- **Your web shortcuts.** Add a keyword and a URL in System Settings and
  KRunner knows it. Flash's bangs come from DuckDuckGo's and Kagi's lists;
  `[flashlight.aliases]` can rename one, not add a site.
- **Shell commands where you type.** A command runs straight from the box,
  with options to run it in a terminal or as another user; Flash wants
  `:!` first, and shows the output rather than a terminal.
- **D-Bus runners** let a script in any language join the results: a
  desktop file in `~/.local/share/krunner/dbusplugins/` and a service that
  answers `Match` and `Run`.

## Where Flash is stronger

- **macOS apps and data.** Mac apps, Safari, Chrome and Firefox tabs,
  Notes, Reminders, Contacts and Shortcuts (`@notes`, `@reminders`,
  `@contacts`, `@shortcuts`), and the frontmost app's menu items
  (`@menus`).
- **Every window, labelled.** The [window switcher](../windows.md#switch-to-any-window)
  lists windows on any Space Flash has seen, minimized and hidden ones
  included, each with a hint label.
- **Bangs at scale**, resolved on your Mac without a redirect.
- **A command line for the whole tool**: hints, window placement, tabs,
  the bar and popups are words you type after `:` with completion.

## Flash features you might like

- `time in tokyo` and `10 euros` answer inline, beside the arithmetic.
- `@system` holds lock, sleep, restart and log out, which KRunner users
  reach by typing their names.
- `menu choose` gives scripts the picker KRunner never had.
- `--query=@windows` on its own chord jumps straight to window search.

## Moving from KRunner

| KRunner | Flash |
| --- | --- |
| Alt+Space, Alt+F2 | A chord to `["flash", "mode", "flashlight"]` |
| `= 2*(3+4)` | `2*(3+4)`, no `=` needed |
| `27.8 km` | `27.8 km to mi` |
| `gg:KDE`, `wp:krunner` | `!g KDE`, `!w krunner` |
| A web shortcut you defined | Not available; an alias renames an existing bang |
| A window's title | `@windows <title>`, or `window switch` |
| A virtual desktop | `workspace switch --name=<name>` with [tiling](../tiling.md) on |
| An activity | Not available |
| A shell command | `:!cmd`, or `mode command --input=!` on a chord |
| `#ls`, `man:/grep` | `:!man ls`, shown in the pager |
| `switch`, `new session` | `system logout`; no session switching |
| Lock, sleep, log out | `@system`, or `screen lock`, `system sleep` |
| A D-Bus runner | A plugin that publishes a source ([cookbook](../plugin-cookbook.md)) |

```toml
[mode.all.mappings]
"alt+<space>" = ["flash", "mode", "flashlight"]
"alt+shift+<space>" = ["flash", "mode", "command", "--input=!"]
"alt+w" = ["flash", "mode", "flashlight", "--query=@windows"]

[flashlight.aliases]
"!gg" = "!g"
"!wp" = "!w"
```

The aliases keep KRunner's `gg` and `wp` keywords pointing at Google and
Wikipedia, as bangs followed by a space. Option-Space types a non-breaking
space on a Mac; binding it takes that from every app.

*Checked 2026-10-23 against KDE's [KRunner page](https://userbase.kde.org/Plasma/Krunner),
the [KRunner framework](https://invent.kde.org/frameworks/krunner)
repository, KDE's [This Week in Plasma](https://blogs.kde.org/2026/10/10/this-week-in-plasma-finishing-touches-on-6.8/)
for 6.8, and KRunner D-Bus runner examples.*
