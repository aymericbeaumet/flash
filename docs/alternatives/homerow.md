# Flash and Homerow

[Homerow](https://www.homerow.app) is "Keyboard shortcuts for your entire
Mac": Accessibility-based labels and a scroll mode, sold for a one-time
$49.99 covering all your personal Macs, with a free trial that reminds you
every 50 activations. It began as the commercial successor of Vimac by Dexter
Leng and now belongs to Neil Chudleigh. Version 1.5.3 shipped in March 2026;
updates are irregular (1.4.0 in February 2025, 1.4.1 in October 2025).

| | Homerow | Flash |
| --- | --- | --- |
| License, price | Closed; $49.99 one-time | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Hints from | Accessibility tree | Accessibility tree; tmux panes |
| Pointer modes | Labels, search and labels together, labels-only, scroll mode, click chain, Mission Control | Hints, search, grid, bisect, pointer mode, drag, select, words, path, sticky, click chain, Mission Control |
| Beyond pointing | Caps Lock to Hyper remap, sound effects | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Settings window, "Ignored Apps" | One TOML file, live reload, CLI |
| Maintenance | 1.5.3, March 2026; 156 open issues on the tracker | 1.0.0, October 2026; one maintainer |

## Where Homerow is stronger

- **Polish.** A settings window, a tutor that shows which properties of an
  element are searchable, sound effects, and a product that has been in
  daily use by many people for years.
- **Search and labels in one view** with a fast/exhaustive switch, tuned
  over a long time on the apps people actually use.
- **Labels as Mission Control opens**, with no key to press (a setting since
  1.5.3). Flash waits for `f`.
- **Nothing to configure.** Install, grant Accessibility, done.

## Where Flash is stronger

- **Free and open.** No trial reminders, no licence, and the source is there
  when an app misbehaves.
- **Configured in a file.** Every binding is in `flash.toml`, lives in your
  dotfiles, reloads on save and is validated by `flash config check`. Homerow
  has no file, CLI or scripting surface.
- **A persistent NORMAL mode** instead of a hold-to-activate hint mode, with
  actions that resolve per app.
- **Grid and pointer modes** for apps with no Accessibility tree. Homerow
  has no grid, so a canvas app is a dead end.
- **Click chains that keep up.** Homerow's chain is a setting that turns every
  activation into one; Flash's is its own key, `alt+f`, next to `f`. It
  labels the app again whenever the app reports a change before your next
  pick, which Homerow's tracker asks for (#218, #188), and it ends on an
  input in INSERT, as Homerow's does.
- **Mission Control on every display**, which Homerow's tracker asks for
  (#216), with App Exposé, and a drag from a window onto a desktop.
- **Terminal, bar, widgets, popups, search, plugins.** Homerow stops at the
  click.
- **Documented privacy.** Homerow's tracker has an open request to opt out of
  analytics calls (#98). Flash has no analytics, and its
  [privacy page](../privacy.md) lists every network destination.

## Flash features you might like

- `mouse target --search` for the search-first feel, `mouse target` for
  labels only, in the same hotkey table.
- `alt+f` (`mouse target --multi`) is the click chain: the labels come back
  after every click until Escape. `--sticky` keeps the same labels instead.
- `f` in Mission Control and App Exposé labels the windows, the desktops and
  the add-desktop button; Escape still closes Mission Control.
- `scroll target` chooses the scroll area, then NORMAL's `ctrl+e`/`ctrl+y`
  scroll it, and `ctrl+d`/`ctrl+u` too unless a list or a text field has
  focus, where they move its selection or caret
  ([arrows or scrolling](../normal-mode.md#arrows-or-scrolling)).
- `mouse dock`, `mouse menubar` and `mouse notifications` label surfaces
  outside the focused window.

## Moving from Homerow

| Homerow | Flash |
| --- | --- |
| Hint shortcut | `["flash", "mouse", "target"]` on the key of your choice |
| Labels only | `mouse target` (labels are the default) |
| Search | `["flash", "mouse", "target", "--search"]` |
| Scroll mode | NORMAL mode scroll keys, `scroll target` to pick the area |
| Shift-Return right-click | In NORMAL, `cf` right-clicks a hint; from a hotkey, `mouse bigram --secondary` |
| Cmd-click, double-click | `df` double-clicks in NORMAL; modifiers are held as you type the label |
| Ignored Apps | `[mode.apps."<bundle id>"]` tables, or leave the app unmapped |
| Caps Lock to Hyper | Keep Karabiner-Elements; Flash does not remap hardware keys |
| Chain clicks setting | `alt+f`, or `["flash", "mouse", "target", "--multi"]` on a hotkey |
| Mission Control hints | `f` while Mission Control or App Exposé is up; nothing to turn on |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]
"cmd+shift+alt+space" = ["flash", "mouse", "target", "--search"]
```

Both apps take the Accessibility grant and a hotkey; running them together
only costs a second overlay. Keep Homerow for its tutor while you learn what
each app exposes, if you like.

*Checked 2026-10-23 against
[homerow.app](https://www.homerow.app), its
[changelog](https://www.homerow.app/changelog) and the
[issue tracker](https://github.com/nchudleigh/homerow).*
