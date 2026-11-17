# Flash and skhd

[skhd](https://github.com/asmvik/skhd) is a "simple hotkey daemon for macOS
that focuses on responsiveness and performance": a text file of
`modifier - key : command` lines, with modes, per-app bindings, passthrough
and synthesized keys, reloaded while it runs. It comes from yabai's author,
and many yabai setups drive it from skhd. It is MIT C with about 8,100 stars,
and its README says it "is in maintenance mode; only critical issues that
affect the core functionality" are handled: v0.3.9 from May 2023 is the last
tag.

The same README points to [skhd.zig](https://github.com/jackielii/skhd.zig),
Jackie Li's "backwards compatible skhd-port" in Zig (MIT, about 670 stars,
0.2.0 on 2026-07-20). It reads an existing `skhdrc` unchanged and adds
process groups, `.define` commands, key forwarding, chord sequences and, in
0.1.0, tap-hold remapping through a root grabber daemon and Karabiner's
driver extension. This page covers both.

| | skhd, skhd.zig | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS, no minimum stated; skhd.zig ships Apple silicon and Intel builds | macOS 13+ |
| Permissions | Accessibility; skhd.zig's remapping adds Input Monitoring, a root LaunchDaemon and Karabiner's driver extension | Accessibility |
| Bindings | Chords to shell commands; modes, with `@` to capture unbound keys; per-app lists, `~` to leave an app alone, `->` passthrough, `.blacklist`; media keys; skhd.zig adds chord sequences, process groups and layers held on a key | Chords, plain keys and sequences per mode and per app; layers; counts, `.` repeat, macros and a which-key palette in NORMAL |
| Actions | Any shell command through `$SHELL -c`; `skhd -k` and `skhd -t` synthesize a key or a line of text | Flash commands in process (windows, hints, tabs, apps, the flashlight, the bar), or any argv |
| Configuration | `~/.config/skhd/skhdrc`, hotloaded; `skhd --reload` | One TOML file, live reload, `flash config check` |
| Runs as | A launchd agent (`skhd --start-service`) | The Flash app, a login item while `[app] autostart` is on |
| Maintenance | skhd: maintenance mode, v0.3.9, May 2023; skhd.zig: 0.2.0, July 2026, active | 1.1.0, October 2026 |

## Where skhd is stronger

- **Any shell line is a hotkey.** Every binding runs through your shell, so
  pipes, `;` chains and environment variables just work. Flash runs an argv
  without a shell; pipes need an explicit `["/bin/sh", "-c", "…"]`.
- **Small and single-purpose.** One daemon, one text file, no UI. If
  hotkeys are all you want, skhd is less to install and less to learn than
  a whole keyboard layer with a bar and plugins.
- **Passthrough.** `->` runs a command and still lets the app see the key.
  Flash takes a chord it binds; the app never gets it.
- **Ignore an app wholesale.** `.blacklist` stops skhd in listed apps. Flash
  removes bindings one at a time with `false` in that app's table.
- **Typing.** `skhd -t` types a line of text. Flash's `key send` and
  `key sequence` send chords, and Flash expands no text.
- **skhd.zig remaps keys.** Caps Lock as Escape on a tap and Control on a
  hold, per device, in the same file; Flash never changes what a key sends.

## Where Flash is stronger

- **Modes you can see.** An skhd mode lasts until a binding switches back,
  and nothing shows it unless the mode's command tells your bar. Flash's
  [layers](../layers.md) put their `label` in the pill and turn the window
  border orange, Escape leaves, and `sticky = false` returns after one key
  without writing `; default` on every line.
- **Plain keys everywhere.** NORMAL holds the keyboard until you enter
  INSERT, so `h` or `<leader>w` is a binding across every app, not only
  inside a capture mode.
- **The actions come with it.** `window focus --direction=left`, `tab next`
  that resolves in each app, labelled hints, the mouse grid, the flashlight:
  with skhd each is a command you supply, from yabai, a script or
  `osascript`.
- **Checked before it loads.** `flash config check` validates every key and
  command offline, with line and column, so a typo fails in your editor or
  CI rather than in the daemon's log.
- **Sequences, counts and repeat** in NORMAL: `3]t`, `gg`, `.`, and a palette
  of what can follow a prefix after a pause.

## Flash features you might like

- A [layer](../layers.md) is an skhd mode with `@`: only its keys act, the
  rest are swallowed, and `[mode.all.mappings]` chords still work inside.
- `[mode.apps."<bundle id>".all.mappings]` is skhd's per-app list, keyed by
  bundle ID rather than process name ([app-specific mappings](../configuration.md#app-specific-mappings)).
- If skhd drove yabai, `window focus --direction=` and Flash's opt-in
  [tiling](../tiling.md) cover the common moves, or keep yabai and call it
  from a layer ([yabai](yabai.md)).
- `?` in NORMAL draws your keyboard with every binding of the mode you pick,
  layers included.

## Moving from skhd

| skhd | Flash |
| --- | --- |
| `alt - h : yabai -m window --focus west` | `"alt+h" = ["yabai", "-m", "window", "--focus", "west"]` in `[mode.all.mappings]`, or `["flash", "window", "focus", "--direction=left"]` |
| `alt - return : open -na Ghostty` | `"alt+<return>" = ["open", "-na", "Ghostty"]` |
| `:: resize @` and `ctrl + alt - r ; resize` | `[mode.layers.resize]` and `"ctrl+alt+r" = ["flash", "mode", "layer", "--name=resize"]` |
| `resize < h : …` | `"h" = …` under `[mode.layers.resize.mappings]` |
| `resize < escape ; default` | Escape, built in; `mode leave` on any other key |
| `:: resize : sketchybar --trigger …` (a command on entering) | The layer's `label` in Flash's pill and in `#{flash.mode}`; a script reads `mode` from `flash resident status --json` |
| `cmd - n [ "Safari" : … ]` | `[mode.apps."com.apple.Safari".all.mappings]` |
| `[ "kitty" ~ ]` | `"<chord>" = false` in that app's table |
| `.blacklist [ … ]` | No whole-app switch; `false` per binding |
| `->` passthrough | Not available |
| `skhd -k "cmd - c"` | `flash key send --keys=cmd+c` |
| `skhd -t "text"` | Not available |
| `skhd --reload` | Saving the file; `flash config reload` |
| skhd.zig `.remap caps_lock { tap: escape, hold: lctrl }` | Keep skhd.zig or [Karabiner-Elements](karabiner-elements.md) for it |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]                  # turns the modes on
"alt+h" = ["flash", "window", "focus", "--direction=left"]  # alt - h : yabai -m window --focus west
"alt+l" = ["flash", "window", "focus", "--direction=right"]
"alt+<return>" = ["open", "-na", "Ghostty"]                 # alt - return : open -na Ghostty
"ctrl+alt+r" = ["flash", "mode", "layer", "--name=resize"]  # ctrl + alt - r ; resize

[mode.layers.resize]                                        # :: resize @
label = "RESIZE"

[mode.layers.resize.mappings]                               # resize < h : …
"h" = ["yabai", "-m", "window", "--resize", "left:-20:0"]
"l" = ["yabai", "-m", "window", "--resize", "right:20:0"]
"<return>" = ["flash", "mode", "leave"]                     # resize < return ; default

[mode.apps."net.kovidgoyal.kitty".all.mappings]             # alt - h [ "kitty" ~ ]
"alt+h" = false
```

## Using both

skhd can call Flash from any line, so a move can go one binding at a time:

```text
ctrl + alt - f : flash mouse target
```

- Give each chord one owner. Two tools listening for the same chord race
  for it; move a binding to `flash.toml` and delete it from `skhdrc` in the
  same edit.
- Do not leave an skhd capture mode (`@`) and Flash's NORMAL reading plain
  keys at the same time. Enter one or the other, or move the mode into a
  Flash layer.
- Both lose keys while a password field holds secure input; skhd's README
  asks for Secure Keyboard Entry to be off, and `flash resident doctor`
  names the app holding it.
- With skhd.zig remapping Caps Lock, bind in Flash the key it produces, as
  with any remapper.

*Checked 2026-10-23 against the skhd
[README](https://github.com/asmvik/skhd) and
[tags](https://github.com/asmvik/skhd/tags), and the skhd.zig
[README](https://github.com/jackielii/skhd.zig) and
[changelog](https://github.com/jackielii/skhd.zig/blob/main/CHANGELOG.md).*
