import Foundation

enum CommandArgumentError: Error, CustomStringConvertible {
  case malformed(String)
  case duplicate(String)

  var description: String {
    switch self {
    case .malformed(let value): return "invalid argument '\(value)'; use --name=value or --flag"
    case .duplicate(let name): return "duplicate argument '--\(name)'"
    }
  }
}

enum CommandArguments {
  static func parse<S: Sequence>(_ entries: S) throws -> [String: String]
  where S.Element == String {
    var result: [String: String] = [:]
    for entry in entries {
      guard entry.hasPrefix("--") else { throw CommandArgumentError.malformed(entry) }
      let parts = entry.dropFirst(2).split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = String(parts[0]).replacingOccurrences(of: "-", with: "_")
      guard let first = key.utf8.first, (97...122).contains(first),
        key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
      else { throw CommandArgumentError.malformed(entry) }
      guard result[key] == nil else { throw CommandArgumentError.duplicate(key) }
      result[key] = parts.count == 2 ? String(parts[1]) : "1"
    }
    return result
  }
}

struct CommandParameter: Equatable {
  enum Kind: Equatable {
    case flag
    case text(String)
    /// A whole number within the bounds, either of them open.
    case integer(min: Int?, max: Int?)
    /// One of a closed set of words.
    case choice([String])
  }
  let name: String
  let kind: Kind
  let required: Bool
  /// A bare word instead of `--name=value` (`tmux session main`). Only a
  /// command that declares its arguments (``DeclaredArguments``) has one.
  var positional = false
  /// One line saying what the argument is, for completion. A core command
  /// says it in its own summary.
  var summary = ""

  static func flag(_ name: String) -> Self { Self(name: name, kind: .flag, required: false) }
  static func text(_ name: String, _ placeholder: String, required: Bool = false) -> Self {
    Self(name: name, kind: .text(placeholder), required: required)
  }
  /// A whole number from 1.
  static func integer(_ name: String, required: Bool = false) -> Self {
    Self(name: name, kind: .integer(min: 1, max: nil), required: required)
  }

  func accepts(_ value: String?) -> Bool {
    guard let value else { return !required }
    switch kind {
    case .flag: return ["0", "1", "false", "true"].contains(value)
    case .integer(let min, let max):
      guard let number = Int(value) else { return false }
      return (min.map { number >= $0 } ?? true) && (max.map { number <= $0 } ?? true)
    case .text: return !required || !value.isEmpty
    case .choice(let values): return values.contains(value)
    }
  }

  /// `--name`, hyphenated as a command line writes it.
  var flagName: String { "--" + name.replacingOccurrences(of: "_", with: "-") }

  var syntax: String {
    let text: String
    switch kind {
    case .flag: text = flagName
    case .integer: text = positional ? "<n>" : flagName + "=<n>"
    case .text(let placeholder):
      text = positional ? "<\(placeholder)>" : flagName + "=<\(placeholder)>"
    case .choice(let values):
      let choices = "<\(values.joined(separator: "|"))>"
      text = positional ? choices : flagName + "=" + choices
    }
    return required ? text : "[\(text)]"
  }
}

/// The arguments of a command that declares them instead of parsing them: a
/// plugin's own command, whose manifest entry lists its `args`. The host
/// holds the words to the declaration before anything else happens (a
/// mapping at load, the command line and the CLI at resolution, a question
/// before it is asked) and hands the plugin one canonical spelling.
struct DeclaredArguments: Equatable {
  var parameters: [CommandParameter]

  /// No arguments at all: what an entry without `args` declares.
  static let none = DeclaredArguments(parameters: [])

  /// The words the command receives for `words`, or nil when the
  /// declaration does not accept them: an unknown, repeated or malformed
  /// argument, a value outside its type, a blank string, a missing required
  /// one, or a bare word without a positional to take it. Each element of
  /// `words` is one argument, as a mapping writes them. The result is in
  /// declaration order: the positional as a bare word, `--name=value` with a
  /// number in plain decimal, and `--name` for a flag that is on.
  func canonical(_ words: [String]) -> [String]? {
    let bare = words.filter { !$0.hasPrefix("--") }
    guard let named = try? CommandArguments.parse(words.filter { $0.hasPrefix("--") }) else {
      return nil
    }
    let positional = parameters.first(where: \.positional)
    guard bare.count <= (positional == nil ? 0 : 1),
      Set(named.keys).isSubset(of: Set(parameters.filter { !$0.positional }.map(\.name)))
    else { return nil }
    var result: [String] = []
    for parameter in parameters {
      let value = parameter.positional ? bare.first : named[parameter.name]
      guard parameter.accepts(value) else { return nil }
      guard let value else { continue }
      switch parameter.kind {
      case .flag:
        if value == "1" || value == "true" { result.append(parameter.flagName) }
      case .integer:
        guard let number = Int(value) else { return nil }
        result.append(parameter.positional ? "\(number)" : "\(parameter.flagName)=\(number)")
      case .text, .choice:
        guard !value.trimmed.isEmpty else { return nil }
        result.append(parameter.positional ? value : "\(parameter.flagName)=\(value)")
      }
    }
    return result
  }

  /// `--pid=<n> [--force]`, or empty without arguments.
  var syntax: String { parameters.map(\.syntax).joined(separator: " ") }

  var requiresArguments: Bool { parameters.contains(where: \.required) }
}

struct CommandDefinition {
  /// One line saying what the command does, for the catalog and completion.
  let summary: String
  let parameters: [CommandParameter]
  let parse: (CommandArgs) -> URLCommand?

  init(
    _ summary: String, _ parameters: [CommandParameter] = [],
    parse: @escaping (CommandArgs) -> URLCommand?
  ) {
    self.summary = summary
    self.parameters = parameters
    self.parse = parse
  }

  func command(arguments: [String: String]) -> URLCommand? {
    guard Set(arguments.keys).isSubset(of: Set(parameters.map(\.name))),
      parameters.allSatisfy({ $0.accepts(arguments[$0.name]) })
    else { return nil }
    return parse(CommandArgs(args: arguments))
  }
}
