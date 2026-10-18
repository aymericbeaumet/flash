# flashlight

`:flashlight` is a fast, typo-tolerant command bar for locations and plugin data. Its default results include apps, browser tabs, tmux windows, and other destinations. Select an explicit source for richer searches:

```text
:flashlight @notes.notes inbox
:flashlight @emojis.glyphs fire
:flashlight @system.actions
```

Browser history and bookmarks are per-browser and never join the default
result pool: they reach the flashlight only through an explicit source filter
or their bang. The bundled `history` plugin still runs by default, copying
Firefox `places.sqlite` and Chrome `History` into its private cache (and
reading Chrome `Bookmarks`) at launch, when the flashlight opens, and when you
leave Firefox or Chrome — at most once a minute, and only when those stores
changed; disable it with `[plugins] disabled = ["history"]`.

```text
:flashlight @firefox.history rust
:flashlight @chrome.bookmarks docs
!fh rust      # Firefox history      (!fb bookmarks)
!ch docs      # Chrome history       (!cb bookmarks)
```

## Ranking

Results rank by what the query says about each row's own name first, and by
where the row comes from second:

1. A registered `!bang` the user typed.
2. Match tier against the row's name (title and aliases): exact, then a prefix
   of the name, then a word start inside it or every query word starting one of
   its words in any order (`flash github` finds `GitHub - aymericbeaumet/flash`),
   then a substring, then rows the query only touches through secondary text
   (URL, subtitle, source) or the typo-tolerant fuzzy matcher. Naming a source
   (`tmux` for `tmux.windows`) counts as an exact hit on its rows. The tier is
   strict: typing a tab's title lands on that tab above every app the query
   matches partially, and `mes` still puts Messages.app above a tab that merely
   contains "mes".
3. Source precedence inside one tier: the manifest `sources[].priority`
   (bundled: tmux windows `important`, apps and browser tabs `high`), a bonus
   for rows backed by a running process, and `[flashlight.precedence]`
   overrides. With no query this is the whole order: tmux windows, then running
   apps and open tabs, then installed apps, then other plugin locations.
4. Match score (how tightly the query fits the field) plus frecency, the
   recency-weighted count of past opens.

`app_open --name=<text>` resolves app names precisely first, then ranks every
plugin location the same way and opens the first row.

Bare arithmetic, unit conversions, currency conversions, color conversions, and world clocks are answered inline by the bundled `answers` plugin. Use `:plugins` to inspect bundled integrations and their status, or `:about` to open the About Flash window.

The bundled tmux source automatically merges every attached local server.
Remote tmux sessions launched through SSH or Mosh join only for hosts listed in
`[plugin.tmux] ssh_hosts` (destinations as typed, without `user@`). Remote
inventory uses the plugin's own short noninteractive SSH calls, which can
prompt an SSH agent or hardware key and appear in the remote auth log, so
without that setting the plugin never inspects SSH/Mosh processes or runs
`ssh`. For a listed host it discovers terminal apps, PTYs, transports, tmux
paths, and windows from the live process graph—no terminal-specific
configuration is required. Catalogs refresh in the background, keep their last
good remote snapshot through brief disconnects, then expire it after two
minutes without a successful refresh. The interactive Mosh transport remains
independent of those inventory calls. Otherwise-identical windows are labelled
by host. The tmux source registers no keyboard mappings: terminal-native shortcuts
can send the user's normal tmux prefix bindings with zero Flash round trips.
Flash still resolves any discovered local or remote window from the finder.
Tmux hint discovery recognizes quoted absolute paths (including spaces and
Unicode), slash-separated relative paths, URLs, and ordinary filenames while
excluding dotted source identifiers such as `JumpTarget.entersInsertMode`.
Committing a terminal link with `f` sends Shift-click; `F` sends Command-Shift
so the terminal can open it in a new context. Flash does not open the value
itself.
Pane, window and link hints preserve the requested click modifiers. A
primary click on a pane or window hint enters INSERT: the terminal owns the
keyboard next. A primary click on a terminal link hint stays in NORMAL.

See [normal mode](normal-mode.md) for shortcuts and mode behavior, and
[plugin configuration](plugin-cookbook.md) for extending the catalog.
