# Flash and Leader Key

[Leader Key](https://github.com/mikker/LeaderKey) is "The *faster than your
launcher* launcher": press one shortcut, then a few letters from a tree you
built, and `o` `m` opens Messages. Its README calls it "a riff on Raycast,
@mxstbr's multi-key Karabiner setup, and Vim's `<leader>` key". It is MIT
Swift by Mikkel Malmberg, about 2,300 stars, and 1.17.3 from 23 September 2025
is its latest release. Since March 2026 the README opens with "Leader Key has
been surpassed by Tuna", the author's launcher (free with limits, $49 for Pro,
macOS 15+) with Leader Key built in, and promises that "Leader Key will stay
free and open source" while his focus moves to Tuna.

Flash's NORMAL mode has the same idea at its centre: `<leader>` and a few
plain keys. The difference is where the keys go. Leader Key opens a panel
that takes them; Flash reads them in a mode that stays on across apps, and
lets the same letters do far more than launch.

| | Leader Key | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS; the README states no minimum | macOS 13+ |
| Permissions | None stated in its README | Accessibility |
| Model | A global shortcut opens a panel; nested groups of single keys; a cheatsheet always, after a delay you set, or on `?` | `<leader>` sequences in NORMAL with a which-key palette after a pause; from any mode, a chord into a layer of keys |
| Actions | Open an app, a URL or a folder, run a command; a held modifier runs a whole group, or keeps the panel open | Any Flash command or argv: apps, URLs, folders, windows, tabs, hints, the flashlight |
| Configuration | A settings editor, `config.json` in a folder you choose; a `leaderkey://` URL scheme on its main branch, newer than the last release | One TOML file, live reload, `flash config check` |
| Maintenance | 1.17.3, September 2025; focus on Tuna since March 2026 | 1.1.0, October 2026 |

## Where Leader Key is stronger

- **You see where you are.** The panel appears the moment you press the
  shortcut and shows the group you are in, and the cheatsheet lists each key
  with its label and app icon or favicon, at once if you like. Flash's
  which-key palette appears only after a pause on a NORMAL prefix (500 ms by
  default), lists the command each key runs rather than a label, and never
  shows icons.
- **Labels.** Every action and group carries a name you chose. A Flash
  mapping is a key and its argv, nothing more.
- **Group actions and sticky mode.** Hold a modifier on a group key and every
  action in it runs; hold another while choosing an action and the panel
  stays open for the next one. A Flash mapping runs one command, and a layer
  is sticky or one-shot as a whole.
- **Edited in a window**, with the tree laid out and apps picked from a list,
  while `config.json` still lives in your dotfiles.
- **No mode model.** One shortcut, from anywhere, and the keyboard is
  untouched otherwise. Flash's NORMAL and layers need its modes turned on,
  which changes how every key behaves until you enter INSERT.

## Where Flash is stronger

- **The leader is a plain key.** In NORMAL `<leader>` is one key (`\`, or
  Space), so `<space>om` is three keystrokes with no chord. From INSERT, a
  chord into a one-shot layer does what Leader Key's shortcut did.
- **More than launching.** The same letters can place windows, switch
  tabs, click labelled hints, open the flashlight or run plugin commands, and
  commands such as `tab next` resolve in whatever app is in front.
- **Per-app sequences.** `[mode.apps."<bundle id>".normal.mappings]` gives
  `<leader>r` a different meaning in one app. Leader Key has one tree for
  every app.
- **Counts and repeat.** `3]t`, `.` to run the last command again, `q`/`@`
  macros of commands ([repeat and macros](../normal-mode.md#repeat-and-macros)).

## Flash features you might like

- `[mode.normal] leader = "<space>"` and `[mode] which_key_ms` for the
  palette's delay; `0` hides it for good ([NORMAL](../normal-mode.md)).
- Marks: `ma` saves the app you are in under `a`, `'a` brings it back, with
  no config edit ([marks](../marks.md)).
- `mode flashlight` for the times typing a name beats remembering a letter.
- `app open --name=…` focuses the app if it is already running, so one
  binding both launches and switches.

## Moving from Leader Key

| Leader Key | Flash |
| --- | --- |
| The activation shortcut (⌘⌥Space, a Hyper chord) | `<leader>` in NORMAL; from INSERT, a chord in `[mode.all.mappings]` entering a one-shot layer |
| Group `o`, action `m`, type `application` | `"<leader>om" = ["flash", "app", "open", "--name=Messages"]` |
| A `url` action | `["open", "https://…"]` |
| A `folder` action | `["open", "~/Downloads"]` |
| A `command` action | Its argv, or `["/bin/sh", "-c", "…"]` for shell syntax |
| `media mute`, `window maximize` from the README's examples | `["flash", "volume", "mute"]`, `["flash", "window", "move", "--position=maximized"]` |
| Group actions | A script on one key |
| Sticky mode | A layer with `sticky = true`, the default |
| Cheatsheet | The which-key palette after `which_key_ms`; `?` for the whole key mappings page |
| `leaderkey://navigate?keys=o,m` | `flash app open --name=Messages` from a script; Flash has no URL scheme |
| `leaderkey://config-reload` | Saving the file |
| Themes, labels, icons | Not available |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]                       # turns the modes on
"cmd+alt+<space>" = ["flash", "mode", "layer", "--name=leader"]  # Leader Key's shortcut, from INSERT too

[mode.normal]
leader = "<space>"

# In NORMAL: Space, then the letters
[mode.normal.mappings]
"<leader>om" = ["flash", "app", "open", "--name=Messages"]
"<leader>os" = ["flash", "app", "open", "--name=Safari"]
"<leader>mm" = ["flash", "volume", "mute"]
"<leader>wm" = ["flash", "window", "move", "--position=maximized"]
"<leader>fd" = ["open", "~/Downloads"]
"<leader>ug" = ["open", "https://github.com"]

# From any mode: the chord, then the same letters, then back where you were
[mode.layers.leader]
label = "LEADER"
sticky = false

[mode.layers.leader.mappings]
"om" = ["flash", "app", "open", "--name=Messages"]
"os" = ["flash", "app", "open", "--name=Safari"]
"mm" = ["flash", "volume", "mute"]
"wm" = ["flash", "window", "move", "--position=maximized"]
"fd" = ["open", "~/Downloads"]
"ug" = ["open", "https://github.com"]
```

With the leader on Space, holding Space in NORMAL is also
[HYPER](../hyper-mode.md), and a tap still starts the sequence.

## Using both

Leader Key can keep its shortcut while you move groups over one at a time.

- Give it a chord Flash does not bind. If you bind the same chord in both,
  `flash resident doctor` reports it as taken by another app.
- Open Leader Key from INSERT. In NORMAL Flash takes plain keys before the
  app in front sees them, and Leader Key's panel is such an app, so its
  letters would be swallowed.
- A `command` action can call Flash: `flash window move --position=lefthalf`
  works from Leader Key as from a shell, once `PATH` reaches `flash` (its
  README explains the non-interactive shell's `PATH`).

*Checked 2026-10-23 against the Leader Key
[README](https://github.com/mikker/LeaderKey),
[releases](https://github.com/mikker/LeaderKey/releases) and settings source,
and the [Tuna](https://tunaformac.com) site.*
