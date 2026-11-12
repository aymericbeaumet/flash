# How Flash works

Flash is one app that stays running, plus a `flash` command that talks to
it. Everything it does is a command, every surface is something a command
opens, and one TOML file says which keys run which commands. This page names
the pieces the rest of the documentation uses.

## One file

`~/.config/flash/flash.toml` is the whole configuration. Flash applies it
when you save, and `flash config check` validates it without the app
running. Anything you leave out keeps its default: the
[reference file](https://github.com/aymericbeaumet/flash/blob/main/config.default.toml)
lists every option with its default, and [configuration](configuration.md#find-the-setting)
says which page covers each table.

## Commands

Every action is two words, a topic and an action: `tab next`,
`window move --position=lefthalf`, `mouse target`. The same words run three
ways:

| From | Write |
| --- | --- |
| A terminal or a script | `flash tab next` |
| A key, in `flash.toml` | `"gt" = ["flash", "tab", "next"]` |
| The command line | `:tab next`, or cut to a unique prefix, `:ta nex` |

A command asks the focused app to act in its own terms, so `tab next`
switches a browser tab, a Finder tab or a tmux window, and an app without
the command gets nothing. [Commands](commands.md) lists every command; the
live [command catalog](/commands) shows the ones installed on this Mac,
plugin commands included.

## Modes

Until a shortcut in [`[mode.all.mappings]`](config:mode.all.mappings) runs `mode normal` (or
`mode leave`), Flash has no modes: your shortcuts run their commands and
every other key types as usual. Binding one turns the modes on, which the
reference file calls advanced mode. The status bar's pill
(`#{flash.mode}`) shows the mode you are in.

| Mode | What the keyboard does | Enter | Leave |
| --- | --- | --- | --- |
| [NORMAL](normal-mode.md) | Keys run commands; keys you have not mapped are swallowed | Your `mode normal` shortcut | `i`; `v` `V` in a field |
| [VISUAL](visual-mode.md) | A selection in the focused text: the motions grow it, operators act on it | `v` `V` in a focused field (`mode visual`), which they engage | Escape, an operator |
| [INSERT](insert-mode.md) | Keys go to the app; only your chords act | `i` (`mode insert`); never a click | Your `mode normal` shortcut |
| [COMMAND](command-mode.md) | You type a command or a flashlight search | `:` in NORMAL, `mode command` | Return runs it, Escape closes it |
| [TERMINAL](terminal-mode.md) | A popup's terminal has the keyboard | `mode terminal`, a click into a popup | `mode leave`, Command-W in a popup |
| [HYPER](hyper-mode.md) | Keys read [`[mode.hyper.mappings]`](config:mode.hyper.mappings): the function row and arrows by default | Hold the HYPER key, the leader (`\`) by default | Release it |
| [HOLD](hold-mode.md) | A mouse button is held, so keys drag or select | ⌘⌃H (`mode hold`) | Return drops, Escape puts it back |
| [A layer](layers.md) | A key table of your own | `mode layer --name=<name>` | Escape |

NORMAL stays on across app and tab switches and through every click; nothing
leaves it for INSERT but `mode insert` ([enter INSERT](insert-mode.md#enter-insert)). Each
mode has its own page, and [modes](modes.md) compares them: which keys each
reads, how to leave one, and the pill's labels and colours.
[Coming from Vim](vim.md) maps Vim habits onto them.

## Surfaces

| Surface | What it is | Opened by |
| --- | --- | --- |
| [Hints](hints.md) | Labels on every control of the focused app; type one to click it | `mouse target`, `f` in NORMAL |
| [Mouse grid](mouse-grid.md) | The screen split like the left half of your keyboard, for spots no label covers | `mouse grid`, `F` in NORMAL |
| Command line and [flashlight](flashlight.md) | The `:` prompt; with `:flashlight`, a search over apps, tabs, windows, emoji and plugin data, with inline answers | `:`, `mode command` |
| [Status bar](statusbar.md) | A tmux-format bar along the top of the screen, while macOS's own menu bar hides | `[statusbar] enabled = true` |
| [Widgets](widgets.md) | The same templates drawn on the desktop, below every window | `[widgets.<name>]` |
| [Popups](popups.md) | Real terminals running tools you already use (btop, newsboat), shown from the bar or a key | `[popup.<name>]`, `mode terminal` |
| Alerts | One centred message, or a `y`/`n` question before something that cannot be undone | Commands, `alert show` |
| Notifications | A macOS notification that stays in Notification Center; a click can open a URL or run a command | `notify send`, a [monitor](monitors.md#keys) with `notify = true` |
| [Browser help](help.md) | This documentation, beside live pages about your installation | `:help`, `flash help show`, `?` in NORMAL |

## Plugins

[Plugins](plugins.md) are separate programs Flash starts, watches and stops.
They add search catalogs, inline answers, hints, status values, commands and
their own help, and each declares the capabilities it needs; most run in a
sandbox. The bundled ones cover browsers, terminals and tmux, system figures,
search providers, emoji, snippets and more.

## What Flash never does

Flash never reads the screen and never records keys: hints come from
Accessibility, and the one keyboard tap only decides whether a key is
swallowed. [Privacy](privacy.md) lists every permission, network
destination and file.
