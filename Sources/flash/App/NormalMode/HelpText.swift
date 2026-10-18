import Foundation

/// Help-modal text rendering for the normal-mode interpreter. Includes
/// the per-topic `helpTopic` / `helpText`, the keymap-listing modal
/// (`mappingsText`), and the row helpers that back them.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeDispatcher {
  private struct MappingRow {
    var scope: String
    var key: String
    var action: String
    var origin: String
    var explanation: String
  }

  static func helpTopic(config: Config, showModes: Bool) -> HelpTopic {
    HelpTopic(
      name: "normal-mode",
      title: "Normal Mode",
      summary: "Normal-mode mappings, counts, command line, and mouse targeting.",
      body: """
        # Normal Mode

        Normal mode captures keyboard input through Flash's sanctioned session
        tap, with the overlay panel as its no-permission fallback. Configured
        modified mappings use Carbon hotkeys. Unmapped keys and chords are
        swallowed; only explicit mappings act.

        ## Core Motion

        - `h` / `l` scroll left/right.
        - `ctrl-e` / `ctrl-y` wheel down/up by `mode.scroll_step_lines` (default 3).
        - `ctrl-d` / `ctrl-u` wheel down/up by `mode.scroll_page_lines` (default 20).
        - Vertical wheel events act at the mouse cursor in every app, including terminals.
          `mode.scroll_smooth_ms` spreads each step over that many milliseconds.
        - `gg` scrolls to the top.
        - `G` scrolls to the bottom.
        - Counts prefix actions: `10u`, `2[a`, and similar forms repeat the action.

        ## Editing And Navigation

        Keys map to high-level actions that resolve in the focused app: tmux
        windows inside tmux, browser tabs, native tabs, and nothing where the
        app lacks the action. No default sends a raw key chord.

        - `u` undoes; `ctrl-r` redoes.
        - `y` copies the selection; `p` pastes.
        - `/` opens Find and enters INSERT; `x` closes the current tab and `X`
          reopens the last closed one.
        - `[a` / `]a` cycles previous/next app in MRU order; keep pressing `a`
          to repeat (`[aaaa` / `]aaaa`). Quitting the focused app focuses
          that previous app.
        - `[t` / `]t` switch to the previous/next tab; keep pressing `t` to
          repeat while staying in NORMAL.
        - `t` opens a tab and enters INSERT; `g1`–`g9` select one and NORMAL
          stays.
        - `r` reloads and `R` hard-reloads where the app has a reload
          (browsers, tmux).
        - `ctrl-o` / `ctrl-i` traverse Flash's movement history.
        - `H` / `L` go back/forward in the app (Cmd-[ / Cmd-], or the app's
          own chord; nothing in terminals and apps without history).
        - Bare `c`, `d`, `m`, `j`, and `k` are unbound. `c`, `d` and `m`
          wait for a mouse finisher. Other tab, pane, archive, find-match,
          URL-copy and mark shortcuts are opt-in.

        ## Mouse Targets

        A mouse action is a prefix and a finisher. Prefixes: none, `m` move,
        `d` double, `c` context (right-click). Finishers: `f` a target, `F`
        the grid, `s` a visible letter. `c` is free in Vim and Vimium; `r`
        reloads and `s` is the search finisher.

        - `f` clicks a discovered target (plain click; terminal links add Shift).
        - `F` starts the mouse grid and clicks a precise screen position.
        - `s`, then one letter, then the two-character hint clicks that letter
          in the focused window (`mouse_bigram`). The pointer lands one point
          left of the letter's centre. `cs` right-clicks it,
          `ds` double-clicks it, and `ms` moves the pointer onto it. `s`
          starts no other mapping, so the jump fires at once. `v` and `V`
          match the same glyphs, and so do a key and its shifted symbol
          (`3` and `#`), in the
          focused window and on the status bar. A textless terminal also matches
          the tmux status line and pane titles. Backspace edits, Escape cancels,
          and no match stays silent.
        - `cf` / `cF` right-click a target or a grid position.
        - `df` / `dF` double-click a target or a grid position.
        - `mf` / `mF` move the cursor to a target or a grid position.
        - A click leaves the pointer on its target; `hints.restore_pointer`
          puts it back after every committed click, drag or selection.
        - `mouse_dock`, `mouse_menubar` (the app's menu titles and the status
          items) and `mouse_notifications` hint surfaces outside the window;
          bind them to use them.
        - `enter_drag_mode` (unmapped by default; `--secondary` for the right
          button) grabs what is under the pointer (DRAG): `h` `j` `k` `l`
          nudge it; `w` `b` `e` `0` `$` jump by text, `f` `F` `s` pick where
          it goes. `y` copies text and clears the selection; `d` / `x` cut,
          `c` changes, and `p` pastes over it. Return drops; Escape puts it back.

        ## Mouse Grid

        The screen splits like the left half of your keyboard: 4 rows × 5
        keys of the `hints.keys` layout (`12345` / `qwert` / `asdfg` / `zxcvb`
        on QWERTY). Press the key where you want to go, then again inside that
        cell; the last step clicks.

        - `space` zooms into the centre; `return` clicks the centre now.
        - `backspace` undoes the last grid key; `cmd-backspace` or
          `alt-backspace` starts over.
        - Arrows slide the region by its own size.
        - `tab` / `shift-tab` move to the next / previous display.
        - `` ` `` toggles cursor-follow; `escape` cancels.
        - `mouse_grid --bisect` keeps a half with the keys at the QWERTY
          `h`/`j`/`k`/`l` positions of `[keyboard] layout`, or a quadrant
          with the keys at `y`/`u` and `b`/`n`. Bépo's top-left quadrant is
          the dead key `^`.
        - Modifiers held on the final hint key ride the click, so `f` then
          Command-Shift-`<hint>` is a Command-Shift click with no binding of its own.
        - Triple click ships unbound: `tf` would stall the bare `t`. Bind it yourself.

        ## Command Line

        The command line has no default shortcut. Run
        `flash enter_command_mode` from a terminal, or bind `:` in
        `[mode.normal.mappings]` to `["flash", "enter_command_mode"]`.
        Use `:help` for
        the browser help homepage, `:help plugins` for plugin docs, and
        `?` or `:mappings` for the live mapping reference.
        `:flashlight <query>` searches source candidates;
        `:open <args>` forwards verbatim to `open` (URLs, files, `-a App`).

        ## Configured mappings

        These are the base mappings from your configuration. The [live mapping
        reference](/mappings) includes plugin overrides for the focused app.

        ```text
        \(helpText(config: config, showModes: showModes))
        ```
        """)
  }

  static func helpText(config: Config, showModes: Bool) -> String {
    let normal = groupedKeys(config.mode.mappings(for: .normal))
    let insert = groupedKeys(config.mode.mappings(for: .insert))
    let terminal = groupedKeys(config.mode.effectiveTerminalMappings)
    let commands = Array(Set(normal.keys).union(insert.keys).union(terminal.keys))
      .sorted { lhs, rhs in
        lhs.diagnosticDescription.localizedCaseInsensitiveCompare(rhs.diagnosticDescription)
          == .orderedAscending
      }
    let rows = commands.map { command -> (String, String, String, String) in
      (
        command.diagnosticDescription,
        joined(normal[command] ?? []),
        joined(insert[command] ?? []),
        joined(terminal[command] ?? [])
      )
    }

    let actionWidth = max("ACTION".count, rows.map(\.0.count).max() ?? 0)
    let normalWidth = max("NORMAL".count, rows.map(\.1.count).max() ?? 0)
    let insertWidth = max("INSERT".count, rows.map(\.2.count).max() ?? 0)
    let commandLineVisible =
      !(normal[.flashCommand(.commandMode)] ?? []).isEmpty
      || !(insert[.flashCommand(.commandMode)] ?? []).isEmpty
    var lines: [String] = []
    if !showModes {
      let mappingWidth = max("MAPPING".count, rows.map(\.1.count).max() ?? 0)
      lines.append(
        padded("ACTION", width: actionWidth)
          + "  " + padded("MAPPING", width: mappingWidth))
      for row in rows where !row.1.isEmpty {
        lines.append(
          padded(row.0, width: actionWidth)
            + "  " + padded(row.1, width: mappingWidth))
      }
      lines.append("")
      lines.append("Counts: N{mapping}, e.g. 10u or 3]t")
      appendCommandLineHelp(to: &lines, visible: commandLineVisible)
      return lines.joined(separator: "\n")
    }

    if showModes {
      lines.append("MAPPINGS")
      lines.append("")
    }
    lines.append(
      padded("ACTION", width: actionWidth)
        + "  " + padded("NORMAL", width: normalWidth)
        + "  " + padded("INSERT", width: insertWidth) + "  TERMINAL")
    for row in rows where !row.1.isEmpty || !row.2.isEmpty || showModes {
      lines.append(
        padded(row.0, width: actionWidth)
          + "  " + padded(row.1, width: normalWidth)
          + "  " + padded(row.2, width: insertWidth) + "  " + row.3)
    }
    lines.append("")
    lines.append("Counts: N{mapping}, e.g. 10u or 3]t")
    appendCommandLineHelp(to: &lines, visible: commandLineVisible)
    return lines.joined(separator: "\n")
  }

  static func mappingsText(config: Config) -> String {
    let rows =
      mappingRows(scope: "all", mappings: config.mode.all)
      + mappingRows(scope: "normal", mappings: config.mode.normal)
      + mappingRows(scope: "hyper", mappings: config.mode.hyper)
      + mappingRows(scope: "insert", mappings: config.mode.insert)
      + mappingRows(scope: "terminal", mappings: config.mode.effectiveTerminalMappings)
      + mappingRows(scope: "command", mappings: config.mode.command)
    let scopeWidth = max("SCOPE".count, rows.map(\.scope.count).max() ?? 0)
    let keyWidth = max("KEY".count, rows.map(\.key.count).max() ?? 0)
    let originWidth = max("FROM".count, rows.map(\.origin.count).max() ?? 0)
    var lines = [
      "# Mappings",
      "",
      "Normal leader: `\(config.mode.normalLeader ?? "<unset>")`",
      "",
      "FROM is `default` for a built-in, `config` or `config:<file>` for your configuration, or `plugin:<name>`.",
      "",
    ]
    guard !rows.isEmpty else {
      lines.append("No mappings are configured.")
      return lines.joined(separator: "\n")
    }
    lines.append("```text")
    lines.append(
      padded("SCOPE", width: scopeWidth)
        + "  " + padded("KEY", width: keyWidth)
        + "  " + padded("FROM", width: originWidth)
        + "  ACTION")
    for row in rows {
      lines.append(
        padded(row.scope, width: scopeWidth)
          + "  " + padded(row.key, width: keyWidth)
          + "  " + padded(row.origin, width: originWidth)
          + "  " + row.action)
    }
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  /// The configured mappings as structured rows for the inspector's Mappings
  /// tab — the same scope data `mappingsText` renders, minus Markdown formatting.
  static func mappingsJSON(mode: Config.Mode) -> [[String: String]] {
    (mappingRows(scope: "all", mappings: Config.Mode.resolveMappings(mode.all))
      + mappingRows(scope: "normal", mappings: Config.Mode.resolveMappings(mode.normal))
      + mappingRows(scope: "drag", mappings: Config.Mode.resolveMappings(mode.drag))
      + mappingRows(scope: "hyper", mappings: Config.Mode.resolveMappings(mode.hyper))
      + mappingRows(scope: "insert", mappings: Config.Mode.resolveMappings(mode.insert))
      + mappingRows(scope: "terminal", mappings: mode.effectiveTerminalMappings)
      + mappingRows(scope: "command", mappings: Config.Mode.resolveMappings(mode.command)))
      .map {
        [
          "scope": $0.scope, "key": $0.key, "action": $0.action, "origin": $0.origin,
          "explanation": $0.explanation,
        ]
      }
  }

  private static func mappingRows(scope: String, mappings: [ModeMapping]) -> [MappingRow] {
    mappings.map { mapping in
      MappingRow(
        scope: scope,
        key: displayMappingKey(mapping.key),
        action: mapping.action.diagnosticDescription,
        origin: mapping.origin,
        explanation: mapping.action.explanation
      )
    }
  }

  private static func displayMappingKey(_ key: String) -> String {
    if key.contains(NormalModeInterpreter.keyAtomSeparator) {
      return displayAtoms(key).joined()
    }
    if let chord = displayModifierChord(key) { return chord }
    return displayAtoms(key).joined()
  }

  private static func displayModifierChord(_ key: String) -> String? {
    let tokens = key.split(separator: "+", omittingEmptySubsequences: false)
    if tokens.count >= 2,
      tokens.dropLast().allSatisfy({ isModifierToken(String($0)) })
    {
      let modifiers = tokens.dropLast().map(String.init).joined(separator: "+")
      let key = displaySingleAtom(String(tokens.last ?? ""))
      return modifiers + "+" + key
    }
    if key.hasPrefix("ctrl-") {
      let suffix = String(key.dropFirst("ctrl-".count))
      return "ctrl-" + displaySingleAtom(suffix)
    }
    return nil
  }

  private static func isModifierToken(_ token: String) -> Bool {
    ["cmd", "command", "ctrl", "control", "shift", "alt", "opt", "option"]
      .contains(token.lowercased())
  }

  private static func displaySingleAtom(_ raw: String) -> String {
    if displayNamedKeyTokens.contains(raw) {
      return "<\(raw)>"
    }
    if raw.count == 1, let ch = raw.first,
      let fullName = NormalModeInterpreter.fullName(forCharacter: ch),
      ["+", "<", ">"].contains(ch)
    {
      return "<\(fullName)>"
    }
    return raw
  }

  private static func displayAtoms(_ key: String) -> [String] {
    if key.contains(NormalModeInterpreter.keyAtomSeparator) {
      return NormalModeInterpreter.keyAtoms(from: key).map(displaySingleAtom)
    }
    var atoms: [String] = []
    var index = key.startIndex
    while index < key.endIndex {
      if let named = displayNamedKeyTokens.first(where: { token in
        key[index...].hasPrefix(token)
      }) {
        atoms.append(displaySingleAtom(named))
        index = key.index(index, offsetBy: named.count)
        continue
      }
      atoms.append(displaySingleAtom(String(key[index])))
      index = key.index(after: index)
    }
    return atoms
  }

  private static let displayNamedKeyTokens = [
    "delete_forward",
    "forward_delete",
    "backspace",
    "pagedown",
    "pageup",
    "delete",
    "escape",
    "return",
    "enter",
    "space",
    "right",
    "down",
    "left",
    "home",
    "end",
    "tab",
    "esc",
    "up",
  ]

  private static func appendCommandLineHelp(to lines: inout [String], visible: Bool) {
    guard visible else { return }
    lines.append("")
    lines.append("COMMANDS")
    for line in commandLineHelpLines {
      lines.append(line)
    }
    lines.append("Command mode exits with the leave_mode mapping, Esc, ctrl-c, or empty backspace.")
  }

  private static var commandLineHelpLines: [String] {
    var lines = commandLineSpecs.map { $0.helpLine }
    lines.append(contentsOf: popupCommandSyntax.values.sorted())
    lines.append(":help [topic]")
    lines.append(":open <args>")
    lines.append(":flashlight <query>")
    lines.append(":plugins / :plugins reload")
    return lines
  }

  private static func groupedKeys(_ mappings: [ModeMapping]) -> [MappingCommand: [String]] {
    var grouped: [MappingCommand: [String]] = [:]
    for mapping in mappings {
      grouped[mapping.action, default: []].append(displayMappingKey(mapping.key))
    }
    return grouped
  }

  private static func joined(_ keys: [String]) -> String {
    keys.joined(separator: ", ")
  }

  private static func padded(_ value: String, width: Int) -> String {
    value + String(repeating: " ", count: max(0, width - value.count))
  }
}
