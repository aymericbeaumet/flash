import FlashCore
import Foundation

/// `resident status`, `resident doctor`, `config check`, `config schema`,
/// `cli completion` and `cli manpage`: queries that
/// report instead of act. They live in their own table, apart from the
/// command table mappings resolve against, so no mapping can fire one;
/// `flash resident status` and `:resident status` run them alike, and their
/// topics are Flash's, so no plugin command can take them.
enum FlashQuery: CaseIterable {
  /// The resident's state.
  case status
  /// Permission, capture, config and plugin checks, run off the main thread.
  case doctor
  /// Validates a config file. The CLI runs it in its own process, so it
  /// works without the resident; the command line runs it in the resident.
  case configCheck
  /// The JSON Schema of flash.toml for this version, for editors
  /// (`ConfigSchema`). Run where it is asked, like `config check`.
  case configSchema
  /// The zsh, bash or fish completion script (`CLIReference`).
  case completion
  /// The `flash(1)` man page, in roff.
  case manPage
  /// Host events as NDJSON, one `event` line each, for as long as the
  /// resident runs (`IPCClient.watch`). The CLI streams it over its own
  /// connection; the command line cannot.
  case eventsWatch

  var name: CommandName {
    switch self {
    case .status: return CommandName("resident", "status")
    case .doctor: return CommandName("resident", "doctor")
    case .configCheck: return CommandName("config", "check")
    case .configSchema: return CommandName("config", "schema")
    case .completion: return CommandName("cli", "completion")
    case .manPage: return CommandName("cli", "manpage")
    case .eventsWatch: return CommandName("events", "watch")
    }
  }

  init?(topic: String, action: String) {
    guard let query = Self.allCases.first(where: { $0.name == CommandName(topic, action) })
    else { return nil }
    self = query
  }

  init?(name: String) {
    guard let query = Self.allCases.first(where: { $0.name.description == name }) else {
      return nil
    }
    self = query
  }

  /// What the query does, for completion and the catalog.
  var summary: String {
    switch self {
    case .status: return "Report the resident's mode, capture, config and plugins"
    case .doctor: return "Check permissions, key capture, config, hotkeys and plugins"
    case .configCheck: return "Validate the config file, or --file=<path>"
    case .configSchema: return "Print flash.toml's JSON Schema, for editors"
    case .completion: return "Print the shell completion script, --shell=zsh, bash or fish"
    case .manPage: return "Print the flash(1) man page"
    case .eventsWatch:
      return "Print host events as they happen, one JSON line each, --name=<glob,...> --count=<n>"
    }
  }

  /// `--json` for the reports, `--file=<path>` for `config check`.
  func accepts(_ arguments: [String: String]) -> Bool {
    switch self {
    case .status, .doctor:
      return arguments.keys.allSatisfy { $0 == "json" }
        && (arguments["json"].map { $0 == "1" } ?? true)
    case .configCheck:
      return arguments.keys.allSatisfy { $0 == "file" }
        && (arguments["file"].map { !$0.isEmpty } ?? true)
    case .configSchema, .manPage:
      return arguments.isEmpty
    case .completion:
      return arguments.keys.allSatisfy { $0 == "shell" }
        && arguments["shell"].flatMap(CLIReference.Shell.init(rawValue:)) != nil
    case .eventsWatch:
      guard arguments.keys.allSatisfy({ $0 == "name" || $0 == "count" }) else { return false }
      if let count = arguments["count"], (Int(count) ?? 0) < 1 { return false }
      guard let names = arguments["name"] else { return true }
      let patterns = Self.eventPatterns(names)
      guard !patterns.isEmpty, patterns.count <= IPCProtocol.maxSubscriptionPatterns,
        case .success = IPCProtocol.resolveSubscription(patterns)
      else { return false }
      return true
    }
  }

  /// `events watch --name=<glob,...>`: the patterns it subscribes to; every
  /// streamed event without one.
  static func eventPatterns(_ names: String?) -> [String] {
    guard let names else { return ["core:*"] }
    return names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Answered from files alone, so the CLI runs it in its own process and
  /// it works without the resident.
  var runsInCLI: Bool {
    switch self {
    case .status, .doctor, .eventsWatch: return false
    case .configCheck, .configSchema, .completion, .manPage: return true
    }
  }

  /// A report's JSON as printed: pretty JSON with `--json`, else its text.
  static func render(_ query: FlashQuery, json: Data, asJSON: Bool) -> String? {
    guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
      return nil
    }
    if asJSON {
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      return data.flatMap { String(data: $0, encoding: .utf8) }
    }
    return query == .doctor ? Doctor.render(object) : FlashStatusReport.render(object)
  }

  /// Why `flash <topic> <action>` cannot be a mapping command.
  static func reservationMessage(topic: String, action: String) -> String? {
    guard let query = FlashQuery(topic: topic, action: action) else { return nil }
    return "flash \(query.name) is a query; run it from a terminal or the command line"
  }
}
