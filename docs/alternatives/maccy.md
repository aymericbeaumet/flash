# Flash and Maccy

[Maccy](https://maccy.app) is a "Lightweight clipboard manager for macOS"
that "does one job - keep your copy history at hand. Period." Press
Shift-Command-C, type a few letters, press Return: that is the whole
product, and it is very good at it. Maccy is MIT-licensed Swift from the
GitHub user p0deje, about 22,000 stars, free from GitHub and Homebrew and
$9.99 on the Mac App Store for those who want to pay for the same app. It
needs macOS 14 or later. 2.7.0 (July 2026) added a slide-out preview with
text recognition in images, and 2.7.1 followed on 10 August 2026.

Flash keeps a clipboard history too, in its core rather than in a plugin,
and searches it from the flashlight with `!clip`. If Maccy is the only
clipboard tool you have ever needed, this page says what you would gain and
lose by letting Flash take over, and how to keep both if you prefer.

| | Maccy | Flash |
| --- | --- | --- |
| License, price | MIT, free; $9.99 on the App Store | MIT, free |
| Platforms | macOS 14+ | macOS 13+ |
| Permissions | Accessibility, only to paste for you | Accessibility |
| Keeps | Text, rich text, images, files; 200 entries by default | Text, formatted text, images, file copies; 1,000 by default, up to 10,000 |
| Search | Exact (default), fuzzy, regular expression or mixed | Typo-tolerant ranking on the first line and the text after it |
| Skips | Concealed, transient and auto-generated types; 1Password, KeeWeb and any type you add; apps you list; a regular expression; pause, or skip the next copy | Concealed, transient and auto-generated items; nothing else to configure |
| Pins | Option-P; each pin gets a permanent key | `<cmd-p>`; pins list first and are never trimmed |
| Configuration | Settings window, `defaults` keys | One TOML file, live reload, `flash config check` |
| Maintenance | 2.7.1, August 2026 | 1.1.0, October 2026 |

## Where Maccy is stronger

- **Control over what is recorded.** Maccy ignores the apps you list (or
  every app except them), any pasteboard type you add, and text matching a
  regular expression. Option-click its menu-bar icon to stop recording,
  Option-Shift-click to skip only the next copy. Flash skips the same
  concealed, transient and auto-generated items and nothing more: no
  per-app list, no pattern, no pause.
- **Search modes.** A regular expression or an exact substring finds an
  entry the way you remember it; Flash's matching is fuzzy and ranked.
- **The preview.** Control-Space slides out a panel with the whole entry,
  the image's dimensions, a colour swatch for a hex value, and a button
  that copies the text recognised in an image. Flash's row shows the first
  line, or `Image 1280×800 PNG`.
- **Pins on a key.** A pinned item gets a permanent shortcut in the popup,
  so a pin is two keystrokes away. Flash's pins come first in the
  list, but you still pick them.
- **Clear on quit**, and an option to clear the system clipboard along with
  the history, for people who keep nothing between sessions.
- **A small, single-purpose app** with years of reports behind it, a native
  settings window, and nothing else to learn.

## Where Flash is stronger

- **It pastes like the app expects.** Flash puts the entry back in the
  formats it was copied with and runs the focused app's own paste command,
  so a terminal receives its paste shortcut rather than typed text. With
  `--restore-mode`, a flashlight opened while you were typing returns you
  to INSERT.
- **One search box.** `!clip` sits in the same flashlight as apps, tabs,
  windows, tmux windows and plugin data, and `@clipboard` adds the named
  registers to the history.
- **Registers next to the history.** In NORMAL, `"ay` yanks into register
  `a` and `"ap` pastes it, as in Vim, without touching the clipboard
  history ([normal mode](../normal-mode.md#default-keys-in-detail)).
- **Scriptable.** `flash clipboard show --offset=0` prints entries and their
  ids as JSON, and `flash clipboard restore --id=<id> --paste` pastes one,
  from any shell script or mapping.
- **A larger history** of up to 10,000 entries, every one searchable on the
  Clipboard page of the browser help.

## Flash features you might like

- `<shift-cr>` pastes plain text, as Option-Shift-Return does in Maccy, and
  `<alt-cr>` only puts the entry back on the clipboard, Maccy's Return.
- `flash clipboard show` opens the Clipboard page: every entry, a search box,
  `p` to pin, `⌫` to delete ([clipboard](../clipboard.md)).
- `selection copy --register=a` and `register paste --register=a` as
  mappings, for text you reuse within a session.
- The snippets plugin types saved text into the focused app from
  `@snippets`, for the entries you keep pinned forever.

## Moving from Maccy

[Moving from Maccy or Clipy](../clipboard.md#moving-from-maccy-or-clipy)
covers the everyday keys. In full:

| Maccy | Flash |
| --- | --- |
| Shift-Command-C opens the history | A mapping to `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| Type to search | The same; exact and regular-expression modes are not available |
| Return copies, Option-Return pastes | `<alt-cr>` copies, `<cr>` pastes |
| Option-Shift-Return pastes without formatting | `<shift-cr>` |
| Option-P pins or unpins | `<cmd-p>`, `p` on the Clipboard page, `flash clipboard pin --id=<id>` |
| Option-Delete deletes an item | `⌫` on the Clipboard page, `flash clipboard delete --id=<id>` |
| History size (200 by default) | `[clipboard] history_size`, 1 to 10,000 |
| Ignored types: concealed, transient, auto-generated | Built in |
| Ignored apps, regular expressions, pause | Not available |
| Control-Space preview, text from images | Not available |
| Clear on quit | Not available; delete entries on the Clipboard page |

Keep Maccy's chord, so your hands do not have to relearn it:

```toml
[clipboard]
history_size = 200  # Maccy's default; raise it as far as 10000

[mode.all.mappings]
"cmd+shift+c" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

A chord in `[mode.all.mappings]` is taken from every app, as Maccy took it;
choose another if an app you use needs Shift-Command-C.

## Using both

They can run together, but both then record every copy, so the history
lives twice on your disk. If you keep Maccy for its ignore lists and give
Flash only the paste-into-terminal job, two settings keep them apart:

- Give each its own chord: Maccy keeps Shift-Command-C, Flash takes another
  one such as `cmd+ctrl+v`.
- When Flash pastes an entry it marks the clipboard with its own type,
  `com.flash.app.clipboard-entry`. Add that type to Maccy's ignored
  pasteboard types (Preferences › Ignore › Pasteboard Types), and a paste
  from Flash no longer shows up in Maccy as a new copy.

Otherwise quit Maccy once you have moved, so that only one of them records.

*Checked 2026-10-23 against [maccy.app](https://maccy.app), the Maccy
[README](https://github.com/p0deje/Maccy), its
[releases](https://github.com/p0deje/Maccy/releases) and
[settings defaults](https://github.com/p0deje/Maccy/blob/master/Maccy/Extensions/Defaults.Keys%2BNames.swift),
and the [App Store listing](https://apps.apple.com/us/app/maccy/id1527619437).*
