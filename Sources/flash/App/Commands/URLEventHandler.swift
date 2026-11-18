import AppKit
import FlashCore

// Flash's command table. Every command is `flash <topic> <action>
// [--name=value ...]`: the words a terminal sends the resident over its
// socket (`IPCServer`), a mapping names (`"f" = ["flash", "mouse",
// "target"]`, parsed at load time through `URLEventHandler.parse(words:)`)
// and the command line resolves, so every entry point shares one source of
// truth.

/// The command table and the names, topics and suggestions derived from it.
enum URLEventHandler {
  static func rejectionMessage(_ invocation: String) -> String {
    var words = invocation.split(separator: " ").map(String.init)
    if let first = words.first, first == "flash" || first.hasSuffix("/flash") {
      words.removeFirst()
    }
    // An argument's `@<type>` that names no type: say which type it meant.
    let values = words.map { $0.split(separator: "=", maxSplits: 1).last.map(String.init) ?? $0 }
    let typeHint = ResourceTypes.firstInvalidToken(in: values.joined(separator: " ")).map {
      " " + ResourceTypes.invalidTokenMessage($0)
    }
    let hint =
      typeHint
      ?? suggestionPhrase(suggestedCommands(for: words)).map { " Did you mean \($0)?" } ?? ""
    return
      "Unsupported command or invalid arguments: \(invocation).\(hint) Check the command and its "
      + "configuration or mapping."
  }

  /// The commands `words` most likely mean when they name none: those whose
  /// every word appears in what was typed (`enter_insert_mode` is `mode
  /// insert`), the most specific first; failing that, those containing every
  /// typed word (`quit`), shortest first. At most three. Snake case splits
  /// into words and a plural `s` folds on both sides. Only a suggestion:
  /// nothing runs under the typed name.
  static func suggestedCommands(for words: [String]) -> [String] {
    let typed = words.filter { !$0.hasPrefix("-") }
    guard !typed.isEmpty else { return [] }
    if typed.count >= 2, commands[typed.prefix(2).joined(separator: " ")] != nil { return [] }
    let typedWords = suggestionWords(typed.joined(separator: "_"))
    guard !typedWords.isEmpty else { return [] }
    let names = commandNames.map(\.description)
    var named: [String] = []
    var specificity = 0
    for name in names {
      let words = suggestionWords(name)
      guard words.allSatisfy(typedWords.contains) else { continue }
      if words.count > specificity {
        named = [name]
        specificity = words.count
      } else if words.count == specificity {
        named.append(name)
      }
    }
    if !named.isEmpty { return Array(named.sorted().prefix(3)) }
    let containing = names.filter { Set(typedWords).isSubset(of: Set(suggestionWords($0))) }
    return Array(
      containing.sorted { (suggestionWords($0).count, $0) < (suggestionWords($1).count, $1) }
        .prefix(3))
  }

  private static func suggestionWords(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " }).map { word in
      word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
    }
  }

  /// `` `a` ``, `` `a` or `b` `` or `` `a`, `b` or `c` ``; nil for none.
  static func suggestionPhrase(_ names: [String]) -> String? {
    let quoted = names.map { "`\($0)`" }
    guard let last = quoted.last else { return nil }
    guard quoted.count > 1 else { return last }
    return quoted.dropLast().joined(separator: ", ") + " or " + last
  }

  /// Every Flash command, sorted: `flash <topic> <action>`.
  static let commandNames: [CommandName] = commands.keys.compactMap(CommandName.init).sorted()

  /// The topics Flash owns: every command's, and the queries'. A plugin
  /// command name is never one of them.
  static let topics: Set<String> = Set(
    commandNames.map(\.topic) + FlashQuery.allCases.map(\.name.topic))

  /// Whether `word` is one of Flash's topics.
  static func isTopic(_ word: String) -> Bool {
    topics.contains(word)
  }

  /// The commands of `topic`, sorted by action.
  static func commandNames(of topic: String) -> [CommandName] {
    commandNames.filter { $0.topic == topic }
  }

  /// The commands that ask the focused app for something: every table
  /// command whose bare form is a source command (``URLCommand/sourceCommand``).
  /// A plugin performs one by declaring it in `commands[]`; `bindings`
  /// declare what an app does for one.
  static let sourceCommandNames: Set<CommandName> = Set(
    commandNames.filter { name in
      commands[name.description]?.command(arguments: [:])?.sourceCommand != nil
    })

  /// Every key a manifest `bindings` entry may use, sorted: each source
  /// command's bare key, plus each bool-flag variant that still yields a
  /// source command (`app reload --force`).
  static let sourceCommandBindingKeys: [CommandBindingKey] = {
    var keys = Set<CommandBindingKey>()
    for name in sourceCommandNames {
      guard let definition = commands[name.description] else { continue }
      keys.insert(CommandBindingKey(name))
      for parameter in definition.parameters {
        guard case .flag = parameter.kind,
          let command = definition.command(arguments: [parameter.name: "1"])?.sourceCommand
        else { continue }
        keys.insert(CommandBindingKey(command))
      }
    }
    return keys.sorted()
  }()

  /// The parameters of `name`, or nil for a command the table does not have.
  static func commandParameters(of name: CommandName) -> [CommandParameter]? {
    commands[name.description]?.parameters
  }

  /// Resolve `flash <topic> <action>` with its `--name=value` arguments.
  /// Nil for an unknown command or arguments it does not accept.
  ///
  /// Plugin commands are not in this table. They are
  /// `flash <command> <subcommand>`, parsed by ``PluginGitInvocation``.
  static func parse(topic: String, action: String, args: [String: String]) -> URLCommand? {
    commands["\(topic) \(action)"]?.command(arguments: args)
  }

  /// Resolve the words after `flash`: `<topic> <action> [--name=value ...]`.
  static func parse(words: [String]) -> URLCommand? {
    guard words.count >= 2, let args = try? CommandArguments.parse(words.dropFirst(2)) else {
      return nil
    }
    return parse(topic: words[0], action: words[1], args: args)
  }

  /// The command table's raw keys, so a test can hold every one to the
  /// `<topic> <action>` shape.
  static var commandTableKeys: [String] { Array(commands.keys) }

  /// The one-line description of a command, for the catalog and completion.
  static func summary(of name: CommandName) -> String? {
    commands[name.description]?.summary
  }

  /// `cursor <motion>`, which takes no arguments.
  private static func cursorMotion(_ motion: TextMotion, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .cursor(.motion(motion)) : nil })
  }

  /// `cursor next_char|…`: the character from `--char`, else the next key.
  private static func characterSearch(_ kind: CharacterSearchKind) -> CommandDefinition {
    .init(
      kind.summary + "; without --char, the next key typed", [.text("char", "c")],
      parse: { a in
        guard a.args.keys.allSatisfy({ $0 == "char" }) else { return nil }
        guard let raw = a.value("char") else { return .cursor(.findCharacter(kind, nil)) }
        guard raw.count == 1, let character = raw.first else { return nil }
        return .cursor(.findCharacter(kind, character))
      })
  }

  /// The `cursor` commands: one per Vim motion, a line by number or
  /// percentage, and the character searches.
  private static let cursorCommands: [String: CommandDefinition] = {
    var table: [String: CommandDefinition] = [:]
    for (action, motion) in CursorCommand.motionActions {
      table["cursor \(action)"] = cursorMotion(
        motion, CursorCommand.motionSummaries[action] ?? action)
    }
    for kind in CharacterSearchKind.allCases {
      table["cursor \(kind.rawValue)"] = characterSearch(kind)
    }
    table["cursor repeat_char"] = .init(
      "Repeat the last character search on the line (;)",
      parse: { a in a.args.isEmpty ? .cursor(.repeatCharacterSearch(reversed: false)) : nil })
    table["cursor repeat_char_back"] = .init(
      "Repeat the last character search the other way (,)",
      parse: { a in a.args.isEmpty ? .cursor(.repeatCharacterSearch(reversed: true)) : nil })
    table["cursor line"] = .init(
      "Move to line --index, or --percent of the way through the text ({count}G, {count}%)",
      [.integer("index"), .integer("percent")],
      parse: { a in
        switch (a.int("index"), a.int("percent")) {
        case (let index?, nil) where index >= 1: return .cursor(.line(index: index))
        case (nil, let percent?) where (1...100).contains(percent):
          return .cursor(.percent(percent))
        default: return nil
        }
      })
    let selections: [(InputMotion, String)] = [
      (.selectLeft, "a character left"), (.selectRight, "a character right"),
      (.selectUp, "a line up"), (.selectDown, "a line down"),
      (.selectWordLeft, "a word left"), (.selectWordRight, "a word right"),
      (.selectLineStart, "to the line's start"), (.selectLineEnd, "to the line's end"),
      (.selectDocumentStart, "to the text's start"), (.selectDocumentEnd, "to the text's end"),
    ]
    for (motion, extent) in selections {
      table["input \(motion.rawValue)"] = inputMotion(
        motion, "Extend the selection \(extent) with the app's own key")
    }
    for position in ScrollCursorPosition.allCases {
      let place: String
      switch position {
      case .top: place = "at the top (zt)"
      case .middle: place = "in the middle (zz)"
      case .bottom: place = "at the bottom (zb)"
      }
      table["scroll \(position.rawValue)"] = .init(
        "Scroll the focused text so the cursor's line sits \(place)",
        parse: { a in a.args.isEmpty ? .scrollCursor(position) : nil })
    }
    return table
  }()

  /// Dispatch table keyed by `"<topic> <action>"`. Adding a command is a
  /// two-step change: add a case to `URLCommand`, then add its summary,
  /// parameters and parser closure to its family's table
  /// (`CommandTable+<Family>.swift`). `AppDelegate` switches exhaustively
  /// over `URLCommand` so the compiler flags any missed wiring.
  private static let commands: [String: CommandDefinition] = [
    pointerCommands, inputCommands, modesCommands, appsCommands, windowsCommands, flashCommands,
    systemCommands, cursorCommands,
  ].reduce(into: [:]) { table, family in
    table.merge(family) { listed, _ in
      preconditionFailure("two commands share a name: \(listed.summary)")
    }
  }

  static var usageText: String {
    commandNames.compactMap { syntax(for: $0, prefix: "flash ") }.joined(separator: "\n")
  }

  static func syntax(for name: CommandName, prefix: String) -> String? {
    guard let definition = commands[name.description] else { return nil }
    let arguments = definition.parameters.map(\.syntax).joined(separator: " ")
    return prefix + name.description + (arguments.isEmpty ? "" : " " + arguments)
  }

  /// The arguments `name` requires, so completion keeps its line open.
  static func requiresArguments(_ name: CommandName) -> Bool {
    commands[name.description]?.parameters.contains(where: \.required) ?? false
  }
}
