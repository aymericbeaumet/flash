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
  let action: MappingCommand
}

/// What a mapping fires. Resolved at config load so Carbon callbacks
/// and overlay key handling never re-parse on the hot path.
///
/// The TOML form is *always* an array of strings. If `argv[0] == "flash"`,
/// the remainder is parsed against the resident verb table
/// (``URLEventHandler/parse(verb:args:)``) and dispatched in-process.
/// Otherwise the array is executed as argv (no shell wrap, just env / `~`
/// expansion on each element).
enum MappingCommand: Hashable {
  case flashCommand(URLCommand)
  case shellCommand([String])
}

/// Build a mapping action from a TOML array.
///
///     ["flash", "mouse_target"]                  → in-process mouseTarget
///     ["flash", "mouse_grid", "secondary=1"]     → in-process mouseGrid (arg)
///     ["sh", "-c", "echo hi"]                    → exec sh -c "echo hi"
///     ["~/dotfiles/toggle.sh", "off"]            → exec the expanded path
///
/// Returns nil when the array is empty, the verb is unknown, or required
/// verb args are missing.
func parseMappingCommand(argv: [String]) -> MappingCommand? {
  guard let first = argv.first else { return nil }
  if first == "flash" {
    let tail = Array(argv.dropFirst())
    guard let verb = tail.first, !verb.isEmpty else { return nil }
    let args = parseVerbArgs(tail.dropFirst())
    guard let cmd = URLEventHandler.parse(verb: verb, args: args) else { return nil }
    return .flashCommand(cmd)
  }
  return .shellCommand(argv)
}

/// Parse `["k1=v1", "k2=v2", ...]` slices into `["k1": "v1", "k2": "v2"]`.
/// Entries without `=` are silently dropped — the verb dispatcher will
/// fail validation downstream if the arg was required.
private func parseVerbArgs(_ entries: ArraySlice<String>) -> [String: String] {
  var out: [String: String] = [:]
  for entry in entries {
    guard let eq = entry.firstIndex(of: "=") else { continue }
    let key = String(entry[..<eq])
    let value = String(entry[entry.index(after: eq)...])
    out[key] = value
  }
  return out
}

extension MappingCommand {
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
    "\""
      + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
