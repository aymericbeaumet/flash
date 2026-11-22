import AppKit
import FlashCore

/// Modes and the surfaces Flash draws: `mode`, `popup`, `alert`, `menu` and `status`.
extension URLEventHandler {
  static let modesCommands: [String: CommandDefinition] = [
    "mode visual": .init(
      "Select from the cursor in the focused text (VISUAL); --line selects whole lines; "
        + "again, leave it; --reselect selects the last VISUAL range again (gv)",
      [.flag("line"), .flag("reselect")],
      parse: { a in
        if a.bool("reselect") { return a.bool("line") ? nil : .visualReselect }
        return .visualMode(a.bool("line") ? .linewise : .charwise)
      }),
    "mode hold": .init(
      "Grab what is under the pointer (HOLD), or drop it", [.flag("secondary"), .flag("middle")],
      parse: { a in
        switch (a.bool("secondary"), a.bool("middle")) {
        case (false, false): return .holdMode(.primary)
        case (true, false): return .holdMode(.secondary)
        case (false, true): return .holdMode(.middle)
        case (true, true): return nil
        }
      }),
    "mode normal": .init(
      "Enter NORMAL mode", parse: { _ in .normalMode }),
    "mode leave": .init(
      "Leave the current mode: INSERT, a layer, the command line or a popup",
      parse: { a in a.args.isEmpty ? .leaveMode : nil }),
    "mode insert": .init(
      "Enter INSERT mode: keys go to the focused app", parse: { _ in .insertMode }),
    "mode layer": .init(
      "Enter a layer: its own keys act until Escape or mode leave",
      [.text("name", "layer", required: true)],
      parse: { a in
        guard a.args.keys.allSatisfy({ $0 == "name" }), let name = a.value("name"),
          Config.Mode.isValidLayerName(name)
        else { return nil }
        return .layerMode(name: name)
      }),
    "mode command": .init(
      "Open the command line, optionally pre-filled with --input",
      [.text("input", "text"), .flag("restore_mode")],
      parse: { a in
        guard let raw = a.value("input") else {
          return a.args.isEmpty ? .commandMode : nil
        }
        guard !raw.isEmpty else { return nil }
        // Strip every leading `:` and feed the rest through verbatim. A single
        // `:` is later prepended by `commandLineBuffer(from:)`. Trailing spaces
        // are meaningful and must NOT be trimmed: `--input=:flashlight ` opens
        // the flashlight with an empty query (all candidates) while
        // `--input=:flashlight` instead surfaces completions for commands that
        // start with `flashlight`. The user gets full control over which
        // behaviour they want.
        let normalized = String(raw.drop(while: { $0 == ":" }))
        // A flashlight query's `@<type>` must name a type, as in `mode
        // flashlight --query=`.
        if normalized.lowercased().hasPrefix("flashlight "),
          ResourceTypes.firstInvalidToken(in: normalized) != nil
        {
          return nil
        }
        return .enterCommand(input: normalized, restoreMode: a.bool("restore_mode"))
      }),
    "mode flashlight": .init(
      "Open the flashlight, optionally pre-filled with --query (a @type, a !bang or text)",
      [.text("query", "text"), .flag("restore_mode")],
      parse: { a in
        let query = a.value("query")
        if let query, query.trimmed.isEmpty { return nil }
        // `@<type>` must name a resource type (`ResourceTypes`); a dotted
        // source name from before types is rejected, with the type it meant.
        if let query, ResourceTypes.firstInvalidToken(in: query) != nil { return nil }
        return .flashlight(query: query?.trimmed, restoreMode: a.bool("restore_mode"))
      }),
    "mode terminal": .init(
      "Show and focus a popup; without --name, the terminal popup", [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }),
          args.value("name").map({ !$0.trimmed.isEmpty }) ?? true
        else { return nil }
        return .terminalMode(name: args.value("name"))
      }),
    "popup restart": .init(
      "Restart the focused or named popup's process", [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }), args.value("name") != "" else {
          return nil
        }
        return .popupRestart(name: args.value("name"))
      }),
    "popup quit": .init(
      "Quit the focused or named popup's process; persistent popups restart",
      [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }), args.value("name") != "" else {
          return nil
        }
        return .popupQuit(name: args.value("name"))
      }),
    "alert show": .init(
      "Show a message in the centred alert",
      [
        .text("message", "text", required: true), .text("duration", "seconds"),
        .text("style", "standard|warning|error"),
      ], parse: { alertCommand($0) }),
    "alert dismiss": .init(
      "Dismiss the alert", parse: { _ in .dismissAlert }),
    "alert confirm": .init(
      "Ask first, then run the wrapped command on y",
      [
        .text("prompt", "question", required: true),
        .text("command", "topic action [--arg=value ...]", required: true),
      ], parse: { confirmCommand($0) }),
    "status set": .init(
      "Push a value into a [statusbar.sources] source from a script or hook",
      [.text("name", "source", required: true), .text("value", "text", required: true)],
      parse: { a in
        guard let name = a.value("name"), let value = a.value("value") else { return nil }
        return .statusPush(StatusPush(source: name, value: value))
      }),
    "status clear": .init(
      "Clear the value pushed into a [statusbar.sources] source",
      [.text("name", "source", required: true)],
      parse: { a in a.value("name").map { .statusPush(StatusPush(source: $0, value: nil)) } }),
    "menu choose": .init(
      "Pick a line of --file in the flashlight and answer with it; for scripts, like dmenu",
      [.text("file", "path", required: true), .text("prompt", "label")],
      parse: { a in
        guard let file = a.value("file"), !file.isEmpty else { return nil }
        let prompt = a.value("prompt")
        guard prompt.map(MenuChoice.validPrompt) ?? true else { return nil }
        return .menuChoose(file: file, prompt: prompt)
      }),
    "menu press": .init(
      "Press a menu-bar item of the focused app by its titles, comma-separated",
      [.text("path", "Menu,Item,...", required: true)],
      parse: { a in a.value("path").flatMap(menuPath).map { .menuPress(path: $0) } }),
    "status refresh": .init(
      "Run a [statusbar.sources] source's command now instead of at its interval",
      [.text("name", "source", required: true)],
      parse: { a in a.value("name").map { .statusRefresh(source: $0) } }),
  ]

  static func alertCommand(_ a: CommandArgs) -> URLCommand? {
    guard let message = a.value("message"), !message.isEmpty else { return nil }

    let duration: TimeInterval?
    if let rawDuration = a.value("duration") {
      guard
        let parsed = TimeInterval(rawDuration),
        parsed.isFinite,
        parsed > 0
      else {
        return nil
      }
      duration = parsed
    } else {
      duration = nil
    }

    let styleRaw = a.value("style") ?? StatusAlert.Style.standard.rawValue
    guard let style = StatusAlert.Style(rawValue: styleRaw) else { return nil }
    return .showAlert(AlertCommand(message: message, duration: duration, style: style))
  }

  /// `--command` holds the wrapped command line as the words after `flash` in a
  /// mapping: `tab close`, `tab select --index=2`, `screenshot window`. The
  /// words are split on spaces, so an argument value cannot contain one.
  static func confirmCommand(_ a: CommandArgs) -> URLCommand? {
    guard let prompt = a.value("prompt")?.trimmed, !prompt.isEmpty,
      let line = a.value("command")
    else { return nil }
    let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard !words.isEmpty,
      case .flashCommand(let command)? = parseMappingCommand(argv: ["flash"] + words)
    else { return nil }
    if case .confirm = command { return nil }
    return .confirm(ConfirmCommand(prompt: prompt, command: command))
  }

  /// `menu press --path=`: the menu's title, then each nested item's,
  /// comma-separated and trimmed; at least two, none blank. A title holding a
  /// comma cannot be named.
  static func menuPath(_ raw: String) -> [String]? {
    let titles = raw.split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard titles.count >= 2, !titles.contains(where: \.isEmpty) else { return nil }
    return titles
  }
}
