# Alternatives

One page per tool Flash is compared with, each in the same shape: what the
tool is, a side-by-side table, where it is stronger than Flash, where Flash
is stronger, the Flash features a user of that tool tends to like, and how
to move a setup over. The pages try to be fair: several of these tools do
things Flash does not and never will, and some of them run fine next to it.

Facts were checked on 2026-10-14 against each project's own README, site,
changelog or GitHub data. Versions and prices move; the source links on each
page are the place to re-check.

## Hint and pointer tools

| | Open source | Hints from | Also | Page |
| --- | --- | --- | --- | --- |
| Neru | MIT | Accessibility, optional OCR, contour and segmentation | Grid, bisect, scroll, custom modes, Linux and Windows beta | [neru](neru.md) |
| Homerow | No, paid | Accessibility | Scroll mode, search and labels together | [homerow](homerow.md) |
| Shortcat | No, free beta | Accessibility, search first | Menu search, window switching | [shortcat](shortcat.md) |
| Scoot | BSD-3 | Accessibility | Grid, freestyle pointer | [scoot](scoot.md) |
| Vimac | GPL-3, discontinued | Accessibility | Scroll mode | [vimac](vimac.md) |
| Mouseless | No, paid | Coordinate grid, label mode in beta | macOS, Windows, Linux | [mouseless](mouseless.md) |
| Wooshy | No, free with naps or subscription | Accessibility, search | Whole-UI search, text yank | [wooshy](wooshy.md) |
| Superkey | No, paid | OCR, optional Accessibility | Hyper key, remaps | [superkey](superkey.md) |
| warpd | MIT, unmaintained | Pixels, no element detection | Persistent vi pointer mode, Linux | [warpd](warpd.md) |
| Neverclick | No, free, Windows | A screen capture | Path, sticky, words | [migration guide](../neverclick.md) |
| mousemaster | MIT, Windows and macOS as root | Accessibility, grids, capture | Combos and remapping | [migration guide](../mousemaster.md) |

## Browser extensions

| | Page |
| --- | --- |
| Vimium | [vimium](vimium.md) |
| Surfingkeys | [surfingkeys](surfingkeys.md) |

## Automation and launchers

| | Page |
| --- | --- |
| Hammerspoon | [hammerspoon](hammerspoon.md), and the [migration guide](../hammerspoon.md) |
| Raycast | [raycast](raycast.md) |
| Alfred | [alfred](alfred.md) |

## Bars and widgets

| | Page |
| --- | --- |
| SketchyBar | [sketchybar](sketchybar.md) |
| Übersicht | [uebersicht](uebersicht.md) |
| conky | [conky](conky.md) |

## Window managers

Flash places and focuses windows but does not tile. These run next to it.

| | Page |
| --- | --- |
| AeroSpace | [aerospace](aerospace.md) |
| yabai | [yabai](yabai.md) |
| Rectangle | [rectangle](rectangle.md) |

## What Flash does not do, whoever you come from

- It reads no pixels. An app that exposes nothing to Accessibility (a
  canvas, a game, a remote desktop) gets the keyboard grid, not labels.
- It runs on macOS 14 or later only. There is no Linux or Windows build.
- It has no preferences window. Everything is one TOML file.
- It does not tile windows, remap hardware keys or expand text.
- Version 1.0.0 shipped in October 2026 from one maintainer. Configuration
  keys that get renamed receive no compatibility shims.

The [comparison table and FAQ](../comparison.md) is the one-screen summary.
