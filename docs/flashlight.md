# flashlight

`:flashlight` is a fast, typo-tolerant command bar for locations and plugin data. Its default results include apps, browser tabs, tmux windows, and other destinations. Select an explicit source for richer searches:

```text
:flashlight @notes.notes inbox
:flashlight @emojis.glyphs fire
:flashlight @system.actions
```

Browser history and bookmarks are per-browser and deliberately opt-in: they
never join the default result pool, and reach the flashlight only through an
explicit source filter or their bang.

```text
:flashlight @firefox.history rust
:flashlight @chrome.bookmarks docs
!fh rust      # Firefox history      (!fb bookmarks)
!ch docs      # Chrome history       (!cb bookmarks)
```

Bare arithmetic, unit conversions, currency conversions, color conversions, and world clocks are answered inline by the bundled `answers` plugin. Use `:plugins` to inspect bundled integrations and their status, or `:about` to open the About Flash window.

The bundled tmux source automatically merges every attached local server with
remote tmux sessions launched through SSH or Mosh. It discovers terminal apps,
PTYs, transports, hosts, tmux paths, and windows from the live process graph—no
terminal- or host-specific configuration is required. Catalogs refresh in the
background, keep their last good remote snapshot through brief disconnects,
then expire it after two minutes without a successful refresh. Mosh-attached
catalogs use short noninteractive SSH calls for inventory; the interactive Mosh
transport remains independent. Otherwise-identical windows are labelled by
host. The tmux source registers no keyboard mappings: terminal-native shortcuts
can send the user's normal tmux prefix bindings with zero Flash round trips.
Flash still resolves any discovered local or remote window from the finder.
Tmux hint discovery recognizes quoted absolute paths (including spaces and
Unicode), slash-separated relative paths, URLs, and ordinary filenames while
excluding dotted source identifiers such as `JumpTarget.entersInsertMode`.
Committing a terminal link with `f` sends Shift-click; `F` sends Command-Shift
so the terminal can open it in a new context. Flash does not open the value
itself.
Pane hints stay in NORMAL mode and preserve the requested click modifiers.

See [normal mode](normal-mode.md) for shortcuts and mode behavior, and
[plugin configuration](plugin-cookbook.md) for extending the catalog.
