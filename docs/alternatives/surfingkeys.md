# Flash and Surfingkeys

[Surfingkeys](https://github.com/brookhong/Surfingkeys) lets you "Map your
keys for web surfing, expand your browser with javascript and keyboard".
It is an MIT extension for Chrome, Firefox, Edge and Safari 15+, configured
in a JavaScript file, with about 6,200 stars and monthly commits. Like
Vimium it works only inside web pages; unlike Vimium it is a small
programming environment.

| | Surfingkeys | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Where it works | Web pages, including Safari | Every macOS app |
| Hints from | The DOM | The Accessibility tree |
| Extras | Visual mode, omnibar, Vim and Emacs editors for text fields, PDF viewer, markdown preview, sessions, LLM chat | NORMAL mode across apps, flashlight, bar, widgets, popups, plugins |
| Configuration | `~/.surfingkeys.js`, custom JS functions on keys | One TOML file, no code |
| Permissions | Extension permissions (all URLs, native messaging, cookies, downloads, history) | Accessibility; Automation per browser for tab lists |

## Where Surfingkeys is stronger

- **Programmable.** A key can run any JavaScript against the page.
- **Safari support** as an extension, and a PDF viewer, markdown preview and
  an in-browser editor for text fields.
- **Richer in-page hints** (DOM, text filtering) and visual mode.

## Where Flash is stronger

- **Every app, and the browser chrome**: the address bar, tab strip,
  settings pages and Web Store that no extension can touch.
- **No code to maintain.** HN users describe configuring Surfingkeys as
  "managing a personal browser extension"; `flash.toml` is a list of keys.
- **The same keys outside the browser**, and everything after the click.

## Flash features you might like

- Plugins are the programmable layer: a plugin in any language adds
  catalogs, actions and status values ([cookbook](../plugin-cookbook.md)).
- `[mode.apps."<bundle id>"]` tables give per-browser keys without
  conditions in code.
- Terminal popups show a TUI next to the page, under a bar segment.

## Moving from Surfingkeys

| Surfingkeys | Flash |
| --- | --- |
| `f` hints | `f` in NORMAL |
| `E` / `R` tabs | `[t` / `]t` |
| `x` close tab | Same |
| Omnibar | `:flashlight` |
| `api.mapkey` in JS | `[mode.normal.mappings]` in TOML |
| Custom JS actions | A plugin, or a mapping that runs any executable |

Unmap `f` for the browser in whichever tool you keep for in-page hints, as
in the [Vimium page](vimium.md).

*Checked 2026-10-14 against the Surfingkeys
[README](https://github.com/brookhong/Surfingkeys).*
