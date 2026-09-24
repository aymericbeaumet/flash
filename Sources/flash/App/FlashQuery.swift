import Foundation

/// `flash status`, `flash doctor` and `flash config_check`: CLI queries that
/// report instead of act. They live in their own table, apart from the verb
/// table mappings resolve against, so no mapping can fire one, and their names
/// are reserved against plugin verbs.
enum FlashQuery: String, CaseIterable {
  /// The resident's state, answered as JSON in the AppleEvent reply.
  case status
  /// Permission, capture, config and plugin checks, answered as JSON once
  /// they finish off the main thread.
  case doctor
  /// Validates a config file in the CLI process alone; the resident is never
  /// contacted.
  case configCheck = "config_check"

  /// Whether the CLI sends the query to the resident.
  var answeredByResident: Bool { self != .configCheck }

  /// Why `flash <name>` cannot be a mapping command or a plugin verb.
  static func reservationMessage(_ name: String) -> String? {
    guard FlashQuery(rawValue: name) != nil else { return nil }
    return "flash \(name) is a CLI query; run it from a terminal"
  }
}
