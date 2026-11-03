# Flash and Spotlight

Spotlight is the launcher every Mac already has, and macOS 26 Tahoe made it
far more than a launcher. Command-Space now opens four views, Applications,
Files, Actions and Clipboard (Command-1 to Command-4); hundreds of system
and app actions run from the search field with their fields filled in
place (send a message, start a timer, remove an image's background, run a
Shortcut, choose an app's menu item); Quick Keys turn a few letters such as
`ft` into an action; and the Clipboard view keeps what you copied for 30
minutes, 8 hours or 7 days, a choice macOS 26.1 added. macOS 27 Golden Gate,
released in September 2026 for Apple silicon Macs, brought the new Siri into
the same search field to answer questions and act in apps, and indexes
shortcuts and actions faster.

Flash does not replace Spotlight; its own file search runs on Spotlight's
index. What it adds is a flashlight for what is open on screen, and hints
for everything a launcher cannot reach. [Raycast](raycast.md),
[Alfred](alfred.md), [LaunchBar](launchbar.md) and [Kando](kando.md) have
pages of their own.

| | Spotlight | Flash |
| --- | --- | --- |
| License, price | Part of macOS | MIT, free |
| Platforms | macOS; actions and the Clipboard view from macOS 26 | macOS 13+ |
| Permissions | None to grant | Accessibility; Automation per browser for tabs and of Notes, and Reminders and Contacts, only for those searches |
| Finds | Apps, files by content and metadata, actions, Shortcuts, clipboard history, iPhone apps through iPhone Mirroring | Apps, windows, browser tabs, tmux windows, the frontmost app's menu items, notes, reminders, contacts, Shortcuts, emoji, snippets; files by name through Spotlight |
| Runs | Hundreds of App Intents actions with typed fields; Quick Keys; Siri requests on macOS 27 | Every Flash command from `:`, `@system` actions, `@menus`, `@shortcuts`, about 14,500 search bangs |
| Clipboard | Command-4: text, links and images, kept 30 minutes to 7 days | `!clip`: up to 10,000 entries, pins, images, file copies, pasted for you |
| Configuration | System Settings › Spotlight | One TOML file, live reload, `flash config check` |
| Maintenance | Ships with macOS; macOS 27 in September 2026 | 1.1.0, October 2026 |

## Where Spotlight is stronger

- **App Intents.** Any app can hand Spotlight actions with typed fields,
  and macOS ranks them by what you do. Flash runs its own commands, its
  plugins' and your Shortcuts, nothing an app declares for Spotlight.
- **Files by content.** Spotlight searches inside documents, mail and
  messages; Flash's `!f` matches file names only, through Spotlight's own
  query.
- **Siri in the search field** on macOS 27, for questions answered on the
  spot. Flash's AI bangs (`!claude`, `!chatgpt`) open a chat with the
  question filled in, in the browser.
- **Already there.** Nothing to install, configure or grant, and it works
  the same on every Mac you sit at.
- **iPhone apps** through iPhone Mirroring, and suggestions learned from
  your routine.

## Where Flash is stronger

- **What is open, not only what is installed.** The flashlight lists
  Safari, Chrome and Firefox tabs, tmux windows, and with `@windows` every
  window of every app, minimized and on other Spaces included, and switches
  to the one you pick ([windows](../windows.md#switch-to-any-window)).
- **A clipboard that pastes.** Apple's guide has you copy an entry back
  with Command-C and paste it yourself; Flash pastes it into the app you
  came from, through that app's own paste command, keeps up to 10,000
  entries with pins that are never trimmed, and pastes plain text with
  `<shift-cr>` ([clipboard](../clipboard.md)).
- **Past the search box.** Hints click anything on screen, NORMAL mode
  drives tabs and windows, and the same keys reach the status bar and
  popups; a launcher stops at opening things.
- **Bangs without a round trip.** Every DuckDuckGo and Kagi bang, about
  14,500, resolves to the site's own search URL on your Mac.
- **Scriptable and in a file.** `flash menu choose` turns any list of lines
  into a picker for your scripts, and every mapping lives in `flash.toml`.

## Flash features you might like

- `@menus` searches and presses the frontmost app's menu items, Spotlight's
  menu-item actions from the keyboard
  ([flashlight](../flashlight.md#narrow-to-a-resource-type)).
- `@shortcuts` lists your Shortcuts and runs the one you pick;
  `shortcuts refresh` rereads them.
- `[flashlight.aliases]` rewrites a short word as you type it, the way a
  Quick Key stands for an action: `"sc" = "@shortcuts"`.
- The `answers` plugin evaluates arithmetic, units, currencies, colours and
  world clocks (`time in tokyo`) as you type; `<cr>` copies the result.
- `@system` lists lock, sleep, restart and the other system actions, and
  asks before the destructive ones.

## Moving from Spotlight

| Spotlight | Flash |
| --- | --- |
| Command-Space | Any chord: `["flash", "mode", "flashlight"]` in `[mode.all.mappings]`; take Command-Space only after freeing it in System Settings › Keyboard › Keyboard Shortcuts › Spotlight |
| Command-1, Applications | The default results, or `@apps` |
| Command-2, Files | `!f <name>` or `@files`, by name only |
| Command-3, Actions | `@system`, `@menus`, `@shortcuts`, and `:` for every Flash command |
| Command-4, Clipboard | `!clip`; `<cr>` pastes, `<alt-cr>` only copies |
| Quick Keys (`ft Ashley`) | `[flashlight.aliases]` for a word in the bar, or a NORMAL sequence such as `"<leader>s"` bound to the command |
| Calculations and conversions | The `answers` plugin |
| Results from Apps | `[flashlight] ignored_apps` and `app_directories` for apps; `@` types for the rest |
| Clipboard history duration | `[clipboard] history_size`, a number of entries |
| Siri requests, App Intents actions | Not available |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+space" = ["flash", "mode", "flashlight", "--restore-mode"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]

[mode.normal.mappings]
"<leader>a" = ["flash", "mode", "flashlight", "--query=@shortcuts"]
"<leader>m" = ["flash", "mode", "flashlight", "--query=@menus"]

[flashlight.aliases]
"sc" = "@shortcuts"
"mn" = "@menus"
```

## Using both

Most people should keep both. Leave Command-Space to Spotlight for files by
content, App Intents actions and Siri, and give Flash a chord of its own for
the flashlight; the two never compete for a key. Flash's `!f` asks
Spotlight's index, so a folder excluded under Search Privacy in Settings ›
Spotlight is hidden from both. If Flash's clipboard history now does the
job, turn off Results from Clipboard in Settings › Spotlight, or keep it to
30 minutes, so your copies are kept in one place.

*Checked 2026-10-23 against Apple's guides on
[actions and Quick Keys](https://support.apple.com/guide/mac-help/take-actions-and-shortcuts-in-spotlight-mchl4953dfeb/mac),
the [Clipboard view](https://support.apple.com/guide/mac-help/search-your-clipboard-history-mchl40d5b86b/mac)
and [Spotlight settings](https://support.apple.com/guide/mac-help/spotlight-settings-on-mac-mchl54d95e8a/mac),
the [macOS 27 release notes](https://support.apple.com/en-us/127257), and
coverage of
[Spotlight in macOS 26](https://9to5mac.com/2025/06/10/macos-26-spotlight-gets-actions-clipboard-manager-custom-shortcuts/),
[its 26.1 clipboard settings](https://www.macrumors.com/2025/11/04/more-spotlight-clipboard-settings-macos-26-1/)
and [macOS 27](https://9to5mac.com/2026/09/14/macos-27-golden-gate-now-available-here-is-everything-new/).*
