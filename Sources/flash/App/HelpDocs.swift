import Foundation

struct HelpTopic: Equatable {
  var name: String
  var title: String
  var summary: String
  var body: String
  /// Extra strings that resolve to this topic in `:help <topic>`.
  /// Use for singular/plural pairs (`mark` ↔ `marks`) or short forms.
  var aliases: [String] = []
  /// The section the browser help files the topic under, in reading order.
  /// `HelpDocs.allTopics` assigns built-in groups; plugin topics share one.
  var group: String = HelpDocs.pluginGroup
  /// The manual page (`docs/<page>.md`) holding the long-form reference, or
  /// nil when the guide is the whole story.
  var manual: String? = nil
}

enum HelpDocs {
  static func repositoryRoot(revision: String?) -> String {
    let isCommit =
      revision.map { value in
        value.count == 40 && value.allSatisfy { $0.isHexDigit }
      } ?? false
    let reference = isCommit ? revision! : "HEAD"
    return "https://github.com/aymericbeaumet/flash/blob/\(reference)"
  }

  static let repositoryRoot = repositoryRoot(
    revision: Bundle.main.object(forInfoDictionaryKey: "FlashGitCommit") as? String)

  /// The published manual, built from `docs/` by the Docs workflow. Guides
  /// link their long-form references there; source files that are not pages
  /// keep `repositoryRoot` links.
  static let manualRoot = "https://aymericbeaumet.github.io/flash"

  static func manual(_ page: String) -> String {
    page.isEmpty ? "\(manualRoot)/" : "\(manualRoot)/\(page)/"
  }

  static func render(
    topic rawTopic: String?,
    config: Config,
    showModes: Bool,
    pluginTopics: [HelpTopic] = []
  ) -> String {
    let topics = allTopics(
      config: config, showModes: showModes, pluginTopics: pluginTopics)
    guard let rawTopic,
      !rawTopic.trimmed.isEmpty
    else {
      return index(topics)
    }
    let name = normalize(rawTopic)
    guard
      let topic = topics.first(where: { topic in
        normalize(topic.name) == name
          || topic.aliases.contains(where: { normalize($0) == name })
      })
    else {
      return unknownTopic(name, topics: topics)
    }
    return render(topic)
  }

  static let pluginGroup = "Plugin guides"

  /// Reading order of the built-in guides: the browser's sidebar, index,
  /// previous/next links and `:help` listing all follow it. A topic absent
  /// from this table is a bug caught by the help tests.
  static let groups: [(title: String, names: [String])] = [
    ("Start here", ["overview", "getting-started", "hints", "normal-mode", "mappings"]),
    ("Move and discover", ["mouse-grid", "flashlight", "verbs"]),
    ("Make it yours", ["config", "statusbar", "status-format", "widgets", "popups"]),
    ("Extend and understand", ["plugins", "privacy", "troubleshooting", "development", "manual"]),
  ]

  /// Manual pages behind the built-in guides (`HelpDocs.manual`).
  static let manualPages: [String: String] = [
    "overview": "",
    "getting-started": "getting-started",
    "hints": "commands",
    "normal-mode": "normal-mode",
    "mappings": "configuration",
    "mouse-grid": "commands",
    "flashlight": "flashlight",
    "verbs": "commands",
    "config": "configuration",
    "statusbar": "status-format",
    "status-format": "status-format",
    "widgets": "widgets",
    "popups": "popups",
    "plugins": "plugin-cookbook",
    "privacy": "privacy",
    "troubleshooting": "troubleshooting",
    "development": "development",
    "manual": "",
  ]

  static func allTopics(
    config: Config,
    showModes: Bool,
    pluginTopics: [HelpTopic] = []
  ) -> [HelpTopic] {
    let declared: [HelpTopic] = [
      overviewTopic,
      gettingStartedTopic,
      manualTopic,
      hintsTopic,
      mouseGridTopic,
      mappingsTopic,
      flashlightTopic,
      NormalModeDispatcher.helpTopic(config: config, showModes: showModes),
      URLEventHandler.helpTopic,
      Config.helpTopic,
      statusbarTopic,
      statusFormatTopic,
      widgetsTopic,
      popupsTopic,
      PluginManager.helpTopic,
      privacyTopic,
      troubleshootingTopic,
      developmentTopic,
    ]
    let byName = Dictionary(declared.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var builtIn: [HelpTopic] = []
    for (title, names) in groups {
      for name in names {
        guard var topic = byName[name] else { continue }
        topic.group = title
        topic.manual = manualPages[name]
        builtIn.append(topic)
      }
    }
    // A declared topic missing from `groups` still renders, at the end.
    let placed = Set(builtIn.map(\.name))
    builtIn += declared.filter { !placed.contains($0.name) }
    // Names and aliases share one route namespace. Host topics win, then
    // the first accepted plugin topic owns its names.
    var claimedNames = Set(
      builtIn.map { normalize($0.name) }
        + builtIn.flatMap { $0.aliases.map(normalize) })
    let extras = pluginTopics.filter { topic in
      let names = Set(([topic.name] + topic.aliases).map(normalize))
      guard claimedNames.isDisjoint(with: names) else { return false }
      claimedNames.formUnion(names)
      return true
    }
    return builtIn + extras.sorted { $0.name < $1.name }
  }

  static let mappingsTopic = HelpTopic(
    name: "mappings",
    title: "Mapping Syntax",
    summary: "How to spell keys and modifier chords in flash.toml.",
    body: """
      # Mapping Syntax

      The [live mappings page](/mappings) shows the effective bindings from
      defaults, plugins and your configuration. Bindings are grouped by mode.
      With the search empty they stay alphabetical by the command; a search
      ranks what the binding does, and a close spelling still matches. Each
      row's ? explains that binding. The Source column uses the same badge as
      the command list. The page focuses its search when it opens. Press `?`
      in NORMAL or run `:mappings` to open it. Above the list, your layout is
      drawn with what each key does in the mode picked under it: NORMAL,
      VISUAL, DRAG, HYPER, INSERT, COMMAND, TERMINAL or all of them, with free keys
      dashed. Modifier buttons show the chord layers, a prefix key opens what
      can follow it, and picking a key keeps its bindings in the list, each
      with the TOML that rebinds or removes it. The keyboard can show the hint
      alphabet, the grid keys and the zones instead. This guide explains how
      to write your own.

      ## Add, replace or remove a binding

      ```toml
      [mode.all.mappings]
      "cmd+shift+space" = ["flash", "mouse_target"]

      [mode.normal.mappings]
      "t" = false
      "gs" = ["flash", "mouse_target", "--scope=screen"]
      "[a" = { command = ["flash", "app_previous"], repeat = true }
      ```

      `all` applies across modes; `normal`, `insert`, `command` and
      `terminal` scope bindings to that mode. `false` removes an inherited
      binding. A repeatable sequence accepts its final key again without
      requiring the prefix. Save the file to apply changes.

      An argv beginning with `flash` dispatches a Flash verb. Other argv
      launch a program. Use an explicit shell (`/bin/sh`, `-c`, script)
      when you need pipes or redirection. See the [command inventory](/commands)
      for installed verbs and the [configuration guide](/docs/config).

      ## Writing keys

      Flash mapping keys are a sequence of "atoms" — each atom is one
      keystroke (a bare character, a named key, or a modifier chord).

      ## Bare characters

      Letters, digits, and **any printable ASCII punctuation** are
      written literally. No angle brackets, no escapes:

      ```toml
      "h"        # the h key
      "'a"       # apostrophe then a
      "[t"       # left bracket then t
      "/"        # forward slash
      ":"        # colon
      ```

      The three syntactic markers `+`, `<`, and `>` cannot appear bare —
      they would conflict with modifier-chord and `<name>` parsing.
      Use `<plus>`, `<less>`, `<greater>` instead.

      ## Named keys

      Anything that isn't a single typeable character is wrapped in
      `<>` with a fullname. The parser also accepts a single
      bare-allowed character inside `<>` as an alias (`<a>` == `a`,
      `<'>` == `'`).

      Special keys:
        `<tab>` `<space>` `<escape>` (also `<esc>`) `<enter>`
        (also `<return>`) `<delete>` (also `<backspace>`)
        `<delete_forward>` (also `<forward_delete>`)
        `<up>` `<down>` `<left>` `<right>`
        `<home>` `<end>` `<pageup>` `<pagedown>`
        `<leader>` — substituted with the value of
        `[mode.normal] leader` at config load.

      Punctuation fullnames (when you'd rather not type the symbol):
        `<colon>` `<semicolon>` `<comma>` `<period>` `<slash>`
        `<question>` `<bang>` `<apostrophe>` `<quote>`
        `<lbracket>` `<rbracket>` `<lbrace>` `<rbrace>`
        `<lparen>` `<rparen>` `<less>` `<greater>`
        `<minus>` `<underscore>` `<equal>` `<plus>`
        `<asterisk>` `<ampersand>` `<caret>` `<percent>`
        `<dollar>` `<hash>` `<at>` `<tilde>` `<backtick>`
        `<backslash>` `<pipe>`

      ## Modifier chords

      Modifier names join with `+`. Aliases: `cmd`/`command`,
      `ctrl`/`control`, `shift`, `alt`/`opt`/`option`. The last token
      is the key (bare char or `<name>`).

      ```toml
      "ctrl+i"               # Ctrl + I
      "cmd+shift+<lbracket>" # Cmd + Shift + [
      "cmd+<delete>"         # Cmd + Backspace
      ```

      ## Sequences

      Multiple atoms concatenate to form a sequence. Whitespace
      between atoms is purely visual and is stripped:

      ```toml
      "gg"                # g then g
      "<leader>m"         # leader then m
      "ctrl+i <leader>c"  # same as "ctrl+i<leader>c"
      ```

      Avoid assigning a prefix its own action: if both `t` and `tf` exist,
      `t` waits for `sequence_timeout_ms` to see whether more keys follow.
      Remove `t` first if you want `tf` to execute without that ambiguity.

      ## Leader value

      `[mode.normal] leader` must resolve to exactly one atom. Use a
      single bare char, a `<fullname>` form, or a single-char `<x>`.

      ```toml
      leader = "<space>"       # Space key
      leader = "<backslash>"   # Backslash
      leader = "\\\\"            # Backslash (bare; TOML needs the escape)
      leader = "'"             # Apostrophe
      ```
      """)

  private static let gettingStartedTopic = HelpTopic(
    name: "getting-started",
    title: "Getting started",
    summary: "Your first hint, a search shortcut, and a path into NORMAL mode.",
    body: """
      # Getting started

      Flash gives your keyboard access to controls across macOS. Start with
      one shortcut; add modes, a status bar and widgets when you want them.

      ## Click your first hint

      Grant Flash Accessibility in System Settings → Privacy & Security →
      Accessibility. Focus another app, press `cmd+shift+space`, then type
      the label on the control you want. Escape cancels.

      The starter configuration supplies that shortcut. Your actual bindings
      are listed in [Mappings](/mappings), including changes made by plugins
      or your own file. From a terminal, `flash mouse_target` does the same job.

      ## Make it yours

      Choose **Open Configuration** from the menu-bar bolt. Flash watches the
      file and applies changes when you save. Add these entries to your existing
      `[mode.all.mappings]` table rather than declaring the table twice:

      ```toml
      [mode.all.mappings]
      "cmd+shift+space" = ["flash", "mouse_target"]
      "cmd+shift+alt+space" = ["flash", "mouse_grid"]
      "cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "]
      ```

      Keep the space after `:flashlight`: it opens the search prompt directly.
      Try an app name, `@emojis.glyphs fire`, or `2 km to m`.

      ## Use NORMAL when you are ready

      Add explicit entry and exit shortcuts:

      ```toml
      [mode.all.mappings]
      "cmd+ctrl+[" = ["flash", "enter_normal_mode"]
      "cmd+ctrl+i" = ["flash", "enter_insert_mode"]
      ```

      In NORMAL, `f` opens hints, `F` opens the grid, `:` opens commands and
      `?` opens your mappings. Unmapped keys are captured. Use your INSERT
      shortcut to type again; clicking or selecting an input, `/` (Find) and
      `t` (new tab) also enter INSERT. NORMAL otherwise stays active as you
      switch apps and tabs.

      Next: [hints](/docs/hints), [grid](/docs/mouse-grid),
      [NORMAL mode](/docs/normal-mode), [flashlight](/docs/flashlight),
      or [configuration](/docs/config). If something fails, start with
      [troubleshooting](/docs/troubleshooting) and [live runtime state](/state).
      """,
    aliases: ["start"])

  private static let hintsTopic = HelpTopic(
    name: "hints",
    title: "Hints & mouse actions",
    summary: "Click controls, find visible text, and target menus or notifications.",
    body: """
      # Hints & mouse actions

      `flash mouse_target` labels clickable controls in the focused app.
      Type a label to click it, or Escape to cancel. The pointer hides while
      the labels are up and returns when it moves. In NORMAL the default
      is `f`. Labels come from Accessibility; terminal content can be supplied
      by the tmux plugin. Flash never reads screen pixels to find targets.

      ## Choose an action

      A mouse action is one prefix and one finisher. `c` is the right-click
      (the context menu). It is the operator Vim and Vimium leave free.
      `r` reloads and `s` is the search finisher, so neither is that prefix.

      | | Click `f` | Grid `F` | Search `s` |
      | --- | --- | --- | --- |
      | Primary | `f` | `F` | `s` |
      | Move `m` | `mf` | `mF` | `ms` |
      | Double `d` | `df` | `dF` | `ds` |
      | Right-click `c` | `cf` | `cF` | `cs` |

      | Goal | CLI |
      | --- | --- |
      | Primary click | `flash mouse_target` |
      | Secondary click | `flash mouse_target --secondary` |
      | Double click | `flash mouse_target --double` |
      | Move the pointer | `flash mouse_target --move` |
      | Jump to a letter | `flash mouse_bigram` |
      | Find by visible text | `flash mouse_target --search` |
      | Keep choosing targets | `flash mouse_target --multi` |
      | Keep the same labels up | `flash mouse_target --sticky` |
      | Click everything between two targets | `flash mouse_target --path` |
      | Label every visible word | `flash mouse_target --words` |
      | Drag between targets | `flash mouse_target --drag` |
      | Select between points | `flash mouse_target --select` |
      | Label each display | `flash mouse_screens` |
      | Jump to a window edge | `flash mouse_warp --edge=top` |
      | Step one text line or character | `flash mouse_step --direction=down` |
      | Save and recall pointer positions | `flash mouse_position --action=save` |

      While labels are up, Tab restarts the same click on the grid, Shift-Tab
      widens it to every app on the screen, and Backspace with nothing typed
      returns to the surface before. The [key mappings](/mappings) keyboard
      shows the hint alphabet and the grid keys.

      Hold a configured magic modifier on the final hint key to include it in
      the click; Shift is always available. Terminal link hints add Shift so
      your terminal opens the link, and that click stays in NORMAL. The [command inventory](/commands) lists
      all flags, scopes and installed mouse verbs.

      ## Beyond the focused window

      Use `mouse_target --scope=screen` for visible apps across the screen,
      including supported Picture in Picture and Stage Manager controls.
      `mouse_menubar`, `mouse_dock` and `mouse_notifications` target those
      system surfaces. When an app does not expose a control through
      Accessibility, the [grid](/docs/mouse-grid) can click its screen position.

      ## Tune labels and pointer behavior

      `[hints] keys` selects a layout or alphabet; `min_length` controls
      label length. `label_order` gives the easiest label to the first target
      in reading order, to the one nearest the centre, or makes the first key
      name the zone of the window (`zones`); `key_priority` lists the keys
      handed out first. Two-key labels alternate hands, then prefer the same
      keyboard row, then a shorter jump between rows. A key ranks by where
      it sits: home row, then bottom row, then top row. `[overlay]`
      controls font, colors and `hint_placement`.
      `[overlay.dark]` supplies dark-mode color overrides. `click_feedback`
      draws a short ring where a click lands.

      Clicks normally leave the pointer on the selected target. Set
      `[hints] restore_pointer = true` to return it after clicks, drags and
      selections. Move-only commands still move it. NORMAL scrolling acts
      at the pointer, so this choice also determines where scrolling lands.

      A primary click on an input enters INSERT; a secondary click preserves
      NORMAL. Discovery with no targets stays silent. Inspect [runtime state](/state)
      and [logs](/logs) for diagnostics, or read [troubleshooting](/docs/troubleshooting).
      """,
    aliases: ["hint", "mouse"])

  private static let mouseGridTopic = HelpTopic(
    name: "mouse-grid",
    title: "Mouse grid & pointer",
    summary: "Reach any screen position with a keyboard grid, bisection, or dragging.",
    body: """
      # Mouse grid & pointer

      `flash mouse_grid` (NORMAL `F`) divides the display into a keyboard-shaped
      grid, including Flash's status bar. Press the key nearest your destination
      to zoom into its cell. Repeat until the last step clicks. Every step uses
      the same layout. The grid stops at the Dock, and at the menu bar when the
      Flash bar is hidden.

      ```text
      1 2 3 4 5
      q w e r t
      a s d f g
      z x c v b
      ```

      These are the QWERTY keys. Layout references in `[hints] keys` select
      the corresponding left-hand block; `mouse_grid_keys` supplies your own
      rectangular matrix. `mouse_grid_steps` defaults to three.

      | Key | Action |
      | --- | --- |
      | Grid key | Refine, then click on the last step |
      | Space | Refine toward the center |
      | Return | Click the current region's center now |
      | Backspace | Undo a selection, move or display switch |
      | Command/Option-Backspace | Start over on the display |
      | Arrow keys | Move the region by its own size |
      | Tab / Shift-Tab | Next / previous display |
      | Backtick | Toggle cursor-follow |
      | Escape | Cancel |

      ## Change the action or geometry

      `cF`, `dF` and `mF` request a right-click, a double click and movement.
      The grid accepts the same click modifiers and action flags as hints.
      `--drag` and `--select` collect two positions; `--multi` starts again
      after each click. `--zoom-to-depth=N` begins around the pointer.

      `flash mouse_grid --bisect` keeps a half with the keys at the QWERTY
      h/j/k/l positions of `[keyboard] layout` (h/j/k/l on QWERTY, h/n/e/i on
      Colemak, d/h/t/n on Dvorak, c/t/s/r on Bépo) and a quadrant with the
      keys at y/u and b/n. Bépo's top-left quadrant is the dead key `^`.
      Return commits immediately; otherwise it commits when the region is
      small enough.

      ## Select, drag or steer the pointer

      `v` starts a visual selection (VISUAL): motions such as `j`, `k`, `f`
      and `s` extend it, and `v` or Escape ends it with the text selected. `D`
      drags what is under the pointer with the left button (DRAG), `cD` with
      the right: `h` `j` `k` `l` nudge it, `f` picks where it goes, Return
      drops it and Escape puts it back. `mouse_pointer` opens keyboard
      pointer control.

      See [commands](/commands) for exact flags and [mappings](/mappings)
      for the shortcuts effective in this running instance.
      """,
    aliases: ["grid", "pointer"])

  static let flashlightTopic = HelpTopic(
    name: "flashlight",
    title: "Flashlight",
    summary: "Fuzzy candidate finder across apps, tmux, browsers, plugins.",
    body: """
      # Flashlight

      Flashlight is the unified candidate finder. Its default pool surfaces
      location rows such as apps, tabs, tmux windows, and plugin-provided
      destinations; explicit source filters can show other
      plugin candidate sets such as contacts, notes, and reminders.

      ## Entry points

      - `flash enter_command_mode --input=':flashlight '` from the CLI.
      - A user-defined mapping to `enter_command_mode --input=:flashlight`.
      - `:flashlight <query>` in command-line mode.

      `:open <args>` is unrelated: it forwards verbatim to `/usr/bin/open`
      (URLs, files, `-a App`) with no finder smarts.

      ## Pinning a source

      Add `@<source>` (or `--<source>`) selectors *anywhere* in the query
      to restrict the pool, e.g. `:flashlight @notes inbox` searches only
      notes. Order is irrelevant — `@tmux @notes test` and
      `test @notes @tmux` are the same — and several selectors widen the
      pool (OR): `@tmux @notes` shows both. The token matches a source
      name (or prefix: `@fire` → firefox) and a few groups:
      `@browser`/`@tabs`, `@apps`. Bare `:flashlight @notes` lists every
      note. Typing an incomplete source token such as `@fire` shows source
      suggestions; `<tab>` or `<cr>` inserts the selected canonical source
      filter.

      Typing `!` shows registered bang suggestions. `<tab>` or `<cr>`
      inserts the selected bang token, and adding a space locks it for the
      remaining query.

      Bare input also runs every pure query evaluator registered for the
      flashlight surface. Evaluators return typed, additive answers rather than
      claiming inputs with regular expressions. Flash gathers them for at most
      50 ms, accepts up to 16 answers per evaluator, and places them in a fixed
      lane above fuzzy catalog matches; `!bang` and `@source` input bypasses
      that lane. The bundled `answers` plugin handles arithmetic (`1+1`),
      units (`2 km to m`), currencies (`10 euros`, `10 euros + 10 euros`),
      color conversions (`#ff8800`, `rgb(255, 136, 0)`), and world clocks
      (`time in tokyo`). It loads cached rates before becoming ready and
      refreshes them over the network only in the background. Selecting an
      answer with `<tab>` or `<cr>` copies the exact result.

      Location rows are final destinations: `<tab>` or `<cr>` submits the
      selected row directly, the same as `<cmd-cr>`.

      App switches and focused-window changes feed Flash's movement history
      with the current location when a source can identify it, so `ctrl-o` /
      `ctrl-i` can walk locations reached through ordinary desktop switching.

      ## Ranking

      The default result pool is location-only: apps, tabs, tmux windows, and
      plugin-provided locations. Other sources are hidden
      unless you type an explicit `@source` filter.

      Inside the location band, scoring layers are:

      1. Exact primary-name match.
      2. Prefix match.
      3. Secondary metadata match (URL, tmux session/path, source labels).
      4. Fuzzy subsequence score.
      5. Source-precedence and alive bonuses as tie-breakers.

      ## Plugin candidates

      Plugin catalogs are push-based: each candidate plugin publishes its
      full catalog to the host whenever it changes, and Flash serves the
      flashlight from its own in-memory store — reading it is synchronous and
      performs no I/O and no plugin round-trip. On open the prompt appears
      immediately with its rows hidden while Flash reads every default
      source, including the warm `core.apps` index (which may still be
      finishing its resident startup scan). Flash reveals the initial catalog
      exactly once when every source settles or the 150 ms first-paint budget
      expires; later publishes merge in through a coalesced refresh tick.
      """)

  private static let overviewTopic = HelpTopic(
    name: "overview",
    title: "Your keyboard, all of macOS",
    summary: "Explore Flash's features and the live state of this installation.",
    body: """
      # Your keyboard, all of macOS

      Flash combines hints, persistent keyboard modes, search, status surfaces
      and plugins in one resident macOS app. One TOML file controls it all.

      ## Find your next step

      - [Getting started](/docs/getting-started): one hotkey, then grid, search and modes.
      - [Hints](/docs/hints) and [grid](/docs/mouse-grid): click controls or any screen position.
      - [NORMAL mode](/docs/normal-mode): navigate and edit across apps.
      - [Flashlight](/docs/flashlight): find apps, tabs and plugin data, or calculate an answer.
      - [Configuration](/docs/config) and [mapping syntax](/docs/mappings): make it yours.
      - [Status bar](/docs/statusbar), [widgets](/docs/widgets) and [popups](/docs/popups):
        bring the information and terminal tools you use into reach.
      - [Plugins](/docs/plugins): add catalogs, actions, answers and status values.

      ## This browser is also your live reference

      [Mappings](/mappings) lists effective keys; [commands](/commands) lists
      built-in and installed plugin commands. [Plugins](/plugins) shows process
      health and capabilities, [runtime](/state) shows the current configuration
      and app state, and [logs](/logs) follows diagnostics as they happen.
      These describe this resident, including your changes.

      `?` in NORMAL opens mappings. `:help` opens the [homepage](/), which
      checks what this Mac has already set up and what is still missing.
      `:help <topic>` opens a guide, for example `:help widgets`.
      Plugin guides appear alongside built-in topics when their manifests load.

      Start with [troubleshooting](/docs/troubleshooting) when behavior differs
      from what you expect. [Privacy](/docs/privacy) explains permissions and
      stored data; [development](/docs/development) links the architecture and
      contributor references. The [manual](/docs/manual) is the complete
      reference, including comparisons with other tools.
      """,
    aliases: ["help"])

  private static let manualTopic = HelpTopic(
    name: "manual",
    title: "Manual",
    summary: "The complete reference, published from the repository's docs.",
    body: """
      # Manual

      These guides are the short version. The full manual is published at
      [\(manualRoot)](\(manual(""))) from the repository's `docs/` directory,
      so it describes the current `main`; your installation may be older.

      ## Using Flash

      - [Getting started](\(manual("getting-started"))), [configuration](\(manual("configuration"))) and the [commands](\(manual("commands"))) reference.
      - [Normal mode](\(manual("normal-mode"))), [flashlight](\(manual("flashlight"))), [windows](\(manual("windows"))) and [audio devices](\(manual("audio"))).
      - [Privacy](\(manual("privacy"))) and [troubleshooting](\(manual("troubleshooting"))).

      ## Status bar, widgets and popups

      - [Status format](\(manual("status-format"))), [status plugins](\(manual("status-plugins"))), [widgets](\(manual("widgets"))), [popups](\(manual("popups"))) and [calendar](\(manual("calendar"))).
      - Examples: [a status bar](\(manual("examples/statusbar"))) and [desktop widgets](\(manual("examples/widgets"))).

      ## Coming from another tool

      [Alternatives](\(manual("alternatives"))) compares Flash with Neru,
      Homerow, Shortcat, Scoot, Vimium, Hammerspoon, Raycast, SketchyBar,
      Übersicht, AeroSpace, yabai, Rectangle and others, one page each, with
      what they do better and how to move a setup over. Migration guides:
      [Hammerspoon](\(manual("hammerspoon"))), [Neverclick](\(manual("neverclick"))),
      [mousemaster](\(manual("mousemaster"))).

      ## Plugins and contributing

      - [Plugin cookbook](\(manual("plugin-cookbook"))), [protocol](\(manual("plugin-protocol"))), [Rust SDK](\(manual("plugin-rust-sdk"))) and [plugin performance](\(manual("plugin-performance"))).
      - [Development](\(manual("development"))), [releases](\(manual("release"))), [architecture](\(manual("architecture"))), [prepared model](\(manual("prepared-model"))), [observability](\(manual("observability"))) and [performance](\(manual("performance"))).
      """,
    aliases: ["docs", "reference", "alternatives"])

  private static let statusbarTopic = HelpTopic(
    name: "statusbar",
    title: "Status bar",
    summary: "Build a live strip with mode, app, metrics, links and popup tools.",
    body: """
      # Status bar

      Enable the bar independently of NORMAL mode. It occupies the top band
      of each selected display; macOS's menu bar auto-hides and remains
      available by reaching the top edge. Turning the Flash bar off restores
      the native setting when Flash was the one that changed it.

      ```toml
      [statusbar]
      enabled = true
      monitor = "all"
      template = "#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.active_app_name}#[align=right]#{flash.plugin.cpu.summary} · %H:%M"
      ```

      Use `monitor = "primary"` for only the primary display. The format can
      align content left, center or right, set colors and attributes, and
      include plugin values or your own command output. Center content yields
      to a physical camera notch.

      ## Turn a label into an action

      `#[link=URL]label#[nolink]` opens a URL. A named range binds an action:

      ```toml
      [statusbar]
      template = "#[range=user|search]Search#[norange]"

      [statusbar.click]
      search = ["flash", "enter_command_mode", "--input=:flashlight "]
      ```

      `#[popup=name]label#[nopopup]` connects a label to a [popup](/docs/popups).
      Plugin summaries may already carry links, actions and detail popups.
      Inspect [plugins](/plugins) to see which are available and healthy.

      Next: [format language](/docs/status-format), [desktop widgets](/docs/widgets),
      [status plugin values](\(HelpDocs.manual("status-plugins"))),
      and a [complete example](\(HelpDocs.manual("examples/statusbar"))).
      """,
    aliases: ["status-bar"])

  private static let statusFormatTopic = HelpTopic(
    name: "status-format",
    title: "Formats, sources & metrics",
    summary: "One tmux-style language for the bar, widgets and text popups.",
    body: """
      # Formats, sources & metrics

      Flash implements the tmux 3.7c format and style language for
      `statusbar.template`, widget templates and text popups. It does not
      need a running tmux server or import tmux configuration.

      | Syntax | Use |
      | --- | --- |
      | `#{flash.mode}` | Current mode |
      | `#{flash.active_app_name}` | Focused app |
      | `#{flash.plugin.cpu.percent}` | A plugin's declared status value |
      | `%H:%M` | Local time |
      | `#[fg=green,bold]OK#[default]` | Style a span |
      | `#[label]Cld#[default]` | Colour a name, then the ordinary foreground |
      | `#[align=right]text` | Place a section |
      | `#{?flash.secure_input,SECURE,}` | Conditional content |
      | `#[meter=12]42#[nometer]` | Numeric bar |
      | `#[spark]1 4 2 7 3#[nospark]` | Numeric history |
      | `#[shrink]#{flash.active_app_name}#[noshrink]` | Cut here first on overflow |

      Write `%%` for a literal percent in a template. Missing values expand
      to empty text. A plugin's numeric value is empty when unknown; do not
      assume that means zero. The status bar is one line; widgets and text
      popups preserve multiple lines. Time is never polled: `%H:%M` refreshes
      on the minute and `%S` every second, whatever `interval` says.

      ## Use your own command

      Native `#(command)` runs an asynchronous shell job. For explicit argv,
      a separate refresh cadence or numeric history, declare a named source:

      ```toml
      [statusbar.sources.load]
      command = ["/bin/sh", "-c", "sysctl -n vm.loadavg | awk '{print $2}'"]
      interval = 10
      history = 30

      [widgets.load]
      template = "Load #{flash.source.load} #[spark]#{flash.history.load}#[nospark]"
      ```

      Sources run only while an evaluated surface needs them. Shared references
      reuse the same source. `interval = 0` runs once; `cycle_interval` rotates
      output lines and cannot combine with `history`. Set `working_directory`
      for source-relative arguments. Failed or empty output keeps the last good value.

      See [runtime](/state) for effective settings, [plugins](/plugins) for
      status publishers, and the
      [full format reference](\(HelpDocs.manual("status-format")))
      for operators, escaping, layouts and source lifecycles.
      """,
    aliases: ["formats"])

  private static let widgetsTopic = HelpTopic(
    name: "widgets",
    title: "Desktop widgets",
    summary: "Put clocks, meters, histories and command output on your desktop.",
    body: #"""
      # Desktop widgets

      A widget draws a multiline [status format](/docs/status-format) above
      the wallpaper and below desktop icons and app windows. It never takes
      focus and clicks pass through it. Widgets work with the status bar off.

      ```toml
      [widgets.system]
      anchor = "top_right"
      screen = "primary"
      font_size = 16
      template = """
      CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer]
      MEM #[meter=20]#{flash.plugin.memory.percent}#[nometer]
      #{flash.plugin.processes.top_cpu}
      """
      ```

      Save to show it; set `enabled = false` or remove the table to hide it.
      Each `[widgets.<name>]` is independent. Choose an anchor and adjust
      `gap_x` / `gap_y` to place it. `screen` accepts `primary`, `all` or a
      display number counted left to right from 1. Widgets at the same anchor
      overlap, so give them different gaps.

      `fg`, `bg`, `border`, padding and font settings style the box. Alpha
      colors such as `#2E3440CC` make its background translucent. Within the
      template, each line has its own alignment; colors carry across lines.
      A multiline value such as `processes.top_cpu` expands into several rows.

      Widgets share plugin data, named sources and jobs with the status bar.
      Meters and sparklines work; links and popup markers have no action on
      this passive surface. Open [plugins](/plugins) if a metric is empty,
      or [runtime](/state) to inspect your loaded configuration.

      Browse [ready-made panels](\#(HelpDocs.manual("examples/widgets")))
      or the [widget reference](\#(HelpDocs.manual("widgets")))
      for all settings and a conky migration table.
      """#,
    aliases: ["widget"])

  private static let popupsTopic = HelpTopic(
    name: "popups",
    title: "Popups & terminal tools",
    summary: "Bring a pager, shell or your favorite TUI into a focused popup.",
    body: """
      # Popups & terminal tools

      Popups appear under status-bar labels or as standalone windows.
      Every popup runs in a real terminal. A text popup evaluates a
      [status format](/docs/status-format) and displays it in a pager;
      a terminal popup runs the argv you choose.

      ```toml
      [popup.date]
      text = "#{flash.calendar}"

      [popup.monitor]
      command = ["btop"]
      size = "90%x85%"
      persistent = true

      [mode.normal.mappings]
      "'b" = ["flash", "enter_terminal_mode", "--name=monitor"]
      ```

      Install and configure the tool yourself; Flash provides its popup,
      keyboard access and lifecycle. `enter_terminal_mode` with no name
      opens the built-in `terminal` popup, a fresh login shell by default.
      A `#[popup=monitor]CPU#[nopopup]` span exposes the same popup from the bar.

      ## Decide what survives closing

      `persistent = true` keeps one process and its terminal state while
      hidden, and restarts it after an exit. The default fresh lifecycle
      stops the process when dismissed. A fresh command that prints a report
      and exits leaves its output available to read. Command-R restarts
      the popup; for a text pager it refreshes the snapshot.

      Set exactly one of `text` or `command`. Terminal popups support `cwd`,
      `env` and `size` (cells or percentages); shared colors and padding live
      in `[popup]`. Use an explicit shell for pipelines. Editing presentation
      preserves a terminal process; changing its command or environment replaces it.

      If a command is missing, install it in your login PATH, then press
      Command-R. `flash doctor` reports missing popup commands. See
      [troubleshooting](/docs/troubleshooting), [live logs](/logs) and the
      [popup reference](\(HelpDocs.manual("popups")))
      for input, focus and lifecycle details.
      """,
    aliases: ["popup", "terminal"])

  private static let privacyTopic = HelpTopic(
    name: "privacy",
    title: "Privacy & permissions",
    summary: "Understand Accessibility, optional plugin permissions and local data.",
    body: """
      # Privacy & permissions

      Accessibility is the only permission needed for hints and clicks.
      Flash discovers controls through the Accessibility tree and window
      geometry. It does not read screen pixels, run OCR or record keys typed
      in other apps, and has no telemetry or analytics.

      ## Optional features have their own access

      Browser and Apple-app plugins may request Automation to list their
      data. The screenshot plugin invokes macOS `screencapture`, which needs
      Screen Recording when used. An explicit network refresh may request
      Location to read the Wi-Fi name. Your own calendar or other commands
      can request permissions too; macOS attributes child-process requests to Flash.

      Some plugins access the network: exchange rates, configured feeds,
      GitHub, AI-provider quotas or explicitly configured remote tmux hosts.
      Read their guides and the [privacy inventory](\(HelpDocs.manual("privacy")))
      for destinations, triggers and defaults. Disable an unwanted plugin
      with `[plugins] disabled = ["<id>"]`.

      ## Local storage and this browser

      Logs live in `~/Library/Logs/Flash/`. Command history, ranking data,
      plugin caches and clipboard history live in
      `~/Library/Application Support/Flash/`. Clipboard history keeps text,
      images, formatted copies, and file paths, and ignores items marked
      concealed, transient, or auto-generated. Flash's own
      submitted commands can appear in command history and diagnostic logs.

      This help server listens on loopback and starts when a browser command
      needs it (or at launch if configured). It exposes live state, logs and
      clipboard entries to local clients until Flash quits. The homepage
      remembers opened guides in that browser only; Flash does not receive
      the list. Other programs
      on your Mac can access it; it is not a remote monitoring service.
      Do not share a log or runtime export without reviewing its contents.

      Most plugins run with manifest-declared sandbox capabilities; some need
      unsandboxed helper access. Inspect [plugins](/plugins) and the privacy
      inventory for those boundaries. `flash doctor` checks permissions;
      [runtime](/state) shows the resident's current permission and input status.
      """,
    aliases: ["permissions"])

  private static let troubleshootingTopic = HelpTopic(
    name: "troubleshooting",
    title: "Troubleshooting",
    summary: "Diagnose missing hints, hotkeys, config errors and unhealthy plugins.",
    body: """
      # Troubleshooting

      Start with the resident's own diagnostics:

      ```sh
      flash doctor
      flash status --json
      flash config_check
      ```

      `doctor` checks permissions, input capture, configuration, hotkeys and
      plugin health. `status` describes the running instance.
      `config_check --file=/path/to/flash.toml` validates a file without
      requiring the resident. Compare them with [runtime](/state),
      [mappings](/mappings), [plugins](/plugins) and [logs](/logs).

      ## Hints do not appear or stopped after an update

      Verify Accessibility for the installed Flash app. Ad-hoc-signed builds
      can lose the effective grant after an update while the switch still
      looks enabled: remove Flash from Accessibility and add it again.
      Focus the app you intend to target and try `flash mouse_target`.
      Some controls have no Accessibility representation; use
      [mouse grid](/docs/mouse-grid) to reach their screen positions.
      No-target discovery intentionally shows no error overlay.

      ## A key types, does nothing or runs a different action

      Check the current mode and effective binding on [Mappings](/mappings).
      NORMAL captures unmapped keys; INSERT passes normal typing through.
      A mapping that prefixes a longer sequence waits for its timeout.
      macOS or another app may own a global shortcut. Secure input can hide
      keys from the event tap; `doctor` reports the holder when available.
      `[app] keyboard_layout` reads keypresses. `[keyboard] layout` is the
      logical layout for hints, the grid, bisect, and the ESDF positions
      HYPER uses as arrows. The right key is the home-row index-finger mark.

      ## A saved config change is missing

      Check the active config path and diagnostics on [Runtime](/state).
      That page shows the resolved configuration as JSON and edits the file.
      Save writes it after the text parses as TOML. Purge defaults removes
      assignments that equal the bundled file and leaves the result in the
      editor until you save. Values from the default configuration keep the
      base colour. A value your file or an environment variable overrode is
      marked with that layer (`config` and the filename, or `env` and the
      `FLASH_` variable).
      `FLASH_CONFIG` or `XDG_CONFIG_HOME` may select a different file.
      Invalid values are diagnosed and preserve the previous valid value
      according to the field's validation rule. Avoid duplicate TOML tables.
      See [configuration](/docs/config) for layering and path resolution.

      ## A plugin, metric or popup is unavailable

      Inspect its last error, state and capabilities on [Plugins](/plugins).
      Check required tools and permissions; a stopped on-demand plugin can
      be healthy. `:plugins reload` reloads all plugins. Empty numeric status
      values mean unknown or unavailable, rather than zero. Missing popup
      commands are checked against the login PATH; after installing one,
      Command-R rereads that environment and retries it.

      For slowness, filter [Logs](/logs) by source or trace and inspect hint
      timings in `flash status --json`. The
      [observability guide](\(HelpDocs.manual("observability")))
      explains traces and the
      [performance guide](\(HelpDocs.manual("performance")))
      describes repeatable measurements. Review [privacy](/docs/privacy)
      before sharing diagnostics.
      """,
    aliases: ["doctor", "diagnostics"])

  private static let developmentTopic = HelpTopic(
    name: "development",
    title: "Development & architecture",
    summary: "Build Flash, understand ownership, and extend it with plugins.",
    body: """
      # Development & architecture

      The `flash` executable is both the resident app and CLI. CLI commands
      arrive as local AppleEvents; native mappings dispatch the same verb
      definitions in process. The host owns discovery, overlays and committed
      mouse events. Plugins are managed children communicating through JSON
      lines on stdin/stdout.

      ## Build and run

      ```sh
      mise install
      mise exec -- ./Scripts/install.sh --dev
      ```

      Run from the repository. The installer builds, signs, installs and
      restarts `/Applications/Flash 🧪.app`. A standalone Swift build does
      not update the resident. Use the development installer for local work;
      release installation makes a clean universal build.

      ## Follow the maintained contracts

      - [Development](\(HelpDocs.manual("development"))): prerequisites and verification suites.
      - [Architecture](\(HelpDocs.manual("architecture"))): ownership, coordinates and deterministic hints.
      - [Prepared model](\(HelpDocs.manual("prepared-model"))): cache validity and refresh scheduling.
      - [Normal-mode internals](\(HelpDocs.manual("normal-mode"))): input routing, latency and mode transitions.
      - [Plugin cookbook](\(HelpDocs.manual("plugin-cookbook"))): build a small plugin.
      - [Protocol](\(HelpDocs.manual("plugin-protocol"))) and [Rust SDK](\(HelpDocs.manual("plugin-rust-sdk"))): wire contract and SDK examples.
      - [Plugin performance](\(HelpDocs.manual("plugin-performance"))): subprocess, scheduling and resource guidance.
      - [Contributor guide](\(HelpDocs.repositoryRoot)/AGENTS.md): repository constraints and required checks.

      ## Inspect the resident

      [Runtime](/state), [plugins](/plugins) and [logs](/logs) describe the
      installed process. The loopback server also exposes `/api/state`, `/api/logs`,
      `/api/traces` and the `/api/events` stream. `flash status` and `flash doctor`
      return local CLI diagnostics over the existing AppleEvent channel.
      Plugin help belongs in its manifest; built-in command documentation
      stays beside its definitions so help follows the installed feature set.
      """,
    aliases: ["architecture"])

  private static func index(_ topics: [HelpTopic]) -> String {
    var lines = [
      "# Flash Help",
      "",
      "Use `:help <topic>` to open one of these topics.",
      "",
    ]
    for topic in topics {
      let names = ([topic.name] + topic.aliases).map { "`\($0)`" }.joined(separator: ", ")
      lines.append("- \(names) - \(topic.summary)")
    }
    return lines.joined(separator: "\n")
  }

  private static func render(_ topic: HelpTopic) -> String {
    topic.body.trimmed
  }

  private static func unknownTopic(_ name: String, topics: [HelpTopic]) -> String {
    var lines = [
      "# Unknown Help Topic",
      "",
      "No help topic named `\(name)`.",
      "",
      "Available topics:",
      "",
    ]
    for topic in topics {
      lines.append("- `\(topic.name)`")
    }
    return lines.joined(separator: "\n")
  }

  private static func normalize(_ raw: String) -> String {
    raw.trimmed.lowercased()
  }
}
