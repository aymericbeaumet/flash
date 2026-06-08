import Foundation
import FlashCore

/// Command-line (`:cmd`) command vocabulary, parser, completion engine,
/// and the spec table used by `helpText` to render `:command` lines.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeDispatcher {
  enum CommandLineCommand: Equatable {
    case quit(force: Bool)
    case save
    case saveAndQuit(force: Bool)
    case print
    case open
    case newWindow
    case newTab
    case close
    case find
    case undo
    case redo
    case copy
    case cut
    case paste
    case copyAll
    case plugins(PluginsSubcommand)
    case mappings
    case help(topic: String?)
  }

  enum PluginsSubcommand: Equatable {
    /// Bare `:plugins` — show the modal status view (current behavior).
    case modal
    /// `:plugins list` / `:plugins ls` — render the status table inline.
    case list
    /// `:plugins reload` — stop and restart every loaded plugin.
    case reload
  }

  static func commandLineCommand(_ raw: String) -> CommandLineCommand? {
    if let plugins = pluginsCommand(raw) {
      return plugins
    }
    guard let parsed = parseCommandLine(raw) else { return nil }
    let matches = commandLineSpecs.compactMap { spec in
      spec.command(for: parsed.body, bang: parsed.bang)
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  /// `:plugins`, `:plugins list`, `:plugins ls`, `:plugins reload`.
  /// Returns nil when the input is not a `:plugins` invocation so the
  /// generic command-spec table runs.
  private static func pluginsCommand(_ raw: String) -> CommandLineCommand? {
    var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.hasPrefix(":") else { return nil }
    body.removeFirst()
    body = body.trimmingCharacters(in: .whitespaces)
    let parts = body.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() }
    guard let head = parts.first, head == "plugins" else { return nil }
    let args = Array(parts.dropFirst())
    if args.isEmpty {
      return .plugins(.modal)
    }
    guard args.count == 1 else { return nil }
    switch args[0] {
    case "list", "ls":
      return .plugins(.list)
    case "reload":
      return .plugins(.reload)
    default:
      return nil
    }
  }

  /// argv for `:open <args>` — the rest of the line split on whitespace,
  /// forwarded verbatim to `/usr/bin/open`. Returns nil when the line is
  /// not an `:open` invocation. Bare `:open` (no args) returns `[]`.
  static func commandLineOpenForward(_ raw: String) -> [String]? {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
      body.removeLeadingWhitespace()
    }
    let name = "open"
    if body.lowercased() == name {
      return []
    }
    guard body.count > name.count else { return nil }
    let nameEnd = body.index(body.startIndex, offsetBy: name.count)
    guard body[..<nameEnd].lowercased() == name, body[nameEnd].isWhitespace else { return nil }
    let rest = String(body[body.index(after: nameEnd)...])
    return rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  static func commandLineCandidateQuery(_ raw: String) -> String? {
    if let query = commandLineQuery(raw, name: "flashlight", acceptsBareCommand: true) {
      return query
    }
    return commandLineEmojiQuery(raw)
  }

  /// Query for `:emojis <text>` (bare `:emojis` lists everything). Shares
  /// the live candidate-finder rendering with `open`/`flashlight`, but its
  /// candidate pool is the emoji source and selection inserts the glyph
  /// rather than activating an app.
  static func commandLineEmojiQuery(_ raw: String) -> String? {
    commandLineQuery(raw, name: "emojis", acceptsBareCommand: true)
  }

  static func commandLineHelpTopic(_ raw: String) -> String?? {
    var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    body.removeLeadingWhitespace()
    guard !body.isEmpty else { return nil }
    let lower = body.lowercased()
    guard lower == "h" || lower == "help" || lower.hasPrefix("h ") || lower.hasPrefix("help ")
    else { return nil }
    let nameLength = lower.hasPrefix("help") ? 4 : 1
    let nameEnd = body.index(body.startIndex, offsetBy: nameLength)
    if body.count == nameLength {
      return .some(nil)
    }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    let topic = String(body[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return .some(topic.isEmpty ? nil : topic)
  }

  private static func commandLineQuery(
    _ raw: String,
    name: String,
    acceptsBareCommand: Bool
  ) -> String? {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
      body.removeLeadingWhitespace()
    }

    if acceptsBareCommand, body.lowercased() == name {
      return ""
    }
    guard body.count > name.count else { return nil }
    let nameEnd = body.index(body.startIndex, offsetBy: name.count)
    guard body[..<nameEnd].lowercased() == name else { return nil }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    let query = String(body[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return query
  }

  enum BangPolicy {
    case rejected
    case accepted
  }

  struct CommandLineName: ExpressibleByStringLiteral {
    var documented: String
    var full: String
    var minimumLength: Int

    init(stringLiteral value: String) {
      self.init(value)
    }

    init(_ documented: String) {
      self.documented = documented
      var full = ""
      var required = 0
      var optional = false
      for ch in documented {
        switch ch {
        case "[":
          optional = true
        case "]":
          optional = false
        default:
          full.append(ch)
          if !optional { required += 1 }
        }
      }
      self.full = full
      self.minimumLength = required
    }

    func matches(_ body: String) -> Bool {
      body.count >= minimumLength && body.count <= full.count && full.hasPrefix(body)
    }
  }

  struct CommandLineSpec {
    var names: [CommandLineName]
    var bangPolicy: BangPolicy
    var build: (Bool) -> CommandLineCommand

    var helpLine: String {
      let base = names.map { ":\($0.documented)" }.joined(separator: " / ")
      guard bangPolicy == .accepted else { return base }
      return "\(base) / \(names.map { ":\($0.documented)!" }.joined(separator: " / "))"
    }

    func command(for body: String, bang: Bool) -> CommandLineCommand? {
      if bang, bangPolicy == .rejected { return nil }
      guard names.contains(where: { $0.matches(body) }) else { return nil }
      return build(bang)
    }
  }

  static let commandLineSpecs: [CommandLineSpec] = [
    CommandLineSpec(names: ["q[uit]"], bangPolicy: .accepted) { .quit(force: $0) },
    CommandLineSpec(names: ["w[rite]"], bangPolicy: .accepted) { _ in .save },
    CommandLineSpec(names: ["wq", "x[it]"], bangPolicy: .accepted) {
      .saveAndQuit(force: $0)
    },
    CommandLineSpec(names: ["p[rint]"], bangPolicy: .rejected) { _ in .print },
    CommandLineSpec(names: ["e[dit]"], bangPolicy: .rejected) { _ in .open },
    CommandLineSpec(names: ["new"], bangPolicy: .rejected) { _ in .newWindow },
    CommandLineSpec(names: ["tabnew", "tabedit", "tabe"], bangPolicy: .rejected) {
      _ in .newTab
    },
    CommandLineSpec(names: ["bd[elete]", "cl[ose]"], bangPolicy: .rejected) {
      _ in .close
    },
    CommandLineSpec(names: ["find", "grep", "vimgrep"], bangPolicy: .rejected) { _ in .find },
    CommandLineSpec(names: ["u[ndo]"], bangPolicy: .rejected) { _ in .undo },
    CommandLineSpec(names: ["red[o]"], bangPolicy: .rejected) { _ in .redo },
    CommandLineSpec(names: ["y[ank]", "copy"], bangPolicy: .rejected) { _ in .copy },
    CommandLineSpec(names: ["d[elete]", "cut"], bangPolicy: .rejected) { _ in .cut },
    CommandLineSpec(names: ["pu[t]", "paste"], bangPolicy: .rejected) { _ in .paste },
    CommandLineSpec(names: ["%y[ank]"], bangPolicy: .rejected) { _ in .copyAll },
    CommandLineSpec(names: ["plugins"], bangPolicy: .rejected) { _ in .plugins(.modal) },
    CommandLineSpec(names: ["map[pings]"], bangPolicy: .rejected) { _ in .mappings },
  ]

  struct CommandLineCompletion: Equatable {
    enum Kind: Equatable {
      case terminal
      case acceptsArgs
      case pluginSubcommand
    }
    var label: String
    var insertion: String
    var kind: Kind
  }

  struct CommandLineCompletionContext: Equatable {
    var prefix: String
    var query: String
    var items: [CommandLineCompletion]
  }

  static func commandLineCompletions(
    _ raw: String,
    pluginCommands: [String],
    pluginSubcommands: [String: [String]],
    helpTopics: [String] = []
  ) -> CommandLineCompletionContext? {
    var body = raw
    body.removeLeadingWhitespace()
    guard body.hasPrefix(":") else { return nil }
    body.removeFirst()

    if body.first(where: { $0.isWhitespace }) == nil {
      let items = topLevelCompletions(pluginCommands: pluginCommands)
      return CommandLineCompletionContext(prefix: ":", query: body, items: items)
    }

    let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let command = String(parts[0]).lowercased()
    let rest = String(parts[1])
    guard rest.first(where: { $0.isWhitespace }) == nil else { return nil }

    // Built-in `help` completes against the topic registry. Future
    // commands plug in here the same way: assemble a list and emit
    // a `pluginSubcommand`-shaped completion. For dynamic candidate-style
    // commands (`open`, `flashlight`) the existing
    // `candidateFinderQuery` path renders results live and is the
    // place to wire async / loading state when needed.
    if command == "help" {
      let items = helpTopics.sorted().map { topic in
        CommandLineCompletion(label: topic, insertion: topic, kind: .pluginSubcommand)
      }
      return CommandLineCompletionContext(
        prefix: ":\(command) ", query: rest, items: items)
    }
    if command == "plugins" {
      let items = pluginsBuiltinSubcommands.map { name in
        CommandLineCompletion(label: name, insertion: name, kind: .pluginSubcommand)
      }
      return CommandLineCompletionContext(
        prefix: ":\(command) ", query: rest, items: items)
    }

    let subcommands = pluginSubcommands.first { key, _ in
      key.localizedCaseInsensitiveCompare(command) == .orderedSame
    }?.value ?? []
    guard !subcommands.isEmpty else { return nil }
    let items = subcommands.map { name in
      CommandLineCompletion(label: name, insertion: name, kind: .pluginSubcommand)
    }
    return CommandLineCompletionContext(
      prefix: ":\(command) ", query: rest, items: items)
  }

  private static let acceptsArgsCompletionNames: Set<String> = [
    "flashlight", "emojis", "help", "plugins",
  ]

  /// Built-in subcommands surfaced by `:plugins <tab>`. Kept in lockstep
  /// with `pluginsCommand(_:)`.
  static let pluginsBuiltinSubcommands: [String] = ["list", "ls", "reload"]

  private static func topLevelCompletions(pluginCommands: [String])
    -> [CommandLineCompletion]
  {
    var items: [CommandLineCompletion] = []
    var seen = Set<String>()
    // Only the primary (first) name per spec is surfaced. Aliases
    // (`tabe`, `wq`, `cut`, …) still work as command-line input but
    // don't pollute the suggestion list.
    for spec in commandLineSpecs {
      guard let primary = spec.names.first else { continue }
      let full = primary.full
      guard !full.hasPrefix("%") else { continue }
      guard seen.insert(full).inserted else { continue }
      let kind: CommandLineCompletion.Kind =
        acceptsArgsCompletionNames.contains(full) ? .acceptsArgs : .terminal
      let insertion = kind == .acceptsArgs ? "\(full) " : full
      items.append(CommandLineCompletion(label: full, insertion: insertion, kind: kind))
    }
    for extra in ["open", "help", "flashlight", "emojis"] where seen.insert(extra).inserted {
      items.append(
        CommandLineCompletion(label: extra, insertion: "\(extra) ", kind: .acceptsArgs))
    }
    let dedupedPlugins = Array(Set(pluginCommands.map { $0.lowercased() })).sorted()
    for command in dedupedPlugins where seen.insert(command).inserted {
      items.append(
        CommandLineCompletion(
          label: command, insertion: "\(command) ", kind: .acceptsArgs))
    }
    items.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    return items
  }

  static func pluginCommandLineInvocation(_ raw: String) -> (
    command: String, subcommand: String, args: [String], raw: String
  )? {
    var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    let parts = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard parts.count >= 2 else { return nil }
    return (
      command: parts[0],
      subcommand: parts[1],
      args: Array(parts.dropFirst(2)),
      raw: raw
    )
  }

  private static func parseCommandLine(_ raw: String) -> (body: String, bang: Bool)? {
    var command = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if command.hasPrefix(":") {
      command.removeFirst()
    }
    guard !command.isEmpty else { return nil }

    let bangCount = command.reduce(0) { $0 + ($1 == "!" ? 1 : 0) }
    guard bangCount <= 1 else { return nil }
    let bang = command.last == "!"
    if bang {
      command.removeLast()
      guard !command.isEmpty else { return nil }
    } else if bangCount > 0 {
      return nil
    }
    return (body: command, bang: bang)
  }
}
