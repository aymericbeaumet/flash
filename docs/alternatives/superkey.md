# Flash and Superkey

[Superkey](https://superkey.app), by the author of Rectangle, is "Simple
and powerful keyboard enhancement on macOS": a hyper key, remap presets,
and Seek, which finds text anywhere on the screen by OCR and clicks it. It
is closed source for macOS 12+, free for 20 days, then a one-time licence
for three devices (the price loads from the checkout; third-party listings
say about $16). Version 1.66 shipped in June 2026; releases come every one
to three months.

| | Superkey | Flash |
| --- | --- | --- |
| License, price | Closed; one-time licence, 20-day trial | MIT, free |
| Platforms | macOS 12+ | macOS 14+ |
| Permissions | Screen Recording for Seek (it takes a screenshot), Accessibility for keystrokes and clicks | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Targets | OCR of the whole screen, plus optional Accessibility parsing | Accessibility tree only |
| Actions | Seek and click, cycle matches with `;` | Labels, search, grid, bisect, drag, select, words, path, sticky, multi |
| Beyond pointing | Hyper key, trackpad gesture for hyper, remap presets | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Preferences window | One TOML file, live reload, CLI |
| Maintenance | 1.66, June 2026 | 1.0.0, October 2026 |

## Where Superkey is stronger

- **Seek finds text that no Accessibility tree exposes**: a canvas, a
  screenshot, a video frame, a remote desktop.
- **Hyper key and remaps** are built in. Flash does not remap hardware keys.
- **Lower macOS floor** and a tiny footprint.

## Where Flash is stronger

- **No Screen Recording.** Seek screenshots the screen to run OCR; Flash
  reads nothing. Superkey's own FAQ notes that small text and text near
  lines are hard to pick up; Accessibility labels do not depend on fonts.
- **Labels, grid and modes**, not only text seek.
- **Open source, free, file-configured**, with per-app tables.
- **Everything after the click.**

## Flash features you might like

- `mouse_target --search` is Seek over Accessibility text: type visible
  text, matches cycle, Return clicks.
- `mouse_bigram` types one visible character (`v`/`V` and `3`/`#` match),
  then a short label, for terminals and status bars.
- `--words` puts a label on every visible word.

## Moving from Superkey

| Superkey | Flash |
| --- | --- |
| Seek | `["flash", "mouse_target", "--search"]`; `--scope=screen` for every app |
| Seek on screen text without Accessibility | Not available; use `mouse_grid` |
| Hyper key | Keep Superkey or Karabiner-Elements for it; Flash mappings accept hyper chords |
| Remap presets | Keep Superkey or Karabiner-Elements |

Superkey's hyper key and Flash coexist: Flash sees the hyper chord like any
other modifier combination.

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target", "--search"]
```

*Checked 2026-10-14 against
[superkey.app](https://superkey.app) and its update feed.*
