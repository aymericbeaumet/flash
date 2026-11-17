# Flash and CopyQ

[CopyQ](https://github.com/hluk/CopyQ) is a "Clipboard manager with advanced
features": a history you can sort into tabs, edit, tag and annotate, with
commands that run on every new copy, a scripting API and a command line that
can do everything the window does. It is GPL-3.0 C++ and Qt by Lukas
Holecek, about 12,500 stars, and runs on Linux, Windows and macOS (13 or
later, per its installation guide). 17.0.0 shipped in October 2026 and moved
its macOS data to `~/Library/Application Support`, a one-way migration.

CopyQ is a programmable clipboard; Flash's [clipboard history](../clipboard.md)
is not. If you use CopyQ for its scripts and tabs, keep it. If you mostly
open it to find and paste something you copied, Flash may be enough, and the
two can share the work.

| | CopyQ | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Linux, Windows, macOS 13+ | macOS 13+ only |
| Permissions | Accessibility, to paste | Accessibility |
| Keeps | Text, HTML, images, custom formats, in tabs; notes and tags | Text, formatted text, images, file copies; pins; named registers |
| Editing | An item editor with Vim keys | None |
| Automation | Commands on copy, on a shortcut or from the menu; a scripting API; a full CLI | `flash clipboard show`, `restore`, `pin`, `delete` from any shell |
| Protection | Concealed copies ignored by default; encrypted tabs (since 14.0.0); ignore copies from chosen windows or containing chosen text | Concealed, transient and auto-generated items never recorded |
| Configuration | Preferences, commands dialog, scripts | One TOML file, live reload, `flash config check` |
| Maintenance | 17.0.0, October 2026; active | 1.1.0, October 2026 |

## Where CopyQ is stronger

- **It is programmable.** An automatic command can rewrite, route or drop a
  copy as it arrives; a global shortcut can run a script over the selected
  items; `copyq eval` runs the same scripts from a shell. Flash runs nothing
  when you copy and has no clipboard scripting.
- **Tabs, notes and tags.** Sort copies into tabs by hand or by command,
  write a note on an item, tag it. Flash has one history and a list of pins.
- **Editing.** Change an item in place, with Vim keys if you like. Flash
  stores what was copied, unchanged.
- **Encrypted storage.** Encrypt Tabs protects the stored history with a
  password, optionally kept in the Keychain. Flash's history is readable
  only by your account but not encrypted by Flash.
- **Finer filters.** Ignore copies made in windows whose title you name, or
  containing text you name.
- **Every platform you use.** The same tabs and scripts on Linux and
  Windows, and the Synchronize plugin mirrors a tab to a folder of files you
  can sync yourself. Flash is macOS only.

## Where Flash is stronger

- **One search box.** `!clip` sits in the flashlight with apps, tabs,
  windows and tmux windows; `@clipboard` adds the named registers.
- **Pasting into a terminal just works.** The entry goes back through the
  focused app's own paste command, so a terminal gets the paste shortcut it
  binds, never keystrokes typed into the shell.
- **The keyboard layer around it.** Hints, NORMAL's `"ay` / `"ap`
  registers, and `--restore-mode` back to INSERT after a paste, in the same
  file as the rest of your keys.

## Flash features you might like

- `flash clipboard show --offset=0` prints a page of entries with their ids
  as JSON, pinned entries first, for `jq` and scripts.
- `flash clipboard restore --id=<id> --paste --plain` pastes one entry's
  plain text from a script.
- `flash menu choose` is a dmenu-style picker: pipe any lines to it and it
  prints the one you pick ([flashlight](../flashlight.md#pick-from-a-list)).
- The Clipboard page of the browser help (`flash clipboard show`) lists
  every entry, with images and file copies.

## Moving from CopyQ

| CopyQ | Flash |
| --- | --- |
| The global shortcut that shows the window | A mapping to `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| Type to filter | The same |
| Pin items | `<cmd-p>`, or `flash clipboard pin --id=<id>` |
| `copyq read 0` | `flash clipboard show --offset=0`, JSON |
| `copyq add`, `copyq copy` | `pbcopy`; Flash records it like any copy |
| Tabs | Pins, and named registers in NORMAL; no tabs |
| Edit an item, notes, tags | Not available |
| Automatic commands on new copies | Not available |
| Ignore by window title or text | Not available |
| Encrypt Tabs | Not available |
| Synchronize with documents | Not available |

```toml
[clipboard]
history_size = 5000

[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
# Keep CopyQ's window one chord away while you move over
"cmd+ctrl+shift+v" = ["/Applications/CopyQ.app/Contents/MacOS/CopyQ", "toggle"]
```

`toggle` is CopyQ's own command-line call for showing or hiding its window;
the app must be running for its command line to answer.

## Using both

Keeping CopyQ works well: let CopyQ own the tabs, the scripts and the
commands on copy, and let Flash be the quick search and the
terminal-safe paste. Both then record each copy. Give them separate chords,
as above, so neither takes the other's.

Flash's picker can also read CopyQ's tabs. With the `copyq` command linked
as CopyQ's installation guide shows
(`/Applications/CopyQ.app/Contents/MacOS/CopyQ` to `/usr/local/bin/copyq`),
this script lists a tab named `notes` in the flashlight, one line per line
of each item, and puts your pick back on the clipboard:

```sh
pick=$(copyq eval -- "tab('notes'); for(i=size(); i>0; --i) print(str(read(i-1)) + '\n');" \
  | flash menu choose) && copyq copy "$pick"
```

*Checked 2026-10-23 against the CopyQ [README](https://github.com/hluk/CopyQ),
[17.0.0 release](https://github.com/hluk/CopyQ/releases/tag/v17.0.0), and its
documentation on [installation](https://copyq.readthedocs.io/en/latest/installation.html),
the [command line](https://copyq.readthedocs.io/en/latest/command-line.html),
the [scripting API](https://copyq.readthedocs.io/en/latest/scripting-api.html),
[password protection](https://copyq.readthedocs.io/en/latest/password-protection.html)
and [security](https://copyq.readthedocs.io/en/latest/security.html).*
