# Flash and Vimari

[Vimari](https://github.com/televator-apps/vimari) is the "Keyboard
Shortcuts extension for Safari": "a lightweight port of vimium to Safari,
taking the best components of vimium and adapting them to Safari." Guy
Halford-Thompson started it in 2011; it now ships from the televator-apps
organisation as a free Mac App Store app that installs a Safari extension.
It is MIT, about 2,700 stars, and has been for years what a Safari user
reached for, since [Vimium](vimium.md) does not run in Safari. Version 2.1.1,
a rebuild for Apple silicon, came out on 27 January 2021, the last commit
landed in April 2021, and 120 issues are open, some filed in 2026. The App
Store lists macOS 10.12 or later; the README asks for Safari 12.

| | Vimari | Flash |
| --- | --- | --- |
| License, price | MIT, free on the Mac App Store | MIT, free |
| Platforms | Safari 12+; macOS 10.12+ per the App Store | macOS 13+ |
| Permissions | Safari's permission for the extension on the sites you allow | Accessibility; Automation of Safari to list its tabs |
| Keys | `f`/`F` hints, scrolling, `w`/`q` tabs, `x`, `t`, `H`/`L`, `r`, `gi` | Those and the rest of NORMAL: tab moves, Find, zoom, windows, apps |
| Modes | Normal and insert (2.1), with optional transparent bindings | NORMAL, INSERT, VISUAL, COMMAND, HOLD and layers, across apps |
| Where it works | Pages Safari loads it into; not the address bar, `topsites://` or Reader | Every app; in Safari the page, toolbar, tab bar, sidebar and menus |
| Configuration | A settings screen and a JSON file of bindings | One TOML file, live reload, `flash config check` |
| Maintenance | 2.1.1, January 2021; no commit since April 2021 | 1.1.0, October 2026 |

## Where Vimari is stronger

- **Pages' own keys keep working.** With transparent bindings on, every key
  Vimari does not bind reaches the page in its normal mode, so Gmail's or
  YouTube's single-key shortcuts still fire. Flash's NORMAL swallows every
  key it does not map; a page's shortcuts need INSERT.
- **Per-site exclusions.** "Excluded URLs" turns it off on chosen sites.
  Flash's tables go per app; Safari is one app to it.
- **The DOM.** It finds links from the page itself, and can count anything
  with a pointer cursor as clickable ("Extra detection by cursor style"), on
  pages whose Accessibility output is thin.
- **Small.** A handful of keys, a settings screen, nothing running outside
  Safari, and no system permission.

## Where Flash is stronger

- **Safari's own interface.** Vimari's README sends you to ⌘L for the
  address bar and notes that it does not load on `topsites://` or work in
  Reader. Flash labels the address bar, tab bar, sidebar, toolbar and menus,
  and those pages too where Safari exposes them to Accessibility.
- **Pages left as they are.** Vimari has not shipped since January 2021,
  and its open reports include a page it breaks, filed in 2026. Flash adds
  no script to a page: its Safari hints come from Safari's Accessibility web
  areas, so a page renders as it would without it.
- **Tabs as a list.** `@tabs` searches Safari's open tabs beside Chrome's
  and Firefox's, `g1`–`g9` select one by position, `]m`/`[m` move the
  current tab (Safari has no shortcut for it, so Flash moves it with
  AppleScript), and `X` reopens the last one closed.
- **Text selection.** `mouse target --select` clicks one label and
  Shift-clicks another; HOLD (⌘⌃H) extends a held selection with `w`, `b`
  and `$`. Vimari has no visual mode.
- **The same keys everywhere**: Mail, Finder, Notes and a terminal take `f`
  and `gt` as Safari does.

## Flash features you might like

- `s`, then a letter, labels every visible occurrence of it, and its label
  clicks it, link or not.
- `mouse target --search` to pick a link by its text, and `mouse target
  --scope=screen` to reach a Picture in Picture window
  ([hints](../hints.md#beyond-the-focused-window)).
- `zi`/`zo`/`z0` use Safari's own zoom, and `/` opens Safari's Find with
  `n`/`N` for the matches.
- `ctrl+w l` focuses the window to the right, whichever app it belongs to.

## Moving from Vimari

| Vimari | Flash |
| --- | --- |
| `f` | `f` in NORMAL |
| `F` (new tab) | `f`, holding Command on the last label key |
| `j`, `k`, `h`, `l`, `gg`, `G` | The same in a page; in a focused field they move the caret, and `ctrl+e` / `ctrl+y` still scroll |
| `u`, `d` (half page) | `ctrl+u`, `ctrl+d`; Flash's `u` is Safari's undo and `d` the double-click prefix |
| `gi`, `H`, `L`, `r`, `x`, `t` | The same; `gi` keeps NORMAL, `i` or `f` on the field types |
| `w`, `q` (next, previous tab) | `]t`, `[t`, or `gt`, `gT`, or `K`, `J`; map `w` and `q` yourself if you like (a `q` mapping replaces macro recording) |
| `i`, then Escape or Control-[ | `i` enters INSERT, where Escape belongs to Safari; bind a chord for NORMAL |
| Modifier setting | Chords in `[mode.all.mappings]`, which work in every mode |
| Link Hint Characters | `[hints] keys`, a string of letters or a layout selector |
| Scroll Size, Smooth Scroll | `[mode] scroll_step_lines`, `scroll_page_lines`, `scroll_smooth_ms` |
| Excluded URLs | Nothing per site; `[mode.apps."com.apple.Safari".normal.mappings]` per app |
| Transparent bindings | Nothing: press `i` for a page's own keys |
| Several bindings for one action | Several keys mapped to the same command |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]

[mode]
scroll_smooth_ms = 120

[mode.apps."com.apple.Safari".normal.mappings]
"w" = ["flash", "tab", "next"]
"q" = ["flash", "tab", "previous"]
"T" = ["flash", "mode", "flashlight", "--query=@tabs"]
```

## Using both

Only one of them hears a key at a time. In NORMAL, Flash swallows every key
it does not map before Safari gets it, so Vimari stays quiet; in INSERT
every key reaches the page, and Vimari's normal mode, hints and tab keys
work as before ([what NORMAL swallows](../normal-mode.md#what-normal-swallows)).
Vimari's own insert mode and Flash's INSERT then stack: Escape goes to
Vimari, and your Flash chord takes you back to NORMAL.

If you keep Vimari, use it in INSERT for the pages where its DOM hints or
transparent bindings matter to you, and Flash's NORMAL for Safari's toolbar,
its tabs and the apps around it. Removing a Flash key with `false` does not
hand it to Vimari: NORMAL swallows it all the same.

*Checked 2026-10-23 against the Vimari
[README](https://github.com/televator-apps/vimari), its
[releases](https://github.com/televator-apps/vimari/releases),
[issues](https://github.com/televator-apps/vimari/issues) and commit history,
and its [Mac App Store listing](https://apps.apple.com/us/app/vimari/id1480933944).*
