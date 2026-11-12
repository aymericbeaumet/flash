# Getting started

Flash starts with one hotkey and grows one table at a time. Everything here
is also in the browser help (`flash help show`), with your own mappings filled in.

These instructions describe the current source. If you installed stable
1.1.0, use its [getting-started guide](https://github.com/aymericbeaumet/flash/blob/1.1.0/docs/getting-started.md):
command and configuration names have changed since that release. A nightly
tracks `main`; a feature branch requires a [development build](development.md).

## Install

```sh
brew install --cask aymericbeaumet/tap/flash
```

[Install and update](install.md) covers the requirements, the download from
GitHub, the first launch (allowing Flash to open, then the Accessibility
grant), the `flash` command, updates and uninstalling. Come back once
`flash resident doctor` reports Accessibility granted.

## 1. One hotkey

On first launch Flash creates `~/.config/flash/flash.toml` with one mapping:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]
```

Try it in Finder first:

1. Open a Finder window and leave it focused.
2. Press **⌘⇧Space**. Labels appear on accessible controls.
3. Type the label on a sidebar folder. Flash clicks it and the folder opens.
4. Press the shortcut again, then Escape to dismiss the labels without clicking.

Your regular typing still works: NORMAL is opt-in. You can keep just this
hotkey and stop here. If nothing appears, check Accessibility and hotkey
conflicts in [troubleshooting](troubleshooting.md); a control the app does
not expose needs the [grid](mouse-grid.md) instead.

From a terminal, `flash mouse target` does the same job in the focused app.
Open the
file from the menu-bar icon (**Open Configuration**); changes apply as soon as
you save. The live [key mappings](/mappings) page lists every binding in
effect, including the ones plugins and your file add. [Hints](hints.md)
covers every way to click, move and select.

## 2. Grid and search

The starter file already lists these shortcuts, commented out: delete the
leading `# ` to enable each one. In a file of your own, add them inside the
existing [`[mode.all.mappings]`](config:mode.all.mappings) table; TOML allows each table to be declared
only once.

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]                            # hints
"cmd+shift+alt+space" = ["flash", "mouse", "grid"]                          # keyboard grid
"cmd+ctrl+alt+space" = ["flash", "mode", "flashlight"]                      # search
```

In the grid, `1` is the top-left cell and `b` the bottom-right one. Each key
zooms into its cell with the same keys, and the last step clicks. Backspace
steps back, Tab moves to the next display; see [the mouse grid](mouse-grid.md).

Search opens on the flashlight; try `@emojis fire` or
`1234 euros in dollars`.

Pick hotkeys that are free on your Mac. macOS uses Control-Space and
Control-Option-Space to switch input sources, and many editors use
Control-Space for completion.

## 3. Normal mode

Uncomment both entries in the starter's `[mode.all.mappings]` table (or add
them to your own; do not declare the table twice). Enable the entry and exit
shortcuts together:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
```

Press ⌘⌃[ and the status pill, if the bar is on, reads NORMAL. Keys to try
first, in a browser:

| Key | Does |
| --- | --- |
| `f` | Labels accessible controls; type a label to click it, Escape cancels |
| `F` | The keyboard grid, for a spot no label covers |
| `s` then a letter | Labels every visible occurrence of that letter (EasyMotion) |
| `h` `j` `k` `l`, `ctrl+d` / `ctrl+u`, `gg` / `G` | The arrow keys (a page scrolls on them, a list moves its selection, a text field you clicked its caret); half a page; the top or bottom |
| `gt` / `gT`, `t`, `x` | Next and previous tab, a new tab, close the tab |
| `/`, then `n` / `N` | The app's own Find and its next and previous match; NORMAL stays on, so press `i` to type the query |
| `:` | The command line (`:tab next`, `:q`, `:help`); words abbreviate, `:ta nex` works |
| `?` | The live page of every mapping in effect |

While NORMAL is active, keys that are not mapped are captured instead of typed.
Press `i` (or ⌘⌃I) to type again; nothing else leaves NORMAL, a click into a
text field (with the mouse, `f` or `F`), opening Find (`/`) or a new tab
(`t`) included, and Escape cancels hints without leaving it (with none up,
it is the app's own Escape: a popover or a dialog closes). NORMAL stays
active across app and tab switches. See [normal mode](normal-mode.md) for
every binding, [coming from Vim](vim.md) for your Vim habits, and
[troubleshooting](troubleshooting.md) if the keyboard seems stuck.

## 4. Status bar and widgets

```toml
[statusbar]
enabled = true

[widgets.system]
anchor = "top_right"
template = """
CPU #[meter=20]#{flash.plugin.sysinfo.cpu_percent}#[nometer] #[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]
MEM #[meter=20]#{flash.plugin.sysinfo.memory_percent}#[nometer]
#{flash.top_cpu}
"""
```

Tools used by terminal popups, such as btop or newsboat, must already be
installed on your login `PATH`; Flash does not install them.

The bar is off until you set `enabled = true`. It takes the top of the
screen, so macOS auto-hides its own menu bar while it is enabled; reaching
for the top edge still reveals it, and turning the bar off restores it.
Widgets sit on the desktop, below your windows. Start from the
[status bar example](examples/statusbar/README.md) or the
[widget examples](examples/widgets/README.md), and see
[widgets](widgets.md) for a conky migration table.

## 5. Remap or remove anything

Every default binding can be changed or removed, including the ones plugins
add; [mapping syntax](mappings.md) spells keys and chords:

```toml
[mode.normal.mappings]
"t" = false                                          # remove a default
"gs" = ["flash", "mouse", "target", "--scope=screen"]   # add your own
```

`flash config check` validates the file without the app running, so it fits in
a dotfiles CI job.

## 6. Plugins

[Plugins](plugins.md) add catalogs, actions, answers and status values. Write
one in any language, or pin someone else's to a commit. Start with the
[plugin cookbook](plugin-cookbook.md). If something fails, start with
[troubleshooting](troubleshooting.md) and the live [runtime](/state) page.

## Where to next

[How Flash works](concepts.md) names the modes and surfaces these steps
used, and the [documentation's home](README.md) finds a page by what you want to
do: windows, clipboard history, marks, monitors, the calendar, macOS
settings, scripting Flash from the terminal.

## Coming from Linux?

| You used | In Flash |
| --- | --- |
| keynav, warpd grid | `mouse grid`, keyboard-shaped, with `--bisect` |
| Vimium, qutebrowser hints | `mouse target`, in every app |
| warpd normal mode | `mouse pointer` |
| conky | [desktop widgets](widgets.md) |
| polybar, waybar | [`[statusbar]`](config:statusbar) with tmux formats |
| rofi, dmenu | flashlight |
| i3, sway, Hyprland modes | NORMAL / INSERT / COMMAND / TERMINAL with `[mode.*.mappings]` |
| i3 `move`, Hyprland dispatchers | `window move` |
| swaymsg, hyprctl | `flash <topic> <action>`, `flash resident status --json`, `flash events watch` |
| dotfiles | one `flash.toml`, live reload, `flash config check` |

The [Linux section](alternatives/README.md#coming-from-linux) of the
alternatives has a page for each of these window managers, launchers, bars
and keyboard tools, with its configuration translated line by line.

## Quit and uninstall

Quit from the menu-bar icon or with `flash resident quit`. Set `[app] autostart = false`
to stop Flash from starting at login, and `[app] menu_bar_icon = false` to hide
the icon. [Uninstall](install.md#uninstall) lists what to undo before removing
Flash and the files it leaves behind.
