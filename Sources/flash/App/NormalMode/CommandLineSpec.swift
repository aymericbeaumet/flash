import Foundation

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
    case closeWindow
    case find
    case undo
    case redo
    case copy
    case cut
    case paste
    case plugins(PluginsSubcommand)
    case mappings
    case help(topic: String?)
    case logs
    case commands
  }

  enum PluginsSubcommand: Equatable {
    /// Bare `:plugins` — show the modal status view.
    case modal
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

  /// `:plugins`, `:plugins reload`. Returns nil when the input is not a
  /// `:plugins` invocation so the generic command-spec table runs.
  private static func pluginsCommand(_ raw: String) -> CommandLineCommand? {
    var body = raw.trimmed
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

  /// Recognize the flashlight command only after its separating whitespace has
  /// been typed. Bare `:flashlight` still belongs to top-level command
  /// completion because the verb is not syntactically committed yet.
  static func commandLineCandidateQuery(_ raw: String) -> String? {
    commandLineQuery(raw, name: "flashlight")
  }

  struct CandidateFinderQuery: Equatable {
    /// `@<source>` narrows the pool to candidates whose `source` matches the
    /// token (exact or prefix; see `candidateMatchesSourceFilter`). `nil` when
    /// the user didn't type one.
    var sourceFilter: String?
    /// The residual search text (every non-selector token, space-joined).
    var text: String
  }

  /// Parse `@<source>` narrowing from the live query. At most one
  /// `@<source>` token is honoured — the first one. Every other token is
  /// kept as literal search text.
  ///
  /// Examples:
  ///   "@firefox.tabs gmail"        → source="firefox.tabs", text="gmail"
  ///   "@emojis.glyphs "            → source="emojis.glyphs", text=""
  ///   "gmail"                      → source=nil,            text="gmail"
  ///   "@"                          → source=nil,            text="@"
  static func candidateFinderSourceFilter(_ query: String) -> CandidateFinderQuery {
    var sourceFilter: String?
    var words: [Substring] = []
    for token in query.split(whereSeparator: { $0.isWhitespace }) {
      guard token.hasPrefix("@"), sourceFilter == nil else {
        words.append(token)
        continue
      }
      let body = token.dropFirst(1)
      if body.isEmpty {
        words.append(token)
        continue
      }
      sourceFilter = String(body)
    }
    return CandidateFinderQuery(
      sourceFilter: sourceFilter,
      text: words.joined(separator: " "))
  }

  static func commandLineHelpTopic(_ raw: String) -> String?? {
    var body = raw.trimmed
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
    let topic = String(body[restStart...]).trimmed
    return .some(topic.isEmpty ? nil : topic)
  }

  private static func commandLineQuery(
    _ raw: String,
    name: String
  ) -> String? {
    var body = raw.trimmingCharacters(in: .newlines)
    body.removeLeadingWhitespace()
    if body.hasPrefix(":") {
      body.removeFirst()
      body.removeLeadingWhitespace()
    }

    guard body.count > name.count else { return nil }
    let nameEnd = body.index(body.startIndex, offsetBy: name.count)
    guard body[..<nameEnd].lowercased() == name else { return nil }
    guard body[nameEnd].isWhitespace else { return nil }
    let restStart = body.index(after: nameEnd)
    // Preserve trailing whitespace: it's the signal `parseBangState`
    // uses to lock onto a bang. We only strip leading whitespace
    // between `flashlight` and the user's query, plus newlines (the
    // command-line buffer should never carry one, but Foundation's
    // string editing can leak them through paste).
    var query = String(body[restStart...])
    query = String(query.drop(while: { $0 == " " || $0 == "\t" }))
    // Preserve a leading `=` marker. It is calculator-owned syntax, not a
    // generic flashlight-query rewrite; evaluator plugins can claim it
    // explicitly while ordinary catalog matching still sees the marker.
    query = query.replacingOccurrences(of: "\n", with: "")
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
    // `:q` closes the focused OS window (vim's "close this window"); `:qa[ll]`
    // quits the whole app. `:q!` / `:qa!` force.
    CommandLineSpec(names: ["q[uit]"], bangPolicy: .accepted) { _ in .closeWindow },
    CommandLineSpec(names: ["qa[ll]"], bangPolicy: .accepted) { .quit(force: $0) },
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
    CommandLineSpec(names: ["plugins"], bangPolicy: .rejected) { _ in .plugins(.modal) },
    CommandLineSpec(names: ["logs"], bangPolicy: .rejected) { _ in .logs },
    CommandLineSpec(names: ["commands"], bangPolicy: .rejected) { _ in .commands },
    CommandLineSpec(names: ["map[pings]"], bangPolicy: .rejected) { _ in .mappings },
  ]

  /// Human-readable descriptions for the built-in command-line commands,
  /// keyed by primary `full` name. Lives next to `commandLineSpecs` so the
  /// two stay in sync; consumed by the HTTP inspector's command catalog.
  private static let coreCommandDescriptions: [String: String] = [
    "quit": "Quit the focused app (⌘Q)",
    "write": "Save the focused document (⌘S)",
    "wq": "Save then quit",
    "print": "Print the focused document",
    "edit": "Open the flashlight candidate finder",
    "new": "Open a new window",
    "tabnew": "Open a new tab",
    "bdelete": "Close the focused window/tab",
    "find": "Open the app's native find",
    "undo": "Undo (⌘Z)",
    "redo": "Redo (⌘⇧Z)",
    "yank": "Copy the selection (⌘C)",
    "delete": "Cut the selection (⌘X)",
    "put": "Paste (⌘V)",
    "plugins": "Open the plugins view in the HTTP debug dashboard",
    "logs": "Open the logs view in the HTTP debug dashboard",
    "commands": "Open the commands view in the HTTP debug dashboard",
    "mappings": "Show the active key mappings",
    "open": "Forward args to /usr/bin/open",
    "help": "Open a help topic",
    "flashlight": "Fuzzy finder across apps, tabs, and plugins",
  ]

  /// Flat catalog of every built-in command-line command, tagged
  /// `source = "core"`. The HTTP inspector merges this with each plugin's
  /// declared commands to list every command and where it comes from.
  static func coreCommandCatalog() -> [[String: Any]] {
    var result: [[String: Any]] = []
    var seen = Set<String>()
    for spec in commandLineSpecs {
      guard let primary = spec.names.first, seen.insert(primary.full).inserted else { continue }
      result.append([
        "name": ":\(primary.full)",
        "syntax": spec.helpLine,
        "aliases": spec.names.map { ":\($0.documented)" },
        "description": coreCommandDescriptions[primary.full] ?? "",
        "source": "core",
        "source_kind": "core",
      ])
    }
    for extra in ["open", "help", "flashlight"] where seen.insert(extra).inserted {
      result.append([
        "name": ":\(extra)",
        "syntax": ":\(extra) <args>",
        "aliases": [":\(extra)"],
        "description": coreCommandDescriptions[extra] ?? "",
        "source": "core",
        "source_kind": "core",
      ])
    }
    return result
  }

  /// A single completion candidate offered for a command or sub-command.
  ///
  /// Every candidate has a **value** (`insertion`) and a **label**
  /// (`label`). The label is purely cosmetic — it is what the user sees
  /// in the suggestion list and never affects behaviour. The value is
  /// what actually lands in the command-line buffer. When a candidate
  /// has no distinct label, set `label == insertion` so the value shows
  /// through.
  ///
  /// Selection semantics, uniform across built-in and plugin candidates:
  /// - `<tab>` inserts the candidate's value without sending the command
  ///   (the user can keep typing args).
  /// - `<CR>` inserts the candidate's value, then either leaves the line
  ///   open or submits according to `kind`.
  ///
  /// `kind` only governs what `<CR>` does once the value is inserted:
  /// `acceptsArgs` leaves the line open for arguments, while `terminal`
  /// and `pluginSubcommand` submit immediately.
  struct CommandLineCompletion: Equatable {
    enum Kind: Equatable {
      case terminal
      case acceptsArgs
      case pluginSubcommand
    }
    /// Cosmetic text shown in the suggestion list.
    var label: String
    /// The value inserted into the command line on `<tab>`/`<CR>`.
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
      let query = body
      var items = topLevelCompletions(pluginCommands: pluginCommands)
      if !query.isEmpty {
        let foldedQuery = query.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: .current)
        items = items.filter {
          $0.label.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
          ).hasPrefix(foldedQuery)
        }
      }
      return CommandLineCompletionContext(prefix: ":", query: query, items: items)
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

    let subcommands =
      pluginSubcommands.first { key, _ in
        key.localizedCaseInsensitiveCompare(command) == .orderedSame
      }?.value.filter { !$0.isEmpty && $0 != "*" } ?? []
    guard !subcommands.isEmpty else { return nil }
    let items = subcommands.map { name in
      CommandLineCompletion(label: name, insertion: name, kind: .pluginSubcommand)
    }
    return CommandLineCompletionContext(
      prefix: ":\(command) ", query: rest, items: items)
  }

  private static let acceptsArgsCompletionNames: Set<String> = [
    "flashlight", "help", "plugins",
  ]

  /// Built-in subcommands surfaced by `:plugins <tab>`. Kept in lockstep
  /// with `pluginsCommand(_:)`.
  static let pluginsBuiltinSubcommands: [String] = ["reload"]

  /// Whether typing `query` is enough to actually invoke the command shown
  /// as `label`, per vim's abbreviation rule. `:q` invokes `quit` (min `q`)
  /// but NOT `qall` (min `qa`), even though `qall` also starts with `q`.
  /// Used to rank invokable candidates above merely-prefix-matching ones so
  /// `:q<CR>` and the suggestion list both land on `quit`, matching the
  /// command parser (`commandLineCommand`) which already resolves `:q` to
  /// `quit`. Non-spec labels (plugins, `open`/`help`/`flashlight`) carry no
  /// abbreviation minimum, so any prefix counts as invokable.
  static func isInvokableAbbreviation(query: String, label: String) -> Bool {
    guard
      let spec = commandLineSpecs.first(where: { $0.names.first?.full == label }),
      let primary = spec.names.first
    else { return true }
    return query.count >= primary.minimumLength
  }

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
    for extra in ["open", "help", "flashlight"] where seen.insert(extra).inserted {
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

  /// Detect the `#` output-capture modifier. A `#` immediately after the
  /// `:` prompt (`:#aws whoami`) or at the very head (`#aws whoami`) means
  /// "run the command and put its stdout on the clipboard". Returns the
  /// raw with the `#` stripped (the leading `:` preserved so downstream
  /// parsers are unaffected) plus whether the modifier was present.
  static func commandLineClipboardModifier(_ raw: String) -> (raw: String, capture: Bool) {
    let trimmed = raw.trimmed
    var hadColon = false
    var body = trimmed
    if body.hasPrefix(":") {
      hadColon = true
      body.removeFirst()
      body = body.drop(while: { $0.isWhitespace }).description
    }
    guard body.hasPrefix("#") else { return (raw, false) }
    body.removeFirst()
    body = body.drop(while: { $0.isWhitespace }).description
    return ((hadColon ? ":" : "") + body, true)
  }

  static func pluginCommandLineInvocation(_ raw: String) -> (
    command: String, subcommand: String, args: [String], raw: String
  )? {
    var body = raw.trimmed
    if body.hasPrefix(":") {
      body.removeFirst()
    }
    body = body.trimmed
    guard !body.isEmpty else { return nil }
    let parts = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let command = parts.first else { return nil }
    // A single token is a top-level command (`:copy`); the plugin registered
    // it with an empty subcommand. Two or more tokens keep the classic
    // `command subcommand args…` shape.
    return (
      command: command,
      subcommand: parts.count >= 2 ? parts[1] : "",
      args: Array(parts.dropFirst(2)),
      raw: raw
    )
  }

  private static func parseCommandLine(_ raw: String) -> (body: String, bang: Bool)? {
    var command = raw.trimmed.lowercased()
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
