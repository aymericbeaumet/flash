# Flash and Paste

[Paste](https://pasteapp.io) promises "Everything you copy on every device":
an unlimited clipboard history on a visual timeline, pinboards you can share
with a team, a Paste Stack for copying several things and pasting them in
order, and iCloud sync between the Mac, iPhone and iPad. It is a closed,
subscription app from the Paste Team: $3.99 a month or $29.99 a year, or
$99.99 once for a lifetime licence, each covering every Apple device you
sign in with, after a seven-day trial. It is also in Setapp. Version 7.0.3
shipped on the App Store in October 2026 and needs macOS 14 or later.

Flash's [clipboard history](../clipboard.md) stays on one Mac and has none
of the sync or sharing. What it offers a Paste user is a free history in the
same search box as everything else, with a paste that terminals accept.

| | Paste | Flash |
| --- | --- | --- |
| License, price | Closed; $3.99/month, $29.99/year or $99.99 lifetime; Setapp | MIT, free |
| Platforms | macOS 14+, iPhone, iPad | macOS 13+ only |
| Permissions | Accessibility, to paste into apps and for the Paste Stack | Accessibility |
| History | Unlimited, kept as long as Keep History says; text, links, images | Up to 10,000 entries; text, formatted text, images, file copies |
| Organising | Pinboards, shared pinboards, filters by type, app, device and date, text inside images, editing and renaming | Pins listed first and never trimmed; named registers in NORMAL |
| Pasting | Return, Shift-Return for plain text, Command-1 to 9, the Paste Stack | `<cr>`, `<shift-cr>` for plain text, through the app's own paste command |
| Sync | iCloud, across Mac, iPhone and iPad | None |
| Configuration | Settings window; four rebindable shortcuts | One TOML file, live reload, `flash config check` |
| Maintenance | 7.0.3, October 2026; active | 1.1.0, October 2026 |

## Where Paste is stronger

- **Your history on every device.** What you copy on the Mac is on the
  iPhone, and the other way round, through your private iCloud. Flash's
  history never leaves the Mac it was copied on.
- **Pinboards and teams.** Named, coloured pinboards for templates, links
  and colours, shared with other people through Paste for Teams. Flash has
  one list of pins, for you alone.
- **The Paste Stack.** Shift-Command-C, copy three things, then Command-V
  three times pastes them in order. Flash has nothing like it.
- **Finding by more than words.** Filters by content type, source app,
  device and date, and search over the text inside screenshots. Flash
  searches an entry's text only.
- **Editing.** Edit an entry in place (Command-E), rename it, rotate an
  image, extract its text, or run Writing Tools on it. Flash stores what was
  copied and never changes it.
- **Quick Paste.** Command-1 to Command-9 paste the newest items without
  searching.
- **Time-based retention, pause and ignored apps.** Keep History sets how
  long items stay, Command-T pauses recording, and Settings › Privacy blocks
  the apps you name. Flash counts entries (`[clipboard] history_size`),
  never pauses, and skips only what apps mark as concealed, transient or
  auto-generated.

## Where Flash is stronger

- **Free and open source,** with no subscription and no account. Paste's
  App Store privacy label lists usage data and diagnostics collected for
  analytics; Flash has no analytics, and its [privacy page](../privacy.md)
  lists every file it writes.
- **One search for everything.** `!clip` is a word in the flashlight that
  also finds apps, tabs, windows and tmux windows; `@clipboard` adds the
  named registers to the history.
- **A paste terminals accept.** Flash runs the focused app's own paste
  command, so a terminal receives its paste shortcut, never typed text.
- **Scriptable.** `flash clipboard show --offset=0` prints entries as JSON,
  and `flash clipboard restore --id=<id> --paste` pastes one, so a shell
  script can reach the history.
- **Keyboard first, end to end.** Open, search, pin (`<cmd-p>`) and paste
  without the pointer, and return to the mode you came from.

## Flash features you might like

- Named registers: `"ay` yanks a selection into `a`, `"by` into `b`, and
  `"ap` `"bp` paste them back, the nearest Flash gets to a Paste Stack
  ([normal mode](../normal-mode.md#default-keys-in-detail)).
- The snippets plugin types saved text into the focused app from
  `@snippets`, for the templates you keep on a pinboard.
- The Clipboard page of the browser help (`flash clipboard show`) searches
  every entry, not just the newest thousand, and pins or deletes them.
- `<alt-cr>` puts an entry back on the clipboard without pasting, when you
  want to paste it yourself.

## Moving from Paste

| Paste | Flash |
| --- | --- |
| Shift-Command-V opens Paste | A mapping to `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| Return pastes, Shift-Return pastes plain text | `<cr>`, `<shift-cr>` |
| Command-F, then type | Type at once; the flashlight is a search box |
| Pinboards | Pins (`<cmd-p>`), listed first by `!clip` and `@clipboard` |
| Shared pinboards | Not available |
| Paste Stack (Shift-Command-C) | Not available; named registers come closest |
| Command-1 to Command-9 | Not available; type a word of the entry |
| Filters by app, type, device, date | Not available |
| Edit, rename, extract text | Not available |
| Keep History | `[clipboard] history_size`, a number of entries |
| Pause, ignored apps | Not available |
| iCloud sync | Not available; keep Paste for it |

Keep the chord you know:

```toml
[clipboard]
history_size = 10000

[mode.all.mappings]
"cmd+shift+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

Paste already takes Shift-Command-V from every app, which many use for
Paste and Match Style; Flash's mapping takes it the same way.

## Using both

Keeping Paste for the iPhone and the shared pinboards is reasonable; the
cost is that both record every copy on the Mac, since Flash's history has no
off switch. Give them different chords (Paste keeps Shift-Command-V, Flash
takes `cmd+ctrl+v`) and use each for what it does best: Paste for anything
that has to reach another device or another person, Flash's `!clip` when you
are already in the flashlight or pasting into a terminal. Both need the
Accessibility grant, and neither gets in the other's way.

*Checked 2026-10-23 against [pasteapp.io](https://pasteapp.io), its
[pricing](https://pasteapp.io/pricing), the help pages on
[Paste on Mac](https://pasteapp.io/help/paste-on-mac),
[keyboard shortcuts](https://pasteapp.io/help/keyboard-shortcuts),
[Paste Stack](https://pasteapp.io/help/using-paste-stack) and
[pasting into other apps](https://pasteapp.io/help/paste-directly-to-other-applications),
and the [App Store listing](https://apps.apple.com/us/app/paste-clipboard-manager/id967805235).*
