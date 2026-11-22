# README media

The README embeds the files below, inside HTML comments until they exist:
remove the comment around each one as it is recorded. None of them is
recorded yet (the README opens with `hints-calculator.gif`, described
below); each entry says what to show so the set reads as one story. Record
on a clean desktop with a neutral wallpaper, light appearance, one 16:10
display at 1920×1200 (or scale to 1600 px wide), with
[KeyCastr](https://github.com/keycastr/keycastr) in the bottom-left so every
keystroke is visible. GIFs: 10–15 s, 20 fps, under 5 MB (`screencapture -v`,
trim with ffmpeg, encode with gifski). PNGs: 2x, under 500 KB.

| File | What to record |
| --- | --- |
| `hero.gif` | The one that sells it. Safari on a busy page: press the hotkey, labels appear on every link and button, type two letters, the link opens. Cut to Finder or System Settings: same hotkey, type a label, a checkbox toggles. End on the Dock: hotkey, label, an app launches. |
| `normal-mode.gif` | Firefox, NORMAL already on (mode pill visible). `f` then a label clicks a link, `]t` switches tab, `ctrl+d` scrolls, `/` opens Find, ⌘⌃I turns the pill INSERT as you type, ⌘⌃[ back to NORMAL. |
| `grid.gif` | A canvas app with no Accessibility tree (Figma, a game, a remote desktop). `mouse grid`: the keyboard-shaped grid appears, press a key, it zooms, press again, the last press clicks. Then `--bisect` halving twice. |
| `tmux-hints.png` | A terminal with four tmux panes, one holding a `git log` with a URL and a file path. Hints visible on every pane, the URL, the path and the status-bar window tabs. |
| `flashlight.png` | The command bar open with `tab ` typed: browser tabs and tmux windows ranked, and below it a second shot or a split with `1234 eur in usd` showing the inline answer. |
| `statusbar-widgets.png` | Full desktop, no windows: the bar on top with `docs/examples/statusbar/flash.toml` (feed, quotas, CPU/MEM/DSK/NET/BAT, clock), the system panel widget from `docs/examples/widgets/system-panel.toml` in the top-right, the clock and agenda widget bottom-left. |
| `popup-btop.png` | Same desktop, the pointer hovering the CPU segment of the bar, the terminal popup below it running btop. |

## Recorded so far

`hints-calculator.gif` opens the README: Calculator over a plain backdrop,
`mouse target`, then the labels of 7, ×, 6 and = typed one activation at a
time. It is nine stills (`screencapture -x -R<x,y,w,h>`) joined with ffmpeg,
not a video: under `screencapture -v` with a region Flash found every
target occluded and showed no hints, so check a short take before recording
a long one with any tool that draws over the screen. A region capture also
keeps everything else on the desktop out of the frame.

## The link card

`social-card.jpg` (1280×640) is the image a shared link shows: the published
site names it as every page's preview image, and it is the file to upload
as the repository's social preview (Settings › General › Social preview; GitHub has no API for
it). It is drawn, not recorded: `Scripts/social-card.html`, rendered by
`mise run build:social-card`.
