# Flash and Clipy

[Clipy](https://github.com/Clipy/Clipy) is a "Clipboard extension app for
macOS": a clipboard history and a library of snippets, each opened as a
native menu from its own shortcut. It descends from naotaka's ClipMenu,
whose code was published as open source, and is maintained by Econa77.
After about eight years without a release, development restarted: 1.3.0
arrived in June 2026 for macOS 13 and later, moving its database from Realm
to SQLite, and 1.4.0 followed on 12 October 2026 with rebuilt settings, HTML
copies, automatic history deletion and a Universal Clipboard exclusion.
Clipy is MIT, free, about 8,900 stars.

Flash's [clipboard history](../clipboard.md) is a search box rather than a
menu, and its snippets come from a plugin. This page is for Clipy users
deciding whether to move both, or neither.

| | Clipy | Flash |
| --- | --- | --- |
| License, price | MIT, free; donations | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility, to paste | Accessibility |
| History | Text, images, HTML and other formats, in a menu; automatic deletion settings | Text, formatted text, images, file copies; up to 10,000 entries, searched |
| Snippets | Folders of snippets in a menu (Shift-Command-B), an editor, XML import and export | The snippets plugin: one TOML or JSON file, searched with `@snippets`, typed into the app |
| Skips | Apps you exclude, Universal Clipboard copies, whitespace-only text | Concealed, transient and auto-generated items |
| Network | Update checks; Firebase analytics and crash reports, on by default, off in Preferences | No analytics; release checks and the plugin requests [privacy](../privacy.md#network) lists |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | 1.4.0, October 2026; restarted in 2026 | 1.1.0, October 2026 |

## Where Clipy is stronger

- **Snippets are first-class.** Folders, an editor with its own global
  shortcut, snippets above the history if you like, and an XML export that
  other apps read. Flash's snippets are a flat list of names in a file you
  edit yourself, with no folders and no editor.
- **A menu needs no typing.** Shift-Command-V, an arrow or a number, and the
  item is pasted. Some people never want a search box; Clipy suits them
  better than Flash's flashlight does.
- **Excluded apps.** Clipy ignores the apps you list, and Universal
  Clipboard copies from your other devices if you ask. Flash skips only what
  apps mark as concealed, transient or auto-generated.
- **Automatic history deletion**, where Flash only keeps a number of
  entries.
- **macOS 13** is enough; Flash needs 14.

## Where Flash is stronger

- **Search instead of a menu.** Type a few letters of an entry from last
  week, among up to 10,000, and it is there; the flashlight ranks matches as
  you type.
- **No analytics.** Clipy's privacy notice says Firebase Analytics and
  Crashlytics are on by default (they can be turned off in Preferences).
  Flash collects nothing, and its [privacy page](../privacy.md) lists every
  network request it makes.
- **A paste terminals accept.** Flash runs the focused app's own paste
  command, so a terminal receives its paste shortcut.
- **Pins and registers.** `<cmd-p>` pins an entry so trimming never drops
  it, and NORMAL's `"ay` / `"ap` keep text in named registers.
- **Scriptable.** `flash clipboard show --offset=0` prints entries as JSON;
  `flash clipboard restore --id=<id> --paste` pastes one.

## Flash features you might like

- `@clipboard` lists pins, the history and the named registers in one list.
- `<shift-cr>` pastes plain text only, and `<alt-cr>` puts an entry back on
  the clipboard without pasting.
- `@snippets` is one flashlight type among the others, so a snippet, an app
  and a browser tab are one search apart
  ([flashlight](../flashlight.md#narrow-to-a-resource-type)).
- The Clipboard page of the browser help (`flash clipboard show`) shows
  images and file copies, and deletes entries with `⌫`.

## Moving from Clipy

| Clipy | Flash |
| --- | --- |
| Shift-Command-V main menu, Control-Command-V history | A mapping to `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| Walk the menu, press a number | Type a word of the entry, then `<cr>` |
| Shift-Command-B snippets menu | A mapping to `["flash", "mode", "flashlight", "--query=@snippets", "--restore-mode"]` |
| Snippet folders | One flat list in a snippets file; give related snippets a shared word to find them together |
| Snippet editor, XML import and export | Edit the file; convert an XML export once, by hand or with a script |
| Excluded apps, Universal Clipboard exclusion | Not available |
| Automatic deletion | `[clipboard] history_size`, a number of entries |
| Paste as plain text | `<shift-cr>` |
| Clipy snippets as pins | `<cmd-p>` on a `!clip` row |

The snippets plugin reads a file of names and texts, TOML or JSON, one
`name = text` entry each at its top level:

```text
# ~/.config/flash/snippets.toml
"mail signature" = "Best regards,\nCamille"
"mail address" = "12 rue de la Paix, Paris"
```

and Clipy's two chords become:

```toml
[plugins.snippets]
file = "~/.config/flash/snippets.toml"

[mode.all.mappings]
"cmd+shift+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+shift+b" = ["flash", "mode", "flashlight", "--query=@snippets", "--restore-mode"]
```

Picking a snippet types its text into the focused app. The plugin rereads
the file when the configuration reloads, so run `flash config reload` after
editing it.

## Using both

Clipy's snippet menus can stay with Clipy while Flash owns the history:
keep Shift-Command-B for Clipy's snippets and map Flash's `!clip` to a chord
Clipy does not use, such as `cmd+ctrl+v`. Both histories then record every
copy, so set Clipy's automatic deletion short if you only keep it for the
snippets. Flash's `[mode.all.mappings]` take a chord from every app, exactly
as Clipy's shortcuts do, so the two must never share one.

*Checked 2026-10-23 against the Clipy
[repository](https://github.com/Clipy/Clipy), its
[releases](https://github.com/Clipy/Clipy/releases) (1.3.0 and 1.4.0) and
[privacy notice](https://github.com/Clipy/Clipy/blob/master/PRIVACY.md), and
[clipy-app.com](https://clipy-app.com).*
