import Foundation

enum ModeScope: String, CaseIterable, Hashable {
  case all
  case normal
  case insert
}

/// One entry from `[mode.all]`, `[mode.normal]`, or `[mode.insert]`.
/// The key is the mapping lhs and the action is resolved at config load.
struct ModeMapping: Equatable {
  let key: String
  let action: MappingAction
}

/// What a mapping fires. Resolved at config load so Carbon callbacks
/// and overlay key handling never parse URL strings on the hot path.
enum MappingAction: Equatable {
  case flashCommand(URLCommand)
}

func parseMappingAction(rawString s: String) -> MappingAction? {
  guard let cmd = URLEventHandler.parseFlashURL(s) else { return nil }
  return .flashCommand(cmd)
}

extension MappingAction {
  var command: URLCommand {
    switch self {
    case .flashCommand(let command):
      return command
    }
  }

  var diagnosticDescription: String {
    switch self {
    case .flashCommand(let command):
      return command.diagnosticDescription
    }
  }
}
