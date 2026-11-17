# Flash and Vimium C

[Vimium C](https://github.com/gdh1995/vimium-c) is "A keyboard shortcut
browser extension for keyboard-based navigation and tab operations with an
advanced omnibar". Gong Dahan (gdh1995) forked [Vimium](vimium.md) in 2014,
rewrote it in TypeScript and kept adding: contextual mappings per site,
global shortcuts that also fire inside input boxes, trees of commands run
from one key, injection into other extensions' pages, full Chinese support
and companion extensions (a PDF viewer, a new-tab adapter). It is
Apache-2.0 (older MIT code lives on a separate branch), free, about 4,600
stars, for Chrome, Edge and other Chromium browsers from version 102 and
desktop Firefox from 101. The store builds are 2.12 (2.12.3 on Firefox
Add-ons, 2.12.2 on Edge Add-ons, both from 14 April 2025); the GitHub
releases page still ends at 1.99.995 from April 2023, and `master` has had
no commit since April 2025.

| | Vimium C | Flash |
| --- | --- | --- |
| License, price | Apache-2.0, free | MIT, free |
| Platforms | Chromium 102+ (Chrome, Edge, Brave and others) and Firefox 101+, on any desktop OS | macOS 13+ |
| Permissions | Every site, tabs, history, sessions, the clipboard and tab groups; bookmarks, downloads and cookies on request | Accessibility; Automation of each Chromium browser to list its tabs |
| Hints from | The page's DOM, with per-site rules | The Accessibility tree |
| Search | The Vomnibar: URLs, bookmarks, history and open tabs | The flashlight: every browser's tabs, Chrome's and Firefox's history and bookmarks, apps, windows, plugin data |
| Key model | `map`, `mapKey`, `map!`, contextual mappings per site, command trees | NORMAL, INSERT and layers; sequences, counts, per-app tables |
| Configuration | The extension's options page | One TOML file, live reload, `flash config check` |
| Maintenance | 2.12 in the stores, April 2025; quiet since | 1.1.0, October 2026 |

## Where Vimium C is stronger

- **Per-site behaviour.** Contextual mappings give a key a different command
  on different websites; Flash's tables go per app, never per URL.
- **More commands for the page and its tabs.** `<a-f>` opens several links
  in new tabs, `]]` and `[[` follow "next" and "previous" links, `gu`, `gU`
  and `ge` climb and edit the URL, `gf` cycles frames, `yt` duplicates a
  tab, `W` moves it to a new window, `<a-p>` pins it and `^` returns to the
  previous one. Flash has no command for any of these yet.
- **Visual and caret modes** inside the page (`v`, `V`, `yc`), with yanks
  and paste-and-go.
- **Command trees.** One key can run a whole tree of commands; each Flash
  mapping runs one command.
- **Reach into other extensions.** It can run inside extensions that accept
  it, and its PDF viewer makes PDFs keyboard-driven.
- **Light and portable.** It runs in the browser with no system permission,
  on Windows and Linux as well.

## Where Flash is stronger

- **The browser around the page.** The address bar, tabs, toolbar
  buttons, menus and dialogs take the same `f`, and so do the browser's own pages (settings, the extension store, the new tab
  page) where it exposes them to Accessibility; an extension is not allowed
  to run on most of those.
- **Every browser at once.** The same keys work in Chrome, Edge, Brave, Arc,
  Vivaldi, Opera, Firefox and Safari without installing anything in them,
  and `@tabs` lists all their tabs in one search.
- **Every other app.** `f`, `gt` and `ctrl+w h` do the same in Finder, a
  terminal or Xcode, and NORMAL stays on as you switch.
- **Not tied to the extension platform.** Flash reads the browser through
  macOS Accessibility, so a browser's next extension API change asks nothing
  of it.

## Flash features you might like

- `!ch` and `!cb` search Chrome's history and bookmarks, `@history` and
  `@bookmarks` every browser's, without opening a tab
  ([flashlight](../flashlight.md#narrow-to-a-resource-type)).
- `mouse target --search` picks a target by typing its visible text, when
  labels alone are too many.
- `mouse target --copy-url` for `yf`, `url copy` for `yy`; both ship
  unbound ([Coming from Vim](../vim.md#from-vimium)).
- Counts: `3gt` (or `g3`) is the third tab, `3]t` three tabs on, `3.` the
  last command three times.

## Moving from Vimium C

Flash's defaults follow Vimium, which Vimium C keeps, so `f`, `J`/`K`,
`gt`/`gT`, `g0`/`g$`, `t`, `x`/`X`, `H`/`L`, `r`, `gs`, `gi`, `/`, `n`/`N`
and `gg`/`G` need nothing. The rest:

| Vimium C | Flash |
| --- | --- |
| `F` (new tab) | `f`, holding Command on the last label key |
| `<a-f>` (several links) | `mouse target --multi`; Escape ends |
| `d`, `u` (half page) | `ctrl+d`, `ctrl+u`; Flash's `d` is the double-click prefix and `u` the app's undo |
| `ng0` (the n-th tab) | `3gt` or `g3` |
| `T` (search tabs) | `mode flashlight --query=@tabs` |
| `o`, `b` (Vomnibar) | `mode flashlight --query=@history`, `--query=@bookmarks` |
| `yy`, `yf` | `url copy`, `mouse target --copy-url` |
| `v`, `V` (visual) | HOLD (⌘⌃H): `w`, `b`, `e`, `0`, `$` extend a held selection, `y` copies ([HOLD](../hold-mode.md)) |
| `ma`, `` `a `` | Flash's marks remember an app, not a scroll position ([marks](../marks.md)) |
| `]]`, `[[`, `gu`, `gU`, `ge`, `yt`, `W`, `<a-p>`, `^` | Nothing yet |
| `map`, `unmap` | `[mode.normal.mappings]`; `false` removes a default |
| Contextual mappings | Per browser: `[mode.apps."com.google.Chrome".normal.mappings]` |
| `mapKey` for another layout | `[keyboard] layout` and `[app] keyboard_layout` ([logical layout](../configuration.md#logical-layout)) |
| Command trees | A `q`/`@` macro of Flash commands, or a script running several `flash` commands |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]

[mode.normal.mappings]
"T" = ["flash", "mode", "flashlight", "--query=@tabs"]
"b" = ["flash", "mode", "flashlight", "--query=@bookmarks"]
"yy" = ["flash", "url", "copy"]  # y alone (copy) now waits for a second key
"yf" = ["flash", "mouse", "target", "--copy-url"]
"<leader>f" = ["flash", "mouse", "target", "--multi"]

[mode.apps."com.google.Chrome".normal.mappings]
"<leader>h" = ["flash", "mode", "flashlight", "--query=!ch"]
```

## Using both

They never fight over a key, because only one of them hears it at a time.
In NORMAL, Flash swallows every key it does not map before the browser sees
it, so Vimium C is silent; in INSERT every key reaches the page and Vimium C
behaves as it always has ([what NORMAL swallows](../normal-mode.md#what-normal-swallows)).
Removing a Flash key with `false` does not pass it on: it is swallowed all
the same.

So choose per moment rather than per key: Flash's NORMAL to get to the
browser, its tab and its toolbar; `i` for INSERT when you want Vimium C's
visual mode, frames or command trees inside the page; your NORMAL chord to
come back. Vimium C's global shortcuts are browser shortcuts, which Flash
leaves alone in INSERT; a Flash chord in `[mode.all.mappings]` takes
precedence over one bound to the same keys.

*Checked 2026-10-23 against the Vimium C
[README](https://github.com/gdh1995/vimium-c),
[release notes](https://github.com/gdh1995/vimium-c/blob/master/RELEASE-NOTES.md),
[manifest](https://github.com/gdh1995/vimium-c/blob/master/manifest.json) and
commit history, and its
[Firefox Add-ons](https://addons.mozilla.org/firefox/addon/vimium-c/) and
[Edge Add-ons](https://microsoftedge.microsoft.com/addons/detail/aibcglbfblnogfjhbcmmpobjhnomhcdo)
listings.*
