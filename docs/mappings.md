# Mapping syntax

The live [key mappings](/mappings) page shows the effective bindings from
defaults, plugins and your configuration, grouped by mode. With the search
empty they stay alphabetical by the command; a search ranks what the binding
does, and a close spelling still matches. Each row's `?` explains that
binding, and its Source column uses the same badge as the command list. Press
`?` in NORMAL or run `:mappings` to open it; it focuses its search. Above the
list, your layout is drawn with what each key does in the mode picked under
it: NORMAL, Text (NORMAL in a field you engaged), VISUAL, HOLD, HYPER, INSERT,
COMMAND, TERMINAL, each of your layers or all of them, with free keys dashed. Modifier buttons show the chord layers, a prefix key opens what
can follow it, and picking a key keeps its bindings in the list, each with the
TOML that rebinds or removes it. The keyboard can show the hint alphabet, the
grid keys and the zones instead. This page explains how to write your own.

## Add, replace or remove a binding

<!-- modes: assumed on -->

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]

[mode.normal.mappings]
"t" = false
"gs" = ["flash", "mouse", "target", "--scope=screen"]
"[a" = { command = ["flash", "app", "previous"], repeat = true }
```

`all` applies across modes; `normal`, `insert`, `command`, `terminal`,
`hyper`, `hold` and `visual` scope bindings to that mode, and `text` to
NORMAL while a field is engaged, read before `normal`
([engage a field](normal-mode.md#engage-a-field)). [VISUAL](visual-mode.md)
reads `visual`, then only the motions of `text` and `normal`, then `all`. `false` removes
an inherited binding. A
repeatable sequence accepts its final key again without requiring the
prefix. Save the file to apply changes.

A layer is a table of your own, `[mode.layers.<name>.mappings]`, that
`mode layer --name=<name>` enters and Escape leaves; only its keys and the
`all` ones act there ([layers](layers.md)):

```toml
[mode.normal.mappings]
"<leader>r" = ["flash", "mode", "layer", "--name=resize"]

[mode.layers.resize.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
```

An argv beginning with `flash` dispatches a Flash command, always its topic
and action (`["flash", "tab", "next"]`). Other argv launch a program. Use an
explicit shell (`/bin/sh`, `-c`, script) when you need pipes or redirection.
See the [commands](commands.md) for every command, the live
[command catalog](/commands) for the installed ones, and
[configuration](configuration.md#commands-and-mappings) for app-scoped tables
and layering.

## Writing keys

Flash mapping keys are a sequence of "atoms": each atom is one keystroke (a
bare character, a named key, or a modifier chord).

## Bare characters

Letters, digits, and **any printable ASCII punctuation** are written
literally. No angle brackets, no escapes:

```toml
"h"        # the h key
"'a"       # apostrophe then a
"[t"       # left bracket then t
"/"        # forward slash
":"        # colon
```

The three syntactic markers `+`, `<`, and `>` cannot appear bare: they would
conflict with modifier-chord and `<name>` parsing. Use `<plus>`, `<less>`,
`<greater>` instead.

## Named keys

Anything that isn't a single typeable character is wrapped in `<>` with a
fullname. The parser also accepts a single bare-allowed character inside `<>`
as an alias (`<a>` == `a`, `<'>` == `'`).

Special keys: `<tab>` `<space>` `<escape>` (also `<esc>`) `<enter>` (also
`<return>`) `<delete>` (also `<backspace>`) `<delete_forward>` (also
`<forward_delete>`) `<up>` `<down>` `<left>` `<right>` `<home>` `<end>`
`<pageup>` `<pagedown>`, the [function keys](#function-keys) `<f1>` to
`<f20>`, and `<leader>`, substituted with the value of `[mode.normal] leader`
at config load.

Punctuation fullnames (when you'd rather not type the symbol): `<colon>`
`<semicolon>` `<comma>` `<period>` `<slash>` `<question>` `<bang>`
`<apostrophe>` `<quote>` `<lbracket>` `<rbracket>` `<lbrace>` `<rbrace>`
`<lparen>` `<rparen>` `<less>` `<greater>` `<minus>` `<underscore>`
`<equal>` `<plus>` `<asterisk>` `<ampersand>` `<caret>` `<percent>`
`<dollar>` `<hash>` `<at>` `<tilde>` `<backtick>` `<backslash>` `<pipe>`

## Modifier chords

Modifier names join with `+`. Aliases: `cmd`/`command`, `ctrl`/`control`,
`shift`, `alt`/`opt`/`option`. The last token is the key (bare char or
`<name>`); after a modifier a name may also go without its brackets
(`cmd+space`, `cmd+f12`).

```toml
"ctrl+i"               # Ctrl + I
"cmd+shift+<lbracket>" # Cmd + Shift + [
"cmd+<delete>"         # Cmd + Backspace
```

## Function keys

`<f1>` to `<f20>` bind like any named key, alone, in a sequence or in a
chord:

```toml
[mode.normal.mappings]
"<f5>" = ["flash", "config", "reload"]

[mode.all.mappings]
"cmd+<f12>" = ["flash", "mode", "terminal"]
```

Written bare, `"f12"` is the three keys f, 1 and 2, so Flash rejects it as a
likely mistake; spell that sequence `"f 1 2"` if you mean it.

On a Mac keyboard the top row types brightness, volume and media keys and
sends F1–F12 only while you hold fn, unless "Use F1, F2, etc. keys as
standard function keys" is on in System Settings › Keyboard (the global
`com.apple.keyboard.fnState`, which a [startup command](startup.md) can
set); F13–F20 come from extended and external keyboards. A function key on
its own acts where Flash holds the keyboard: NORMAL, VISUAL, HYPER, HOLD and
layers.
INSERT reads only chords, so bind `cmd+<f5>` or another modifier there.
`shift+<f1>` is a binding of its own; without one, Shift-F1 is F1.

## Sequences

Multiple atoms concatenate to form a sequence. Whitespace between atoms is
purely visual and is stripped:

```toml
"gg"                # g then g
"<leader>m"         # leader then m
"ctrl+i <leader>c"  # same as "ctrl+i<leader>c"
```

Avoid assigning a prefix its own action: if both `t` and `tf` exist, `t`
waits for `sequence_timeout_ms` to see whether more keys follow. Remove `t`
first if you want `tf` to execute without that ambiguity.

## Leader value

`[mode.normal] leader` must resolve to exactly one atom. Use a single bare
char, a `<fullname>` form, or a single-char `<x>`.

```toml
leader = "<space>"       # Space key
leader = "<backslash>"   # Backslash
leader = "\\"            # Backslash (bare; TOML needs the escape)
leader = "'"             # Apostrophe
```
