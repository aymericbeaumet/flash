# Hints and mouse actions

`flash mouse target` labels clickable controls in the focused app. Type a
label to click it, or Escape to cancel. The pointer hides while the labels
are up and returns when it moves. In NORMAL the default is `f`. Labels come
from Accessibility; terminal content can be supplied by the terminals plugin
(tmux panes, links and status-bar tabs).
Flash never reads screen pixels to find targets.

## Choose an action

A mouse action is one prefix and one finisher. `c` is the right-click (the
context menu). It is the operator Vim and Vimium leave free. `r` reloads
and `s` is the search finisher, so neither is that prefix.

| | Click `f` | Grid `F` | Search `s` |
| --- | --- | --- | --- |
| Primary | `f` | `F` | `s` |
| Move `m` | `mf` | `mF` | `ms` |
| Double `d` | `df` | `dF` | `ds` |
| Right-click `c` | `cf` | `cF` | `cs` |

| Goal | CLI |
| --- | --- |
| Primary click | `flash mouse target` |
| Secondary click | `flash mouse target --secondary` |
| Double click | `flash mouse target --double` |
| Move the pointer | `flash mouse target --move` |
| Jump to a letter | `flash mouse bigram` |
| Find by visible text | `flash mouse target --search` |
| Keep choosing targets (`alt+f`) | `flash mouse target --multi` |
| Keep the same labels up | `flash mouse target --sticky` |
| Click everything between two targets | `flash mouse target --path` |
| Label every visible word | `flash mouse target --words` |
| Drag between targets | `flash mouse target --drag` |
| Select between points | `flash mouse target --select` |
| Pick a display by its number | `flash mouse screens` (NORMAL `gm`) |
| Jump to a window edge | `flash mouse warp --edge=top` |
| Step one text line or character | `flash mouse step --direction=down` |
| Save and recall pointer positions | `flash mouse position --action=save` |

While labels are up, Tab restarts the same click on the grid, Shift-Tab
widens it to every app on the screen, and Backspace with nothing typed
returns to the surface before. The [key mappings](/mappings) keyboard shows
the hint alphabet and the grid keys.

Hold a configured magic modifier on the final hint key to include it in the
click; Shift is always available. Terminal link hints add Shift so your
terminal opens the link, and that click stays in NORMAL. The
[command reference](commands.md#command-reference) lists every flag and scope,
and the [live command catalog](/commands) the installed mouse commands.

## Click several targets

`alt+f` (`mouse target --multi`) is a click chain, Vimium's `<a-f>`: after
each click the labels come back for the next one, until Escape. A click can
change what is on screen, so the app is walked again after every click, and
again whenever it reports a change while the chain waits for your next pick
(a page still loading, a list filling in, a sheet sliding down). A control
that is still there keeps its label; new ones get labels and gone ones lose
theirs. A modifier held on the final label key rides that one click, so
Command opens each link in a new tab, as Vimium's `<a-f>` does. `--double`
and `--middle` chain those clicks instead; `--sticky` keeps the same labels
up with no new walk.

The chain ends where a single click would hand the keyboard on: a
Control-click, or a click into the menu bar, leaves the keyboard to the menu
it opens, as `cf` does. Another app coming forward ends it too. A click on
an input does not: no click enters INSERT, so the chain goes on after it,
and Escape ends it in the mode it started in. A pick whose control changed or went
away clicks nothing, and the chain labels the app again. Because a secondary
click always opens a menu, `--multi` and `--sticky` refuse `--secondary` and
a `ctrl` modifier.

## Beyond the focused window

When something of the system's sits in front of the app you are in, `f`
labels that instead, with no other command to learn:

| In front of the app | What `f` labels |
| --- | --- |
| Notification Center's panel | Its notifications (open, expand, Show Less, Clear) and its widgets' buttons and links |
| Control Center's panel or a module (Wi-Fi, Sound, Focus…) | Its toggles, sliders, menus and buttons |
| A menu extra's popover or menu, Apple's or another app's | Its controls and menu items |
| Spotlight and the Apps view | The search results and apps |
| A Dock stack, the Dock's menus | The stack's items, the menu items |
| A dialog from a system agent: Gatekeeper's "downloaded from the Internet" card, an alert, Force Quit, the Character Viewer | Its buttons and fields |
| The screenshot toolbar (⇧⌘5) | Its buttons |
| Mission Control | Its window thumbnails, the Spaces bar's desktops and its add-desktop button, on every display |
| App Exposé | The app's windows |

A notification banner never takes `f` from your app; `mouse notifications`
labels banners, alerts and the panel alike. A system window with nothing to
press (the volume or brightness display) gives `f` back to the app it covers.
A password or Touch ID prompt (SecurityAgent, LocalAuthentication) is never
labelled or clicked, nor the window behind it, so no mapping or script can
answer it for you: `f` does nothing until it closes.

### Mission Control

While Mission Control or App Exposé is up, `f` labels the Dock's view
instead of the windows it shrank. The windows get the easiest labels, then
the desktops, then the add button. Committing a label clicks it: a window or
a desktop leaves Mission Control, while the add button keeps it open, so
an `alt+f` chain carries on there. `mouse target --drag` picks a
window, then the desktop to drop it on. Flash knows Mission Control is open
from the Dock's own Accessibility reports, never by polling or looking at the
screen, and reads only the view's Accessibility tree. A view the Dock is still
building (its opening animation) is read again for up to 750 ms, and stays
silent if it never completes.

Open it however you like (Hyper+3 is `missioncontrol toggle`, or the
trackpad), then press `f` in NORMAL. NORMAL keeps only the keys it maps
while the view is up and lets every other key reach the Dock, so Escape
closes Mission Control as it does without Flash. The keys arrive
through the session tap, as every NORMAL key does; from INSERT an all-mode
chord bound to `mouse target` works the same way, and so does
`flash mouse target` from a launcher.

Use `mouse target --scope=screen` for visible apps across the screen,
including supported Picture in Picture and Stage Manager controls.
`mouse menubar`, `mouse dock` and `mouse notifications` target those system
surfaces directly. When an app does not expose a control through
Accessibility, the [grid](mouse-grid.md) can click its screen position.

## Tune labels and pointer behavior

`[hints] keys` selects a layout or alphabet; `min_length` controls label
length. `label_order` gives the easiest label to the first target in reading
order, to the one nearest the centre, or makes the first key name the zone of
the window (`zones`); `key_priority` lists the keys handed out first. Two-key
labels alternate hands, then prefer the same keyboard row, then a shorter jump
between rows. A key ranks by where it sits: home row, then bottom row, then
top row. [`[overlay]`](config:overlay) controls font, colors and `hint_placement`.
[`[overlay.dark]`](config:overlay.dark) supplies dark-mode color overrides. `click_feedback` draws a
short ring where a click lands. [Hint labels](configuration.md#hint-labels)
covers the details.

Clicks normally leave the pointer on the selected target. Set
`[hints] restore_pointer = true` to return it after clicks, drags and
selections. Move-only commands still move it. NORMAL scrolling acts at the
pointer while it is inside the focused window, so this choice also
determines where scrolling lands
([where a scroll lands](normal-mode.md#where-a-scroll-lands)).

No click changes the mode: `f`, `F` and the letter jump `s` keep NORMAL, on
an input as anywhere else, so press `i` after a click to type there.
Discovery with no targets stays silent.
Inspect [runtime state](/state) and [logs](/logs) for diagnostics, or read
[troubleshooting](troubleshooting.md). [Normal mode](normal-mode.md) has the
complete mouse bindings.
