# Flash and Contexts

[Contexts](https://contexts.co) is a "Radically simpler & faster window
switcher for Mac" by Usman Khalid. Its heart is search: press Control-Space,
type a few letters of an app or a window title, and the window comes
forward. Around that sit a window-level Command-Tab, Fast Search (hold Fn,
type, release), and a Sidebar that lists every window grouped by Space.
Contexts is closed source, $9.99 for a licence with a free trial. The current
version, 3.9.0 from August 2022, added native Apple silicon support; its page
lists macOS Ventura, Sonoma and Sequoia (13 to 15), and nothing has shipped
since.

Flash covers the same two gestures, typing to find a window and a list to
pick from, with the flashlight's `@windows` search and the
[window switcher](../windows.md#switch-to-any-window).

| | Contexts | Flash |
| --- | --- | --- |
| License, price | Closed; $9.99, free trial | MIT, free |
| Platforms | macOS 13 to 15, per its page | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Search | Control-Space, then type; non-consecutive letters, acronyms first, remembers your picks | `@windows` in the flashlight: title and app name, word starts in any order, typo-tolerant, ranked with your past opens |
| Lists | Command-Tab by window, Command-Backquote for the front app, a Sidebar grouped by Space, filters by Space | `window switch` (`:ls`): every window, most recently used first, one hint label each |
| Without a list | Fast Search: hold Fn, type, release | `window last`, `window next`, marks, hints, `window focus --direction` |
| Configuration | A preferences window, several switchers with their own shortcuts | One TOML file, live reload, `flash config check` |
| Maintenance | 3.9.0, August 2022; none since | 1.1.0, October 2026 |

## Where Contexts is stronger

- **Fast Search.** Hold Fn, type `s`, let go, and Safari's window is in
  front: no panel to dismiss, no Return. Flash has no Fn modifier, and its
  searches open the flashlight and wait for Return.
- **The Sidebar** keeps every window on screen all the time, grouped by
  Space, with a swipe to tuck it away. Flash has no persistent window list.
- **It can be Command-Tab.** Contexts can take over Command-Tab and list
  windows rather than apps. Flash leaves Command-Tab to macOS.
- **Filters by Space** and several switchers with their own shortcuts and
  sort orders. Flash's list has one order and no filters.
- **Actions from the switcher**: Command-W closes, Command-Q quits, and
  others minimize and hide the selected window without switching to it.
- **A trackpad gesture**: two fingers down from the top edge opens the list.

## Where Flash is stronger

- **Maintained, and on current macOS.** Contexts has not shipped since
  2022 and its page stops at Sequoia; Flash 1.1.0 shipped in October 2026.
- **One keystroke per window in the list.** Every row of `window switch`
  carries a hint label, so the list doubles as a jump table when you already
  know which window you want.
- **Search reaches past windows.** The same flashlight finds running and
  installed apps, browser tabs, tmux windows, clipboard entries and system
  actions, so one key and a word replace several switchers.
- **Free and open source.**

## Flash features you might like

- `window last` (`ctrl+w p`) flips to the previous window with no list at
  all, the habit Contexts' Command-Tab builds.
- `window next` and `window previous` (`]w`, `[w`) cycle the front app's
  windows, Contexts' Command-Backquote.
- `mode flashlight --query=@windows <words>` pre-fills a search, so a key can
  open the flashlight already narrowed to one app's windows.
- Hints label every control in the window you land on, so the keyboard
  carries on after the switch ([hints](../hints.md)).

## Moving from Contexts

| Contexts | Flash |
| --- | --- |
| Control-Space, type, Return | `mode flashlight --query=@windows`, type, Return |
| Fast Search (Fn-`s` for Safari) | A NORMAL sequence that pre-fills the search, as below; there is no Fn modifier |
| Command-Tab by window | `window switch` on a chord of your own; Command-Tab stays macOS's |
| Command-Backquote | `window next` (`]w`), `window previous` (`[w`) |
| Remembered search shortcuts | Frecency: rows you open often and lately rank higher |
| Command-W, Command-Q in the switcher | Switch, then `window close` or `app quit` |
| Minimize, hide in the switcher | Switch, then `window minimize`; hiding an app is not a Flash command |
| Sidebar, filter by Space, trackpad gesture | Not available |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"ctrl+<space>" = ["flash", "mode", "flashlight", "--query=@windows", "--restore-mode"]
"cmd+ctrl+<tab>" = ["flash", "window", "switch"]

[mode.normal.mappings]
"<leader>s" = ["flash", "mode", "flashlight", "--query=@windows safari"]
"<leader>t" = ["flash", "mode", "flashlight", "--query=@windows terminal"]
```

Control-Space is also macOS's default shortcut for the previous input
source; if you use several keyboard layouts, pick another chord.

## Using both

Contexts can keep running while it still launches on your macOS: Flash maps
none of Control-Space, Command-Tab or Fn by default, and Contexts' Sidebar
and Fast Search have no Flash counterpart. Give each its own chords; if you
move the search to Flash, release Control-Space in Contexts' preferences
first: two apps cannot hold one hotkey, and `flash resident doctor` lists
the ones macOS refused Flash.

*Checked 2026-10-23 against [contexts.co](https://contexts.co), its
[release history](https://contexts.co/history) and its
[Homebrew cask](https://formulae.brew.sh/cask/contexts).*
