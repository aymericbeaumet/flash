import Foundation

/// One run of Flash's command grammar: the words after `flash` in a
/// terminal, or after `:` on the command line. Both surfaces resolve the
/// same words through ``NormalModeDispatcher/resolveCommandWords(_:inventory:)``
/// against the same inventory and run them through the resident's one
/// runner, so a line means the same thing typed in either place. Config
/// files and mappings stay canonical (`URLEventHandler.parse(words:)`).
struct CommandInvocation: Equatable {
  /// The words to resolve, without the `#` prefix.
  var words: [String]
  /// Where relative paths in the words resolve: the shell's directory for
  /// `flash`, the home directory for `:`.
  var workingDirectory: String?
  /// `#` before the words (`:#aws whoami`, `flash '#aws' whoami`): the
  /// output is also put on the clipboard.
  var capturesOutput: Bool

  /// `words` as typed; a leading `#`, alone or glued to the first word,
  /// asks for the output on the clipboard.
  init(words: [String], workingDirectory: String? = nil) {
    var words = words
    var captures = false
    if let first = words.first, first.hasPrefix("#") {
      captures = true
      let rest = String(first.dropFirst())
      if rest.isEmpty { words.removeFirst() } else { words[0] = rest }
    }
    self.words = words
    self.workingDirectory = workingDirectory
    self.capturesOutput = captures
  }

  /// The line as the log and a rejection name it.
  var line: String { words.joined(separator: " ") }
}

/// How an invocation ended: the CLI's exit status and output, and what the
/// command line shows. It crosses the socket as a `result` message's
/// `result` object (`IPCProtocol.resultFrame`), which `flash --json` prints.
struct CommandInvocationResult: Equatable, Codable {
  enum Status: String, Codable {
    /// It ran; exit 0.
    case succeeded
    /// It ran and failed, or found nothing to act on; exit 1.
    case failed
    /// The words name no command, or more than one; exit 2.
    case rejected
    /// A query the CLI runs itself (`config check`), in its own directory
    /// and environment.
    case local
  }

  var status: Status
  /// Text the command produced: printed by the CLI, shown (or copied) by
  /// the command line.
  var output: String?
  /// Why it failed or was rejected.
  var message: String?
  /// For `.local`: the query's words and its arguments.
  var query: String?
  var arguments: [String: String]?

  static func succeeded(_ output: String? = nil) -> Self {
    Self(status: .succeeded, output: output.flatMap { $0.isEmpty ? nil : $0 })
  }

  static func failed(_ message: String, output: String? = nil) -> Self {
    Self(status: .failed, output: output.flatMap { $0.isEmpty ? nil : $0 }, message: message)
  }

  static func rejected(_ message: String) -> Self {
    Self(status: .rejected, message: message)
  }

  static func local(_ query: FlashQuery, arguments: [String: String]) -> Self {
    Self(status: .local, query: query.name.description, arguments: arguments)
  }

  /// The CLI's exit status. A `.local` result is replaced by the local
  /// query's own before the CLI exits.
  var exitCode: Int32 {
    switch status {
    case .succeeded, .local: return 0
    case .failed: return 1
    case .rejected: return 2
    }
  }

  var json: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data(#"{"status":"failed"}"#.utf8)
  }

  init(
    status: Status, output: String? = nil, message: String? = nil, query: String? = nil,
    arguments: [String: String]? = nil
  ) {
    self.status = status
    self.output = output
    self.message = message
    self.query = query
    self.arguments = arguments
  }

  init?(json: Data) {
    guard let decoded = try? JSONDecoder().decode(Self.self, from: json) else { return nil }
    self = decoded
  }
}

extension NormalModeDispatcher.CommandLineResolution {
  /// Why `words` run nothing, naming what they could have been; nil when
  /// they resolve to something that runs.
  func rejection(
    of words: [String], inventory: NormalModeDispatcher.CommandLineInventory
  ) -> String? {
    let line = words.joined(separator: " ")
    switch self {
    case .commands, .plugin, .query, .open, .flashlight, .shell, .normalKeys:
      return nil
    case .empty:
      return "no command given"
    case .unknown:
      let hint =
        URLEventHandler.suggestionPhrase(URLEventHandler.suggestedCommands(for: words))
        .map { "; did you mean \($0)?" } ?? ""
      return "unknown command or invalid arguments: \(line)\(hint)"
    case .ambiguous(let candidates):
      return "'\(line)' is ambiguous: \(candidates.joined(separator: ", "))"
    case .incomplete(let word):
      if let actions = inventory.actions(of: word) {
        return "'\(word)' needs an action: \(actions.sorted().joined(separator: ", "))"
      }
      if word == "!" { return "'!' needs a shell command" }
      if let subcommands = inventory.pluginCommands[word] {
        let named = subcommands.filter { !$0.isEmpty && $0 != "*" }.sorted()
        return named.isEmpty
          ? "'\(word)' needs its words"
          : "'\(word)' needs a subcommand: \(named.joined(separator: ", "))"
      }
      return "'\(word)' needs its words"
    }
  }
}
