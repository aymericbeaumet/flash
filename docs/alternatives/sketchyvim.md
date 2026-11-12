# Flash and SketchyVim

[SketchyVim](https://github.com/FelixKratz/SketchyVim) "Adds all vim moves
and modes to macOS text fields". It does so with real Vim rather than a
reimplementation: it "turns accessible(!) input fields on macOS into full vim
buffers" by keeping the focused field in sync with a libvim buffer, so every
mode, the command line and the remappings in your `svimrc` behave as Vim's
do. Felix Kratz, who also wrote [SketchyBar](sketchybar.md), publishes it
under GPL-3.0 as the `svim` formula of his Homebrew tap, run as a background
service. It has about 1,000 stars; v1.0.11 came out on 11 February 2024 and
the last commit is from March 2024.

Flash does the other half: it is Vim for the desktop around the field,
with Vim's motions inside it in NORMAL to move and select what you copy,
and hands the field, in INSERT, entirely to the app and to SketchyVim.
Flash edits no text at all, by design
([what Flash does not do with text](../vim.md#what-flash-does-not-do-with-text)):
editing is SketchyVim's.

| | SketchyVim | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | macOS; the minimum version is not stated | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Where | Accessible text fields, text areas and combo boxes; apps listed in `~/.config/svim/blacklist` are left alone | Every element, window, tab and app on screen |
| Text editing | Vim itself through libvim: every mode, the command line, your `svimrc` | In a field you engage (click it, `gi`, leave INSERT there) NORMAL has Vim's motions with counts (`w` `b` `e`, `0` `^` `$`, `%`, `{` `}`, `t` `T` `;` `,`, `H` `M` `L`, `zz`), computed from the field's text; `h` `j` `k` `l` and the half pages move the caret with the app's arrows; VISUAL (`v`, `V`) selects with the motions for `y` (copy) and `p` (paste over). No edit: no operator, change, delete or cut. INSERT gives the keyboard to the app |
| Hooks | `~/.config/svim/svim.sh` runs on every mode or command-line change, with `$MODE` and `$CMDLINE` | `flash status set` puts a value in the bar the moment a hook runs |
| Configuration | `svimrc`, `blacklist`, `svim.sh` | One TOML file, live reload, `flash config check` |
| Maintenance | v1.0.11, February 2024; quiet since | 1.1.0, October 2026 |

## Where SketchyVim is stronger

- **It is Vim.** Because the field is a libvim buffer, text objects,
  counts, `.` and the `:` line (`:s/foo/bar/`) are Vim's own, not an
  approximation, and a `noremap` in `svimrc` works as it does in your
  editor. Flash's motions in a field are Vim's, checked against Vim 9.1,
  but they only move the caret and grow a selection that `y` copies and
  `p` pastes over: Flash deletes, changes and cuts nothing.
- **Your Vim configuration carries over**, up to its known limits: the
  README notes that multi-key remaps such as `jk` for Escape are not
  recognized and that comments break `svimrc`.
- **A hook on every mode change.** `svim.sh` receives the mode and the
  command line, which is how its author shows them in SketchyBar.
- **Free, open and small**: one binary and three plain files.

## Where Flash is stronger

- **Everything outside the field.** Clicking any control by its label,
  scrolling, tabs, windows, apps and the command line, with a bar to show
  where you are.
- **Fields SketchyVim cannot reach.** Its README notes that Firefox, unlike
  Safari, makes few text fields available to it; Flash's `f`, or the grid
  where a field has no label, still clicks into them, and `i` then types
  there as usual.
- **Selection outside text fields.** HOLD (⌘⌃H) keeps the mouse button
  down so `w`, `b`, `e`, `0` and `$` extend a selection in a web page, a PDF
  or a terminal, and `y` copies it ([HOLD](../hold-mode.md)).
- **Maintained.** SketchyVim has had no commit since March 2024.

## Flash features you might like

- `flash status set` from `svim.sh` puts SketchyVim's mode in Flash's bar
  with nothing polled ([pushed status values](../commands.md#pushed-status-values)).
- Registers across apps: `"ay` yanks a selection into register `a`, `"ap`
  pastes it in another app.
- `mouse target --words --select` selects from one visible word to another
  with two labels.
- Per-app tables, `[mode.apps."<bundle id>".insert.mappings]`, for chords
  that only make sense where SketchyVim edits.

## Moving from SketchyVim

Nothing moves; SketchyVim keeps the fields and Flash takes the rest.

| SketchyVim | Flash |
| --- | --- |
| Vim inside a text field | Stays SketchyVim's, in Flash's INSERT |
| Motions in a field | Flash's NORMAL has Vim's too (`w`, `b`, `$`, `%`, `t`), and VISUAL selects with them for `y`, `d`, `c` and `p`; operators on motions and the `:` line stay SketchyVim's |
| Getting to the field | `f` on it clicks it, `gi` focuses the first one; both keep NORMAL, and `i` types there |
| Escape to Vim's normal mode | Stays SketchyVim's: Escape reaches the app in INSERT |
| Leaving the field to command the app | Your Flash chord for NORMAL |
| `svim.sh` driving a SketchyBar item | `svim.sh` calling `flash status set`, shown as `#{flash.source.svim}` |
| `blacklist` for terminals and editors | Keep it; it only concerns SketchyVim. Flash stays out of terminals and of VS Code, the JetBrains IDEs, Zed and Sublime Text on its own; `[mode.apps."<bundle id>".text] enabled = false` adds an app |
| Visual selection outside fields | HOLD (⌘⌃H) |
| Leave every field to SketchyVim | `[mode.text] enabled = false` |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]

# Optional: Flash never acts on a field's text; SketchyVim alone is Vim there.
[mode.text]
enabled = false

[statusbar]
enabled = true
template = "#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.source.svim}#[align=right]%H:%M"

# Pushed by ~/.config/svim/svim.sh; runs nothing itself.
[statusbar.sources.svim]
```

with `~/.config/svim/svim.sh`:

```sh
#!/usr/bin/env sh
# SketchyVim sets $MODE to N, I, V or C inside a field, and empties it outside.
if [ -n "$MODE" ]; then
  flash status set --name=svim --value="[$MODE]"
else
  flash status clear --name=svim
fi
```

SketchyVim runs as a Homebrew service with a short `PATH`; if `flash` is not
found there, write its full path (`command -v flash` prints it).

## Using both

The two never compete for a key. Flash's keyboard tap sits earlier in the
macOS session than SketchyVim's, so while NORMAL holds the keyboard
SketchyVim sees nothing, and in INSERT every key, Escape included, goes on to
it. A chord you bind in `[mode.all.mappings]` is Flash's in every mode, so
`cmd+ctrl+[` brings NORMAL back from the middle of a Vim edit without
SketchyVim seeing it.

Inside a field, Escape gives you Vim's normal mode and `i` takes you back to
typing; your Flash chord leaves the field altogether. Keep your terminals and
editors in SketchyVim's `blacklist`, as its example does, so a Vim running in
a terminal is never wrapped in a second one.

If you would rather Flash never touched a field's text, `[mode.text]
enabled = false` turns the engagement off: `v` and `V` do nothing, NORMAL's
keys keep their page meaning in every field, and SketchyVim alone is Vim
inside it ([engage a field](../normal-mode.md#engage-a-field)).

*Checked 2026-10-23 against the SketchyVim
[README](https://github.com/FelixKratz/SketchyVim), its
[releases](https://github.com/FelixKratz/SketchyVim/releases), example
[`svim.sh`](https://github.com/FelixKratz/SketchyVim/blob/master/examples/svim.sh),
source and commit history, and its
[Homebrew formula](https://github.com/FelixKratz/homebrew-formulae/blob/master/svim.rb).*
