import Foundation

enum ModeScope: String, CaseIterable, Hashable {
  case all
  case normal
  case insert
}

/// One entry from `[mode.all.mappings]`, `[mode.normal.mappings]`, or
/// `[mode.insert.mappings]`.
/// The key is the mapping lhs and the action is resolved at config load.
struct ModeMapping: Equatable {
  let key: String
  let action: MappingAction
}

/// What a mapping fires. Resolved at config load so Carbon callbacks
/// and overlay key handling never parse URL strings on the hot path.
enum MappingAction: Hashable {
  case flashCommand(URLCommand)
  case shellCommand([String])
}

func parseMappingAction(rawString s: String) -> MappingAction? {
  guard let cmd = URLEventHandler.parseFlashURL(s) else { return nil }
  return .flashCommand(cmd)
}

extension MappingAction {
  var command: URLCommand? {
    switch self {
    case .flashCommand(let command):
      return command
    case .shellCommand:
      return nil
    }
  }

  var diagnosticDescription: String {
    switch self {
    case .flashCommand(let command):
      return command.diagnosticDescription
    case .shellCommand(let argv):
      return "[" + argv.map(Self.tomlQuotedString).joined(separator: ", ") + "]"
    }
  }

  var configValue: Any {
    switch self {
    case .flashCommand(let command):
      return command.diagnosticDescription
    case .shellCommand(let argv):
      return argv
    }
  }

  private static func tomlQuotedString(_ value: String) -> String {
    "\"" + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
