# Flash and kindaVim

[kindaVim](https://kindavim.app) promises "The mode you love in your
favorite editor, now in your favorite OS", and its repository says where:
"Vim motions to macOS Text Fields, Text Areas, Dropdowns, Lists, Menus...
basically everywhere." Its Accessibility Strategy reads and edits a field
"like a screen reader", accurately, in apps that implement Accessibility
(Xcode, Safari, Notes); its Keyboard Strategy remaps key presses in apps that
do not. It is a closed-source app by the independent developer godbout, in
development since 2020 and released in 2022, with a release roughly every
month: version 97 on 3 September 2026 added Visual mode's `O`, after `aw`
and `aW` in July and a Command-line mode in August. It runs on macOS 14 and
later, with older builds kept for 12 and 13.

Flash's NORMAL is Vim for the desktop around the field: it clicks, scrolls
and switches, and moves through a field's text with Vim's motions; VISUAL
selects with those motions so `y` copies the selection and `p` pastes over
it, and INSERT gives every key to the app. Flash edits no text at all, by
design ([what Flash does not do with text](../vim.md#what-flash-does-not-do-with-text)):
editing is kindaVim's. kindaVim is Vim inside the field, operators on
motions and text objects included. The two share the motions and Visual
mode's basics and otherwise do different halves of the same job.

| | kindaVim | Flash |
| --- | --- | --- |
| License, price | Closed; US$3.88 a month or US$46.28 a year; without a licence it works fully except in the mornings | MIT, free |
| Platforms | macOS 14+; older builds for 12 and 13 | macOS 13+ |
| Permissions | Accessibility, which its main strategy is built on | Accessibility |
| Where | The focused text field, text area, list or menu | Every element, window, tab and app on screen |
| Text editing | Normal, Visual and Command-line modes; motions, operators and text objects (`ciw`, `di(`, `dap`) with counts and repeat in most | In a field you engage (click it, `gi`, leave INSERT there) NORMAL has Vim's motions with counts (`w` `b` `e`, `0` `^` `$`, `%`, `{` `}`, `t` `T` `;` `,`, `H` `M` `L`, `zz`), computed from the field's text; `h` `j` `k` `l` and the half pages move the caret with the app's arrows; VISUAL (`v`, `V`) selects with the motions for `y` (copy) and `p` (paste over). No edit: no operator, change, delete or cut. INSERT gives the keyboard to the app |
| Mode display | The Characters Window, placed and sized as you like; mode exposed to Karabiner-Elements and in a JSON file | The mode pill in Flash's bar |
| Configuration | Settings window with per-app guidance (the Wizard), Karabiner-Elements variables | One TOML file, live reload, `flash config check` |
| Maintenance | Version 97, September 2026; monthly | 1.1.0, October 2026 |

## Where kindaVim is stronger

- **Editing.** Operators, text objects and Visual mode (`ciw`, `dap`,
  `yi"`, `>>`), with counts and `.` on many of them, inside any field that
  exposes its text: Xcode, Notes and Safari's fields among them. Flash's
  motions move the caret or grow a VISUAL selection that `y` copies and `p`
  pastes over, and nothing else touches the text: no operator, no `d`,
  `c`, `s` or `x`, no cut. `f` stays the hints (Vim's `f` is a mapping
  away).
- **Dropdowns and menus.** `j` and `k` walk a dropdown or a menu as well as
  text and lists, and `fn` during a move scrolls the interface instead of
  the caret. Flash's `j` and `k` move a field's caret and a list's
  selection but scroll anywhere else; `ctrl+e` / `ctrl+y` scroll from a
  field.
- **Apps without Accessibility.** The Keyboard Strategy imitates Vim with
  synthesized keys where an app exposes no text; there Flash sends the
  app's own chord for `b`, `e`, `0`, `$`, `gg` and `G` and does nothing
  for the other motions.
- **Tuned per app.** The Wizard carries suggestions for named apps, with
  Audacity, ChatGPT and MindNode among the latest additions.
- **Mode-aware remapping.** With its Karabiner-Elements integration, a
  Karabiner rule can depend on kindaVim's mode (`kVnnoremap`,
  `kVxnoremap`, …); Flash publishes no mode to Karabiner.

## Where Flash is stronger

- **Everything outside the field.** Clicking any control by its label,
  scrolling, tabs, windows, apps, the command line and the status bar.
  kindaVim's few commands outside text (`gt`, `gT`, `:q`, `:w`, `ZZ`) are
  where Flash starts.
- **Free and open.** No subscription, no mornings off, and the source is
  there when an app misbehaves.
- **Open about what it reads.** Both read a field's contents to move
  through it. Flash's keyboard tap only decides whether a key is swallowed,
  never logs or stores one, and in INSERT lets your typing through; NORMAL
  reads a field's text only for a key that measures it (the motions, `h`,
  `l`, VISUAL, `p`), keeps none of it, never reads a password
  field's, and lists all of it in its [privacy](../privacy.md) inventory,
  with the source to check.
- **Text selection across apps by label.** `mouse target --select` clicks
  one label and Shift-clicks another, `mouse target --words --select` picks
  two words, and HOLD (⌘⌃H) holds the mouse button down so `w`, `b`, `e`,
  `0` and `$` extend a selection as a drag would.

## Flash features you might like

- Registers across apps: `"ay` yanks the selection into register `a` in one
  app and `"ap` pastes it in another; `"+` is the system clipboard.
- `mouse target --words` puts a label on every visible word and clicks its
  leading edge, so the caret lands where your next kindaVim motion starts.
- `:w`, `:wq` and `:q` work in Flash's command line too, on the app instead
  of the field: save, save and close the tab, close it
  ([aliases](../commands.md#vim-command-line-aliases)).
- kindaVim's mode in Flash's bar next to Flash's own, read from its
  `environment.json`, as below.

## Moving from kindaVim

Nothing moves: keep kindaVim for editing and add Flash for the rest. What
each piece does in the combination:

| You want to | Use |
| --- | --- |
| Move through a field with Vim's motions | Flash's NORMAL ([Vim motions in text](../normal-mode.md#vim-motions-in-text)), or kindaVim in Flash's INSERT |
| Select in a field and copy it or paste over it | Flash's VISUAL (`v`, `V`, then `y`, `p`), or kindaVim's Visual mode in Flash's INSERT |
| Cut, delete or change the selection | kindaVim's Visual mode, in Flash's INSERT |
| Edit a field with operators and text objects | kindaVim, in Flash's INSERT |
| Get to the field | Flash: `f` on it clicks it and `i` types there; `gi` focuses the first one |
| Leave the field and command the app | Your Flash chord for NORMAL (below) |
| Leave kindaVim's normal mode | kindaVim's own keys: `i`, `a`, `o` |
| Switch tabs | Flash's `gt`/`gT` in NORMAL; kindaVim's in its normal mode |
| Select text in an app with no text access | HOLD (⌘⌃H), then `w`, `b`, `$`, and `y` |
| See both modes | Flash's pill, and kindaVim's mode as a bar source |
| Leave every field to kindaVim | `[mode.text] enabled = false` |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]

# Optional: Flash never acts on a field's text; kindaVim alone is Vim there.
[mode.text]
enabled = false

[statusbar]
enabled = true
template = "#[align=left]#[pill]#{flash.mode}#[nopill] kV #{flash.source.kindavim}#[align=right]%H:%M"

[statusbar.sources.kindavim]
command = ["/bin/sh", "-c", "plutil -extract mode raw -o - \"$HOME/Library/Application Support/kindaVim/environment.json\""]
interval = 1
```

## Using both

Escape is the whole question. kindaVim enters its normal mode on Escape,
and in Flash's INSERT, Escape goes to the app, so kindaVim gets it as
always. Flash's way back to NORMAL is a chord of yours instead; with
`cmd+ctrl+[` above, it stays clear of kindaVim's own alternatives
(double-Escape or Command-Escape to send a real Escape, or a `jk` or
Control-[ entry you may have set).

The order is then: Flash's NORMAL to reach a field (`f` on it, then `i` for
INSERT), kindaVim's Escape for Vim inside the field, kindaVim's `i` to type
again, and your Flash chord when you are done with the field. Flash's NORMAL
swallows the keys it does not map, so keep kindaVim's work to INSERT, where
every key reaches the app ([INSERT](../insert-mode.md#keys-in-insert)).
Flash's NORMAL already moves through the field with Vim's motions; kindaVim's
operators and text objects are what INSERT is for there.

If you would rather Flash never touched a field's text, `[mode.text]
enabled = false` turns the engagement off: `v` and `V` do nothing, NORMAL's
keys keep their page meaning in every field, and kindaVim alone is Vim
inside it ([engage a field](../normal-mode.md#engage-a-field)). With the
switch on, Flash already stays out of VS Code and its forks, the JetBrains
IDEs, Zed and Sublime Text, which edit text their own way;
`[mode.apps."<bundle id>".text] enabled = false` keeps it out of any other app.

*Checked 2026-10-23 against [kindavim.app](https://kindavim.app), its
[subscription page](https://kindavim.app/subscribe), the kindaVim
[repository and release notes](https://github.com/godbout/kindaVim.blahblah),
and its documentation on
[the Accessibility Strategy](https://docs.kindavim.app/implementation/accessibility-strategy),
[commands](https://docs.kindavim.app/implementation/commands),
[custom mappings](https://docs.kindavim.app/integrations/custom-mappings) and
[the JSON file](https://docs.kindavim.app/integrations/json-file).*
