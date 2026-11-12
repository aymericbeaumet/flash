# Flash and Tridactyl

[Tridactyl](https://github.com/tridactyl/tridactyl) sets out to "Replace
Firefox's default control mechanism with one modelled on the one true
editor, Vim." It carries on the Vimperator and Pentadactyl tradition inside a
modern Firefox extension: a normal mode, hint modes, and an ex command line
through which every one of its functions runs, with `:bind`, `:set`, a
`.tridactylrc`, autocmds, and an optional native messenger that edits text
areas in your editor and reaches `about:` pages. It is Apache-2.0 and free,
about 6,400 stars, with stable 1.25.1 on 8 September 2026 after a large
1.25.0 on 28 August, and commits landing in October 2026. It runs wherever
desktop Firefox does (Firefox Add-ons lists 94 and later).

Tridactyl and Flash only meet in Firefox, and they meet from opposite sides:
Tridactyl from inside the page, Flash from outside the browser, through
macOS Accessibility.

| | Tridactyl | Flash |
| --- | --- | --- |
| License, price | Apache-2.0, free | MIT, free |
| Platforms | Firefox 94+ on macOS, Windows and Linux | macOS 13+ |
| Permissions | Extension access to every site, tabs, history, bookmarks, cookies, downloads, proxy settings and native messaging | Accessibility; Firefox's tabs need no Automation grant |
| Where it works | Firefox's web pages; not `about:`, `view-source:`, `data:`, most `file:` pages or addons.mozilla.org | Every app; in Firefox, the page and the toolbar, tab strip, menus and dialogs around it |
| Hints from | The page's DOM, with extended modes (`;y`, `;i`, `;s` …) and CSS selectors (`:hint -c`) | The Accessibility tree |
| Command line | Ex commands for everything, with completions, `:help`, `:tutor` | `:` for Flash's commands and Vim's ex aliases; the flashlight for tabs, history and bookmarks |
| Configuration | `:bind`, `:set`, `.tridactylrc`, autocmds | One TOML file, live reload, `flash config check` |
| Maintenance | 1.25.1, September 2026; active | 1.1.0, October 2026 |

## Where Tridactyl is stronger

- **It knows the page.** Extended hint modes copy a link (`;y`), open or save
  an image (`;i`, `;S`), save a linked resource (`;s`), read an element
  aloud (`;r`) or delete it (`;k`), and `:hint -c <selector>` makes a
  site-specific hint mode. `[[` and `]]` follow pagination links in many
  languages, `gu` and `gU` climb the URL, `]c` increments it, quickmarks
  (`M<key>`, `go<key>`) and page marks remember places. Flash copies a link
  or an element's text with a label and has none of the rest.
- **It drives Firefox itself.** Containers (`:containercreate`,
  `:recontain`), hidden tabs, `:tabclose --match`, `guiset` to strip
  Firefox's interface, and autocmds such as `DocFocus` and `ModeEnter` that
  run commands per page or per mode. Flash sees Firefox as one app among
  others and reaches none of those internals.
- **Text areas in your editor.** With the native messenger, a text area
  opens in Vim or any editor and comes back filled. Flash edits no text.
- **A command language.** `:composite` chains commands, every key is an ex
  command you can rebind, and `:help`, `:apropos` and `:tutor` teach them in
  the browser. Flash's mappings run one command each.
- **Every desktop.** The same `.tridactylrc` works on Windows and Linux, and
  it needs no system permission.

## Where Flash is stronger

- **Around the page.** The address bar, tab strip, toolbar buttons, menus
  and dialogs take the same `f`, and so do Firefox's own `about:` pages and
  the add-ons site, the places Tridactyl's README says it cannot run,
  wherever Firefox exposes them to Accessibility.
- **Nothing inside the page.** Tridactyl's FAQ opens with sites it breaks or
  blanks; Flash runs no content script, so a page renders exactly as it would
  without it.
- **Firefox next to everything else.** `]t` is the next Firefox tab, then the
  next tmux window when you switch to a terminal, with NORMAL still on. The
  flashlight lists Firefox's tabs beside Safari's and Chrome's, read from
  Firefox's tab strip and session file with no add-on
  ([privacy](../privacy.md#data-read-from-other-apps)).
- **Firefox's history and bookmarks from any app.** `!fh` and `!fb` search
  a local copy of Firefox's `places.sqlite`, not only from a Firefox tab.

## Flash features you might like

- `mouse target --copy-url` and `--copy-text` are `;y` and `;p`;
  `mouse target --multi` keeps the labels coming, as `gF` does, until Escape
  ([hints](../hints.md#choose-an-action)).
- Vim's ex aliases in `:`: `:tabn 3`, `:tabm +1`, `:q` closes the tab, `:so`
  reloads the configuration, `:norm 3gt` runs keys
  ([aliases](../commands.md#vim-command-line-aliases)).
- `.` repeats the last command, `q{x}` records a macro of Flash commands and
  `@{x}` plays it, in Firefox or any app.
- HOLD (⌘⌃H) is a visual mode for any app: `w`, `b`, `e`, `0` and `$`
  extend a held selection and `y` copies it ([HOLD](../hold-mode.md)).

## Moving from Tridactyl

Flash's defaults already follow Vimium, so most Tridactyl keys land where
your fingers expect them; [Coming from Vim](../vim.md#from-vimium) has the
whole list. The ones that differ:

| Tridactyl | Flash |
| --- | --- |
| `f` | `f` in NORMAL, from Accessibility |
| `F` (background tab) | `f`, holding Command on the last label key |
| `gF` (keep following links) | `mouse target --multi`; Escape ends |
| `;y`, `;p` | `mouse target --copy-url`, `mouse target --copy-text` |
| `yy` | `url copy` (unbound: a `yy` makes `y` wait for the second key) |
| `gi` | `gi` focuses the first text field and keeps NORMAL, as `f` on a field does; `i` then types |
| `d`, `u` (close, undo close) | `x`, `X`; Flash's `u` is the app's undo and `d` the double-click prefix |
| `b` (tab list) | `mode flashlight --query=@tabs`: every browser's tabs |
| `o`, `t` with history completion | `t` opens a tab; `!fh` and `!fb` search Firefox's history and bookmarks |
| `<C-^>` (last tab) | Nothing yet |
| `zi`, `zo`, `zz` | `zi`, `zo`, `z0` |
| `/`, `n`, `N` | The same, as Firefox's own Find; press `i` to type the query |
| Quickmarks (`go<key>`) | A NORMAL sequence that opens the URL in Firefox |
| Page marks (`` `a ``) | Flash's marks remember an app, not a scroll position ([marks](../marks.md)) |
| `[[`, `]]`, `gu`, `gU`, `]c` | Nothing |
| `:bind`, `.tridactylrc` | `[mode.normal.mappings]`, and `[mode.apps."org.mozilla.firefox".normal.mappings]` for Firefox only |
| `:set` | Keys in `flash.toml`, applied on save and checked by `flash config check` |
| Autocmds | A [monitor](../monitors.md#runs-and-events) on `core:focus.changed` with `app = "org.mozilla.firefox"`; nothing per URL |
| Native editor, containers, `guiset` | Nothing; keep Tridactyl for them |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+shift+space" = ["flash", "mouse", "target"]

[mode.normal.mappings]
"yy" = ["flash", "url", "copy"]
";y" = ["flash", "mouse", "target", "--copy-url"]
";p" = ["flash", "mouse", "target", "--copy-text"]
"gF" = ["flash", "mouse", "target", "--multi"]
"b" = ["flash", "mode", "flashlight", "--query=@tabs"]

[mode.apps."org.mozilla.firefox".normal.mappings]
"gog" = ["/usr/bin/open", "-a", "Firefox", "https://github.com"]
```

## Using both

Flash's NORMAL holds the keyboard: every key it does not map is swallowed
before Firefox sees it ([what NORMAL swallows](../normal-mode.md#what-normal-swallows)),
so Tridactyl is silent while NORMAL is on, and removing a Flash key with
`false` does not hand it to Tridactyl. In INSERT every key reaches Firefox,
so Tridactyl's normal mode, hints and ex line work as if Flash were not
there. That gives a clean split:

- Flash's NORMAL for moving between apps, windows and tabs, and for
  Firefox's toolbar and dialogs.
- `i` (INSERT) when you want Tridactyl inside a page; your NORMAL chord
  (`cmd+ctrl+[` above) to come back. Flash never switches mode by itself
  when Firefox comes forward.
- Chords in `[mode.all.mappings]` work in both, so `cmd+shift+space` above
  still labels Firefox's toolbar while Tridactyl owns the page. Tridactyl's
  defaults sit on bare keys and Shift, Control and Alt chords, which
  Command-Control and Command-Shift chords leave alone.

*Checked 2026-10-23 against the Tridactyl
[README](https://github.com/tridactyl/tridactyl),
[changelog](https://github.com/tridactyl/tridactyl/blob/master/CHANGELOG.md),
[license](https://github.com/tridactyl/tridactyl/blob/master/LICENSE) and
[manifest](https://github.com/tridactyl/tridactyl/blob/master/src/manifest.json),
and its [Firefox Add-ons listing](https://addons.mozilla.org/firefox/addon/tridactyl-vim/).*
