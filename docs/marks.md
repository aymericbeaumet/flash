# Marks

Each letter `a`–`z` or digit `0`–`9` holds one mark. Setting a mark records
the focused app's process ID and bundle identifier, so a jump survives the
app quitting and Flash restarting.

## Commands

```text
flash mark set --letter=a
flash mark jump --letter=a
```

The same words run from the command line (`:mark set --letter=a`) and in a
mapping. A letter is one ASCII letter or digit; `A` is the mark `a`, and
anything else is rejected, so a typo never makes a mark.

`mark set` saves the app you were working in, never Flash itself, even when
you run it from Flash's command line. `mark jump` raises the saved process
while it is still that app. If it is gone, Flash raises another running copy
of the app and the mark follows it, or launches the app. A jump joins the
movement history, so `movement back` returns to where you were. Neither
command changes mode.

## Keys

NORMAL reads Vim's mark keys: `m{x}` saves the focused app as mark `x`, and
`'{x}` or `` `{x} `` brings it back. They give way to any mapping on the same
keys: `mf`, `mF` and `ms` stay the mouse moves (set those three marks with
`mark set --letter=f` and so on), and a `'a` your configuration binds runs
instead of jumping to mark `a`, while `'d` still jumps. Bind other keys like
any command:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>a" = ["flash", "mark", "jump", "--letter=a"]
```

## Storage

The 36 slots persist to
`~/Library/Application Support/Flash/marks.json`. Flash moves the file the
retired marks plugin kept under `Plugins/marks/share/` there on first launch.
[Privacy](privacy.md#data-stored-on-your-mac) lists everything Flash stores.
