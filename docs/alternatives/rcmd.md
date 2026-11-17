# Flash and rcmd

[rcmd](https://lowtechguys.com/rcmd/) is "Reimagined Command-Tab": hold the
Right Command key and press an app's first letter to focus it, or launch it
if it is not running, while Left Command keeps every macOS shortcut. Letters
are assigned automatically, Tab cycles the apps that share one, and you can
pin your own. Version 3 grew around that idea: double-tap and hold Right
Command to fuzzy-search windows, tabs and Stages (saved sets of windows),
jump between Spaces by number, and drive it all from an `rcmd` command line.
It is made by The Low-Tech Guys (Alin Panaitiu), closed source, free with a
Pro tier at €15 for a lifetime licence and a 14-day trial. Version 3.6.4 is
current in October 2026; it needs macOS 13 or later.

Flash reaches apps by keys you choose rather than letters it picks, and adds
marks, a labelled window list and the flashlight around them.

| | rcmd | Flash |
| --- | --- | --- |
| License, price | Closed; free, Pro €15 once | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility, Automation, Screen Recording to read window titles | Accessibility |
| Reaching an app | Hold Right Command, press its letter: focus or launch; Tab for the next app on that letter; letters assigned for you | A key per app you map to `app open --name=`, or a mark set with `m{x}` |
| Windows | Command-Tab by window, Command-Backtick for the app's; fuzzy search and Exposé in Pro | `window switch` with a hint label per row; `@windows` search; `]w` / `[w` |
| Spaces and sets | Right Command plus 1–9 jumps to a Space; Pro sends windows to a Space and saves Stages | No Space control; opt-in [tiling](../tiling.md) workspaces of Flash's own |
| Scripting | `rcmd` CLI with `--json` over a local connection; an MCP setting for AI agents | `flash <topic> <action>` CLI; `flash resident status --json` |
| Configuration | Settings window; `rcmd config` | One TOML file, live reload, `flash config check` |
| Maintenance | 3.6.4, current in October 2026 | 1.1.0, October 2026 |

## Where rcmd is stronger

- **Nothing to set up.** Every app has a letter the moment rcmd runs. Flash
  needs one mapping per app you want on a key, and assigns no letters itself.
- **A modifier of its own.** rcmd uses Right Command alone and leaves Left
  Command to the system. Flash cannot tell the two Command keys apart, so it
  has no equivalent layer; its closest are HYPER (a held key in NORMAL) and
  multi-modifier chords.
- **Launch, cycle, hide on one key.** The same letter launches the app,
  focuses it, and with Tab steps to the next app that starts with it.
- **Spaces.** Jumping to Space 3 or sending a window there is a keystroke.
  Flash does not switch or assign Spaces.
- **Stages** save a set of windows on a key and bring them back, and since
  3.6.4 can run a script or open a file or URL. Flash has no saved window
  sets.
- **Hold, type, release** fuzzy search, Exposé and recently closed windows
  in Pro.

## Where Flash is stronger

- **No Screen Recording.** rcmd needs it because macOS hides other apps'
  window titles from apps without it; Flash reads titles through
  Accessibility and needs no grant beyond it.
- **Free and open source**, with nothing held back for a paid tier.
- **One key per window, not only per app.** `window switch` puts a hint
  label on every window of every app, minimized and hidden ones included,
  and those on other Spaces once Flash has seen them.
- **After the switch, the keyboard carries on**: hints on every control,
  NORMAL's tab and scroll keys, the flashlight and the bar.

## Flash features you might like

- [Marks](../marks.md) are rcmd's custom letters, set by a keystroke: `m{x}`
  in NORMAL saves the app you are in as mark `x`, and `'{x}` brings it back
  from anywhere. Marks survive the app quitting and Flash restarting, and a
  jump launches the app if it is gone.
- [HYPER](../hyper-mode.md): hold the leader (`\` by default) in NORMAL and
  press a letter mapped in `[mode.hyper.mappings]`. It is the closest
  feel to holding Right Command; the defaults use the digits and `e` `s` `d`
  `f`, so pick other letters or override those.
- `app previous` (`[a`) bounces back to the app you came from, and
  `movement back` retraces a chain of jumps.

## Moving from rcmd

| rcmd | Flash |
| --- | --- |
| Right Command + letter | A `[mode.hyper.mappings]` letter (hold `\` in NORMAL), or a chord in `[mode.all.mappings]` for every mode |
| Automatic letters | Not available: one mapping per app |
| Custom letter (Right Command + Right Option + letter) | `m{x}` then `'{x}`, or `mark set --letter=x` and `mark jump --letter=x` |
| Launch an app that is not running | `app open --name=<app>` launches or focuses it |
| Tab through apps on the same letter | Not available: give each its own key |
| Command-Tab by window | `window switch` on a chord of your own; Command-Tab stays macOS's |
| Command-Backtick | `window next` / `window previous` (`]w` / `[w`) |
| Double-tap and hold, type a window's name | `mode flashlight --query=@windows` |
| Right Command + 1–9 to a Space | Not available; with `[tiling] enabled = true`, `workspace switch --name=<n>` for Flash's workspaces |
| Stages | Not available |
| `rcmd app focus safari` | `flash app open --name=Safari` |
| `rcmd window place left-half` | `flash window move --position=lefthalf` |

```toml
# Hold \ (the leader) in NORMAL, then press the letter.
[mode.hyper.mappings]
"b" = ["flash", "app", "open", "--name=Brave Browser"]
"m" = ["flash", "app", "open", "--name=Messages"]
"n" = ["flash", "app", "open", "--name=Notes"]
"t" = ["flash", "app", "open", "--name=Ghostty"]

# The same apps from every mode, INSERT included.
[mode.all.mappings]
"cmd+ctrl+alt+b" = ["flash", "app", "open", "--name=Brave Browser"]
"cmd+ctrl+alt+m" = ["flash", "app", "open", "--name=Messages"]
"cmd+ctrl+alt+w" = ["flash", "mode", "flashlight", "--query=@windows", "--restore-mode"]
```

## Using both

rcmd's letters and Flash's NORMAL keys sit on different keys, so the two
can share a Mac: keep rcmd for automatic letters, Spaces and Stages, and use
Flash for the labelled window list, marks and everything after the switch.
Two rules keep them apart. Do not map plain `cmd+<letter>` chords in Flash:
it cannot tell Right Command from Left, so such a chord would answer rcmd's
key too. And NORMAL swallows every chord it has not mapped
([what NORMAL swallows](../normal-mode.md#what-normal-swallows)); if a
Right Command letter does nothing while Flash is in NORMAL, use it from
INSERT or map that app in Flash as well.

*Checked 2026-10-23 against [rcmd's page](https://lowtechguys.com/rcmd/),
its [changelog](https://files.lowtechguys.com/rcmd/changelog.html) and its
[Homebrew cask](https://formulae.brew.sh/cask/rcmd).*
