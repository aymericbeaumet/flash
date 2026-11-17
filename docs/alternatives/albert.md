# Flash and Albert

[Albert](https://albertlauncher.github.io) "is a plugin-based,
desktop-agnostic C++/Qt keyboard launcher". A query that starts with a
trigger goes to that plugin alone; anything else goes to every global
handler at once, with fallbacks when nothing matches, and every result
carries a list of actions. Its plugins cover applications, files, a
Qalculate calculator, clipboard, snippets, web search, ssh, timers, time
zones, the focused app's menu items and Homebrew, and Python plugins add
more. It is C++, about 8,000 stars, v35.1.0 in July 2026, under the
"Albert license v1.1": personal use, modified or not, and redistribution
without modification; redistributed binaries must not target Microsoft or
Apple platforms. Unlike most Linux launchers it also runs on macOS, from its own Homebrew tap, as an
unsigned app the cask signs ad hoc. So a Linux Albert user can keep Albert
on the Mac; Flash is the alternative when you want the launcher, hints and
modes in one app.

| | Albert | Flash |
| --- | --- | --- |
| License, price | Albert license v1.1 (source available, personal use), free | MIT, free |
| Platforms | Linux, macOS (Homebrew tap) | macOS 13+ |
| Query model | Triggers, global handlers in parallel, fallbacks; actions per item | One ranked pool, `@<type>` scopes, `!bangs`; one action per row |
| Plugins | Native C++ and Python, enabled in settings | Processes in any language over JSON lines, most sandboxed |
| Beyond launching | None | Hints, NORMAL mode, window placement, status bar, popups |
| Configuration | Settings window, ini file | `flash.toml`, live reload |
| Maintenance | v35.1.0, July 2026; active | 1.1.0, October 2026 |

## Where Albert is stronger

- **The same launcher on both machines.** Your triggers, plugins and habits
  work on the Linux desktop and on the Mac; Flash has no Linux build.
- **Actions on every result.** Hold Option or press Command-Return for an
  item's other actions. A flashlight row does one thing, with Shift-Return
  and Option-Return as variants on clipboard rows only.
- **Triggers and fallbacks.** A trigger hands the query to one plugin,
  which can order its own results and show an input hint; fallback items
  appear when nothing matches.
- **A broad plugin set**, including Qalculate's full calculator, ssh hosts,
  timers, Obsidian, Spotify and Homebrew (install and uninstall from the
  launcher), and a Python API for your own.
- **A settings window**, with a configuration page for plugins that have
  options, and an input history on Shift-Up and Shift-Down.

## Where Flash is stronger

- **MIT licence.** You may modify and share Flash; Albert's licence permits
  personal use and unmodified redistribution only.
- **Tabs, windows and tmux.** Safari, Chrome and Firefox tabs, every window
  on any Space Flash has seen, minimized and hidden ones included, with a
  hint label per row, and tmux windows on local and listed remote hosts.
- **Bangs at scale.** About 14,500 DuckDuckGo and Kagi triggers resolved on
  your Mac ([bangs](../flashlight.md#bangs)).
- **Past the launcher.** Hints on every button, a keyboard grid, window
  placement, a status bar and popups share the same file and plugins.
- **Sandboxed plugins** with declared capabilities ([privacy](../privacy.md#plugin-isolation)).

## Flash features you might like

- `:!cmd` is Albert's `>` command-line trigger, with the output in a banner
  or the pager.
- `@system` lists lock, sleep, restart and the rest; `@menus` searches the
  frontmost app's menu items, as Albert's Menu bar plugin does.
- `@snippets` types a snippet from a TOML file of `name = text` lines.
- `menu choose` turns any list into a picker for your own scripts.

## Moving from Albert

| Albert | Flash |
| --- | --- |
| The Albert hotkey | A chord to `["flash", "mode", "flashlight"]` |
| Applications plugin | The default rows |
| `>` command line | `:!cmd` |
| Calculator (Qalculate) | Inline answers: `1+1`, `2 km to m`, `10 euros` |
| Web search triggers | `!bangs`: `!w`, `!gh`, `!yt` |
| Clipboard plugin | `!clip`, with pins and images ([clipboard](../clipboard.md)) |
| Snippets plugin | `@snippets`, from `[plugins.snippets] file` |
| Files plugin | `!f <name>` or `@files` |
| Time zones, date and time | `time in tokyo` |
| System plugin | `@system` |
| Menu bar plugin | `@menus` |
| ssh plugin | A `menu choose` script over `~/.ssh/config` |
| Fallbacks | Type a bang |
| Item actions (Command-Return) | Not available: one action per row |
| Python plugins | A Flash plugin ([cookbook](../plugin-cookbook.md)) |

```toml
[mode.all.mappings]
"cmd+ctrl+space" = ["flash", "mode", "flashlight"]
"cmd+ctrl+s" = ["flash", "mode", "flashlight", "--query=@snippets", "--restore-mode"]

[plugins.snippets]
file = "~/.config/flash/snippets.toml"
```

## Running Albert next to Flash

The two can share a Mac: Albert keeps launching and its plugins, Flash takes
hints, modes and the bar. NORMAL swallows chords it does not map, so the
dependable way to open Albert is a Flash chord that calls Albert's own
command line, `albert toggle`, or `albert show "<trigger> "` to open it on a
trigger (with `albert` on your `PATH`):

```toml
[mode.all.mappings]
"cmd+<space>" = ["albert", "toggle"]
"cmd+ctrl+x" = ["albert", "show", "> "]  # the command-line trigger
```

Command-Space is Spotlight's shortcut; turn it off in System Settings ›
Keyboard › Keyboard Shortcuts › Spotlight first.

*Checked 2026-10-23 against the Albert [README](https://github.com/albertlauncher/albert),
[licence](https://github.com/albertlauncher/albert/blob/main/LICENSE.md),
[releases](https://github.com/albertlauncher/albert/releases),
[macOS installation](https://albertlauncher.github.io/installation/macos/),
[basics](https://albertlauncher.github.io/basics/) and
[FAQ](https://albertlauncher.github.io/faq/) pages.*
