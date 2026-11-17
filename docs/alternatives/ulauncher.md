# Flash and Ulauncher

[Ulauncher](https://ulauncher.io) "is a fast application launcher for
Linux. It's written in Python using GTK+, and features: App Search (fuzzy
matching), Calculator, Extensions, Shortcuts, File browser mode and Custom
Color Themes." It opens on Ctrl+Space, has a preferences window, a gallery
of Python extensions at ext.ulauncher.io, and shortcuts that turn a keyword
into a URL or a script (`g %s` searches Google out of the box). It is
GPL-3.0 Python, about 4,500 stars; the stable 5.16.2 shipped in September
2026, and v6, "a huge rewrite", is in public beta (beta35 the same month),
with v5 receiving no new features meanwhile. It runs on Linux only. On a Mac,
Flash's [flashlight](../flashlight.md) covers app search, calculation and
web keywords; [Raycast](raycast.md) and [Alfred](alfred.md) are the
launchers with an extension store.

| | Ulauncher | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Linux | macOS 13+ |
| Search | Apps (fuzzy), files by path, calculator, shortcuts, extensions | Apps, tabs, windows, tmux windows, files by name, processes, menus, emoji, clipboard, answers, bangs |
| Web keywords | Shortcuts: your own keyword, URL or script with `%s` | About 14,500 `!bangs` from DuckDuckGo's and Kagi's lists; aliases for your own spelling |
| Extensions | Python, a public gallery | Plugins in any language over JSON lines, most sandboxed |
| Configuration | Preferences window; JSON files | `flash.toml`, live reload |
| Maintenance | 5.16.2 and v6 beta, September 2026 | 1.1.0, October 2026 |

## Where Ulauncher is stronger

- **Shortcuts are yours.** Any keyword, any URL with `%s`, or a script that
  receives the query, created in the preferences window. Flash's bangs come
  from DuckDuckGo's and Kagi's lists; `[flashlight.aliases]` renames one,
  but you cannot add a site of your own.
- **The extension gallery.** Years of community extensions, browsed on
  ext.ulauncher.io and installed from their repository URL. Flash's
  plugins are the bundled ones, plus third-party ones pinned to a commit in
  the file.
- **File browsing by path.** Typing `~/` walks the file system in place;
  Flash finds files by name through Spotlight.
- **A settings window and colour themes**, for people who would rather
  click than edit TOML.

## Where Flash is stronger

- **Mac apps, browser tabs and every window.** It lists Safari, Chrome and
  Firefox tabs and windows on any Space Flash has seen, minimized or hidden,
  each with a hint label in the [window switcher](../windows.md#switch-to-any-window).
- **More answers inline**: units, currencies and world clocks beside
  arithmetic, with nothing to install.
- **Clipboard history and emoji built in** (`!clip`, `@emojis`), where
  Ulauncher reaches for an extension.
- **A command line and a picker for scripts.** `:` runs any Flash command,
  `:!cmd` the shell, and `flash menu choose` turns a list into a menu.
- **It acts on the screen too**: hints, a keyboard grid and window
  placement live in the same app.

## Flash features you might like

- `!g`, `!w` and `!so` are bangs already, so the default shortcuts keep
  working word for word ([bangs](../flashlight.md#bangs)).
- Frecency ranks what you open often, as Ulauncher's app ordering does.
- `--query=@<type>` on a chord opens a scoped search, the way an extension
  keyword does.
- Plugins publish their rows to Flash, so typing never waits on a plugin
  process ([plugins](../plugins.md)).

## Moving from Ulauncher

| Ulauncher | Flash |
| --- | --- |
| Ctrl+Space | A chord to `["flash", "mode", "flashlight"]` |
| App search | Type the name; a running app outranks an installed one that matches as well |
| Calculator | Type the expression: `1+1`, `2 km to m` |
| Shortcut `g %s`, `wiki %s`, `so %s` | `!g`, `!w`, `!so` |
| A shortcut with your own URL | Not available; `["open", "https://…"]` in a mapping opens a fixed page |
| A shortcut running a script with `%s` | `:!script args` on the command line |
| File browser (`~/`) | `!f <name>` or `@files` |
| Extensions | Bundled plugins, or one of your own ([cookbook](../plugin-cookbook.md)) |
| Color themes | None |
| "Launch at Login" | `[app] autostart = true`, the default |

```toml
[app]
autostart = true

[mode.all.mappings]
"cmd+ctrl+space" = ["flash", "mode", "flashlight"]
"cmd+ctrl+d" = ["open", "https://docs.python.org/3/"]

[flashlight.aliases]
"!wiki" = "!w"
"@t" = "@tabs"

[flashlight]
ignored_apps = ["Migration Assistant", "Boot Camp Assistant"]
```

Command-Control-Space is macOS's own Emoji & Symbols shortcut, which the
first mapping replaces.

*Checked 2026-10-23 against the Ulauncher [README](https://github.com/Ulauncher/Ulauncher),
its [releases](https://github.com/Ulauncher/Ulauncher/releases),
[ulauncher.io](https://ulauncher.io) and the v5 default settings and
shortcuts in its source.*
