import Foundation
import FlashCore

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
  }

  static func helpTopic(config: Config, showModes: Bool) -> HelpTopic {
    HelpTopic(
      name: "normal-mode",
      title: "Normal Mode",
      summary: "Normal-mode mappings, counts, command line, and mouse targeting.",
      body: """
        # Normal Mode

        Normal mode captures keyboard input through the Flash overlay panel. It
        does not install arbitrary global key capture; only configured modified
        mappings use Carbon hotkeys.

        ## Core Motion

        - `h` / `j` / `k` / `l` scroll left, down, up, and right.
        - `ctrl-d` / `ctrl-u` scroll by half a page.
        - `gg` scrolls to the top.
        - `G` scrolls to the bottom.
        - Counts prefix actions: `10u`, `2[t`, and similar forms repeat the action.

        ## Tabs And Windows

        - `[t` / `]t` moves to the previous or next tab.
        - `[h` / `]h` walks the focused target's page history.
        - `[a` / `]a` cycles previous/next app in MRU order.
        - `g1` ... `g9` select a numbered tab when the focused source supports it.
        - In browsers this maps to tab selection.
        - `n` opens a new window with Cmd-N.
        - `t` opens a new tab and then enters insert mode.

        ## Mouse Targets

        - `f` targets clickable elements discovered from the focused app, then enters insert mode.
        - `rf` right-clicks a discovered target, then enters insert mode.
        - `df` double-clicks a discovered target, then enters insert mode.
        - `mf` moves the cursor to a discovered target.
        - `F` starts mouse grid mode for a precise screen position, then enters insert mode after the click.
        - `rF` / `dF` right-click or double-click with mouse grid mode, then enter insert mode.
        - `mF` moves the cursor with mouse grid mode.

        ## Command Line

        `:` opens command-line mode. Use `:help` for the topic index,
        `:help plugins` for plugin docs, and `:mappings` for the resolved
        mapping table. `:flashlight <query>` searches source candidates;
        `:open <args>` forwards verbatim to `open` (URLs, files, `-a App`).

        ## Active Mappings

        ```text
        \(helpText(config: config, showModes: showModes))
        ```
        """)
  }

  static func helpText(config: Config, showModes: Bool) -> String {
    let normal = groupedKeys(config.mode.mappings(for: .normal))
    let insert = groupedKeys(config.mode.mappings(for: .insert))
    let commands = Array(Set(normal.keys).union(insert.keys))
      .sorted { lhs, rhs in
        lhs.diagnosticDescription.localizedCaseInsensitiveCompare(rhs.diagnosticDescription)
          == .orderedAscending
      }
    let rows = commands.map { command -> (String, String, String) in
      (
        command.diagnosticDescription,
        joined(normal[command] ?? []),
        joined(insert[command] ?? [])
      )
    }

    let actionWidth = max("ACTION".count, rows.map(\.0.count).max() ?? 0)
    let normalWidth = max("NORMAL".count, rows.map(\.1.count).max() ?? 0)
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
        + "  INSERT")
    for row in rows where !row.1.isEmpty || !row.2.isEmpty || showModes {
      lines.append(
        padded(row.0, width: actionWidth)
          + "  " + padded(row.1, width: normalWidth)
          + "  " + row.2)
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
      + mappingRows(scope: "insert", mappings: config.mode.insert)
    let scopeWidth = max("SCOPE".count, rows.map(\.scope.count).max() ?? 0)
    let keyWidth = max("KEY".count, rows.map(\.key.count).max() ?? 0)
    var lines = [
      "# Mappings",
      "",
      "Normal leader: `\(config.mode.normalLeader ?? "<unset>")`",
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
        + "  ACTION")
    for row in rows {
      lines.append(
        padded(row.scope, width: scopeWidth)
          + "  " + padded(row.key, width: keyWidth)
          + "  " + row.action)
    }
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  private static func mappingRows(scope: String, mappings: [ModeMapping]) -> [MappingRow] {
    mappings.map { mapping in
      MappingRow(
        scope: scope,
        key: mapping.key,
        action: mapping.action.diagnosticDescription
      )
    }
  }

  private static func appendCommandLineHelp(to lines: inout [String], visible: Bool) {
    guard visible else { return }
    lines.append("")
    lines.append("COMMANDS")
    for line in commandLineHelpLines {
      lines.append(line)
    }
    lines.append("Command mode exits with Esc, ctrl-c, or empty backspace.")
  }

  private static var commandLineHelpLines: [String] {
    var lines = commandLineSpecs.map { $0.helpLine }
    lines.append(":help [topic]")
    lines.append(":open <args>")
    lines.append(":flashlight <query>")
    lines.append(":plugins list / :plugins ls / :plugins reload")
    return lines
  }

  private static func groupedKeys(_ mappings: [ModeMapping]) -> [MappingCommand: [String]] {
    var grouped: [MappingCommand: [String]] = [:]
    for mapping in mappings {
      grouped[mapping.action, default: []].append(mapping.key)
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
