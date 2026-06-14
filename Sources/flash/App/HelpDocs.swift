import Foundation

struct HelpTopic: Equatable {
  var name: String
  var title: String
  var summary: String
  var body: String
  /// Extra strings that resolve to this topic in `:help <topic>`.
  /// Use for singular/plural pairs (`mark` ↔ `marks`) or short forms.
  var aliases: [String] = []
}

enum HelpDocs {
  static func render(topic rawTopic: String?, config: Config, showModes: Bool) -> String {
    let topics = allTopics(config: config, showModes: showModes)
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

  static func allTopics(config: Config, showModes: Bool) -> [HelpTopic] {
    [
      overviewTopic,
      mappingsTopic,
      marksTopic,
      flashlightTopic,
      NormalModeDispatcher.helpTopic(config: config, showModes: showModes),
      URLEventHandler.helpTopic,
      Config.helpTopic,
      PluginManager.helpTopic,
    ].sorted { $0.name < $1.name }
  }

  static let mappingsTopic = HelpTopic(
    name: "mappings",
    title: "Mapping Syntax",
    summary: "How to spell keys and modifier chords in flash.toml.",
    body: """
      # Mapping Syntax

      Flash mapping keys are a sequence of "atoms" — each atom is one
      keystroke (a bare character, a named key, or a modifier chord).
      The single parser used by `[mode.*.mappings]` keys and the
      `[mode.normal] leader` value is
      `NormalModeInterpreter.parseKeySequence`.

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

  static let marksTopic = HelpTopic(
    name: "marks",
    title: "Marks",
    summary: "Vim-style marks: `m<letter>` to set, `` `<letter> `` to jump.",
    body: """
      # Marks

      Flash carries a Vim-style mark register. Each letter `a`-`z` holds
      one mark; setting a mark records the focused app's pid and bundle
      identifier so jumps survive process restarts (by falling back to
      the bundle).

      ## Setting a mark

      In normal mode, press `m` followed by a lowercase letter:

      ```text
      ma   # set mark `a` to the currently focused window
      mz   # set mark `z`
      ```

      ## Jumping to a mark

      Backtick + letter recalls the saved app. If the original pid is
      gone, Flash relaunches the app from its bundle identifier.

      ```text
      `a   # focus whatever was tagged `a`
      `z   # focus `z`
      ```

      ## URL form

      The same actions are reachable through the URL handler so external
      tools can drive them:

      ```text
      flash://set_mark?letter=a
      flash://jump_to_mark?letter=a
      ```

      ## Notes

      - 26 mark slots total — one per lowercase letter.
      - Marks persist for the lifetime of the Flash process; they are
        not written to disk yet.
      - Uppercase letters are reserved for future global/buffer marks.
      """,
    aliases: ["mark"])

  static let flashlightTopic = HelpTopic(
    name: "flashlight",
    title: "Flashlight",
    summary: "Fuzzy candidate finder across apps, tmux, browsers, plugins.",
    body: """
      # Flashlight

      Flashlight is the unified candidate finder. It surfaces apps,
      tmux windows, browser tabs, Slack channels, and plugin-provided
      candidates (contacts, notes, reminders, …) in one ranked list.

      ## Entry points

      - `flash://flashlight` URL.
      - `<leader><space>` in normal mode (default mapping).
      - `:flashlight <query>` in command-line mode.

      `:open <args>` is unrelated: it forwards verbatim to `/usr/bin/open`
      (URLs, files, `-a App`) with no finder smarts.

      ## Pinning a source

      Add `@<source>` (or `--<source>`) selectors *anywhere* in the query
      to restrict the pool, e.g. `:flashlight @notes inbox` searches only
      notes. Order is irrelevant — `@tmux @slack test` and
      `test @slack @tmux` are the same — and several selectors widen the
      pool (OR): `@tmux @slack` shows both. The token matches a source
      name (or prefix: `@fire` → firefox) and a few groups:
      `@browser`/`@tabs`, `@apps`. Bare `:flashlight @notes` lists every
      note. Typing an incomplete source token such as `@fire` shows source
      suggestions; `<tab>` or `<cr>` inserts the selected canonical source
      filter.

      Typing `!` shows registered bang suggestions. `<tab>` or `<cr>`
      inserts the selected bang token, and adding a space locks it for the
      remaining query.

      App and tmux-window rows are final destinations: `<tab>` or `<cr>`
      submits the selected row directly, the same as `<cmd-cr>`.

      ## Ranking

      Scoring layers, in order of weight:

      1. Exact primary-name match.
      2. Prefix match.
      3. Secondary metadata match (URL, tmux session/path, source labels).
      4. Fuzzy subsequence score.
      5. Source-precedence bonus — tmux windows rank above browser tabs,
         which rank above active apps, then inactive apps, then the rest
         (slack / notes / reminders / contacts).

      ## Plugin candidates

      Plugins keep candidate snapshots warm through host events such as
      `core:apps.snapshot`, `core:focus.changed`, and `core:ax.changed`.
      Flashlight asks them for a warm snapshot on open and only lets late
      responses appear after you type.
      """)

  private static let overviewTopic = HelpTopic(
    name: "overview",
    title: "Flash Help",
    summary: "How to read Flash help topics.",
    body: """
      # Flash Help

      `:help` opens the topic index.
      `:help <topic>` opens a specific topic, for example `:help plugins`.

      Help topics are Markdown text rendered in the Flash modal. The runtime
      docs are kept in Swift source files next to the feature code they
      describe, so command behavior and help text can change together.
      """)

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
