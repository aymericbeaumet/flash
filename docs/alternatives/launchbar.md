# Flash and LaunchBar

[LaunchBar](https://www.obdev.at/products/launchbar/) is Objective
Development's launcher, "Unleashed productivity." in its own words: type a
few letters of anything it has indexed (apps, documents, bookmarks,
contacts, music, Shortcuts) and it learns which item you meant. It is one of
the oldest tools of its kind, begun on NeXTSTEP and on the Mac since 2001,
and it is still maintained: version 6.24 shipped on 27 April 2026, after
6.22 and 6.23 brought macOS 26 Tahoe support. It is closed source, with a
30-day trial after which it stays usable for free but "occasionally invites
you to take a short break"; a Single or Family licence removes the breaks.

Flash's flashlight covers part of the same ground (apps, files by name,
clipboard history, calculations, web searches) and adds what is on screen
now: browser tabs, windows and tmux windows. It does not try to be
LaunchBar's object browser, and this page says where that leaves you.

| | LaunchBar | Flash |
| --- | --- | --- |
| License, price | Closed; free after the trial with occasional break prompts, a Single or Family licence removes them | MIT, free |
| Platforms | 6.24 runs on macOS 26 and, per its download page, Sequoia, Sonoma, Ventura and Monterey; older versions for earlier systems | macOS 13+ |
| Permissions | Accessibility for Instant Send and the Finder selection; Full Disk Access to index Safari bookmarks; Automation of Finder for Empty Trash | Accessibility; Automation per browser to list tabs; Notes, Reminders and Contacts on their first search |
| Finding | Abbreviations that adapt to your choices, over an index you tune with indexing rules; Right Arrow browses folders, contacts, bookmarks and recent items | Typo-tolerant search with frecency over apps, tabs and tmux windows; `@windows`, `@menus`, `@notes`, `@reminders`, `@contacts`, `@emojis`, `@shortcuts`; files by name with `!f` |
| Acting | Instant Send of a selection to an app, contact or search template; script actions in AppleScript, JavaScript, Ruby, Python or PHP; a `bc` calculator; clipboard history with ClipMerge; snippets; new events and reminders | Every Flash command from `:`; about 14,500 bangs resolved on the Mac; arithmetic, units, currencies, colours and world clocks; `!clip`; `@snippets`; `menu choose` for scripts |
| Beyond the launcher | File actions on what you browse to | Hints, NORMAL mode, window placement, status bar, widgets, popups |
| Configuration | Settings window, index rules, an Actions editor | One TOML file, live reload, `flash config check` |
| Maintenance | 6.24, April 2026; macOS 26 support in 6.22 and 6.23 | 1.1.0, October 2026 |

## Where LaunchBar is stronger

- **Abbreviations that learn.** Type `T`, get TextEdit, pick Terminal
  instead, and `T` means Terminal from then on; Assign Abbreviation (⌘⌥A)
  pins one by hand. Flash ranks by how the query hits a name and by
  frecency, so what you open often rises, but you cannot assign a short form
  to one item. `[flashlight.aliases]` only rewrites literal tokens.
- **Instant Send.** Hold ⌘Space with text or files selected in any app and
  send them on: to Mail as an attachment, to a search template, to a
  contact. Flash has nothing like it; the flashlight never takes the
  selection.
- **Browsing.** Right Arrow walks into folders, contacts, bookmarks and
  recent items, and the file actions copy, move and rename what you reach.
  Flash finds a file by name and opens it; the rest is Finder's.
- **Creating things.** Calendar events and reminders typed into the bar.
  Flash lists open reminders and joins your next meeting, but it creates no
  event and no reminder.
- **ClipMerge**: press ⌘C twice and consecutive copies merge into one
  clipboard item. And actions written in half a dozen scripting languages
  with a long-documented format.
- **A lower macOS floor** and three decades of refinement.

## Where Flash is stronger

- **What is open now.** Browser tabs, windows on every Space Flash has
  seen, tmux windows and the frontmost app's menu items are rows, not only
  what is installed; and hints click everything the flashlight cannot reach.
- **Bangs on the Mac.** DuckDuckGo's and Kagi's bang lists turn `!w`, `!gh`
  or `!yt` into the site's own search URL locally, with no redirect through
  a search engine.
- **Text you can keep.** Sources, aliases, snippets and the keys that open
  them sit in `flash.toml`, in your dotfiles, checked by `flash config check`.
- **Free and open source**, with no break prompts.
- **One layer for the rest of the Mac:** a persistent NORMAL mode, window
  placement, a status bar and popups, configured in the same file.

## Flash features you might like

- `@menus` searches the frontmost app's menu items and presses the one you
  pick, so a command buried three menus deep is a few letters away.
- `menu choose` turns any list into a picker for a script, as a LaunchBar
  action that returns items would:
  `git branch --format='%(refname:short)' | flash menu choose | xargs git switch`.
- `@snippets` types a snippet from the file `[plugins.snippets] file` names,
  one `name = text` line each.
- `[flashlight.aliases]` gives your own short sigils: `"@t" = "@tabs"`.
- `Tab` or Return on a calculation copies the exact result.

## Moving from LaunchBar

| LaunchBar | Flash |
| --- | --- |
| ⌘Space | `"cmd+<space>" = ["flash", "mode", "flashlight"]` in `[mode.all.mappings]` once LaunchBar gives it up, or any other chord |
| An abbreviation (`SPF`) | Type it: letters in order still match, and frecency lifts what you open most |
| Assign Abbreviation | A NORMAL sequence to `app open --name=<app>` |
| Instant Send | Not available |
| Clipboard History | `!clip`, or `--query=!clip` on its own key |
| ClipMerge | Not available |
| Snippets | `@snippets`, fed by the file `[plugins.snippets] file` names |
| Calculator | Bare input: `1+1`, `2 km to m`, `10 euros` |
| Search templates | Bangs (`!w rust`); `[flashlight.aliases]` for your own spellings |
| Spotlight search from the bar | `!f quarterly report`, or `@files` |
| Script actions | A mapping to the script's argv; `menu choose` when it picks from a list; a [plugin](../plugin-cookbook.md) when it needs a catalog |
| Right Arrow into folders | Not available; `!f` finds by name |
| Contacts, reminders | `@contacts`, `@reminders` (open ones, to show; not to create) |
| Emoji, Shortcuts | `@emojis`, `@shortcuts` |
| Open Terminal Here, Terminal Interaction | tmux windows in the default rows; the terminal popup, `mode terminal` |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+<space>" = ["flash", "mode", "flashlight"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+ctrl+e" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]

[mode.normal.mappings]
"<leader>t" = ["flash", "app", "open", "--name=Terminal"]
"<leader>m" = ["flash", "app", "open", "--name=Mail"]

[flashlight.aliases]
"@t" = "@tabs"
"@m" = "@menus"

# name = text lines, one per snippet: sig = "Best regards,\nAda"
[plugins.snippets]
file = "~/.config/flash/snippets.toml"
```

`--restore-mode` brings you back to INSERT after a paste or an emoji, so
typing carries on where it was.

## Using both

They run side by side without trouble as long as each owns its own chord:
LaunchBar keeps ⌘Space and Instant Send, Flash takes another chord for the
flashlight. A common split is to leave LaunchBar the jobs it is unmatched
at (Instant Send, browsing, creating events) and use the flashlight for tabs,
windows, menus and bangs. If both keep a clipboard history, each records
every copy; turn one of them off, so a copied secret is stored once at most.

*Checked 2026-10-23 against LaunchBar's [product page](https://www.obdev.at/products/launchbar/index.html),
[features](https://www.obdev.at/products/launchbar/features.html),
[download page](https://www.obdev.at/products/launchbar/download.html),
[release notes](https://www.obdev.at/products/launchbar/releasenotes.html),
[licence terms](https://www.obdev.at/products/launchbar/order.html), and its help on
[abbreviation search](https://www.obdev.at/resources/launchbar/help/AbbreviationSearch.html)
and [Instant Send](https://www.obdev.at/resources/launchbar/help/InstantSend.html);
its history against [Wikipedia](https://en.wikipedia.org/wiki/LaunchBar).*
