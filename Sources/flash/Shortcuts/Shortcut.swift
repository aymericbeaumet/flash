import Foundation

enum ModeScope: String, CaseIterable, Hashable {
  case all
  case normal
  case insert
}

/// One entry from `[mode.all.mappings]`, `[mode.normal.mappings]`, or
/// `[mode.insert.mappings]`.
/// The key is the mapping lhs and the action is resolved at config load.
/// `repeatsOnFinalKey` keeps a completed normal-mode sequence armed so each
/// additional press of its final key dispatches the same mapping (`[aaaa`).
struct ModeMapping: Equatable {
  let key: String
  let action: MappingCommand
  let repeatsOnFinalKey: Bool

  init(key: String, action: MappingCommand, repeatsOnFinalKey: Bool = false) {
    self.key = key
    self.action = action
    self.repeatsOnFinalKey = repeatsOnFinalKey
  }
}

/// What a mapping fires. Resolved at config load so Carbon callbacks
/// and overlay key handling never re-parse on the hot path.
///
/// The action's TOML form is always an array of strings, either directly as a
/// compact mapping value or under `action` in an inline mapping table. If
/// `argv[0]` names Flash (`"flash"` or a path whose basename is `flash`), the
/// remainder is parsed against the resident verb table
/// (``URLEventHandler/parse(verb:args:)``) and dispatched in-process. Otherwise
/// the array is executed as argv (no shell wrap, just env / `~` expansion on
/// each element).
enum MappingCommand: Hashable {
  case flashCommand(URLCommand)
  case shellCommand([String])
}

/// Build a mapping action from a TOML array.
///
///     ["flash", "mouse_target"]                    → in-process mouseTarget
///     ["flash", "mouse_target", "--modifiers=cmd"] → preset Command-click
///     ["flash", "mouse_grid", "--secondary"]       → in-process mouseGrid (bool flag)
///     ["flash", "app_open", "--name=Alacritty"]    → in-process openApp
///     ["sh", "-c", "echo hi"]                      → exec sh -c "echo hi"
///     ["~/dotfiles/toggle.sh", "off"]              → exec the expanded path
///
/// Returns nil when the array is empty, the verb is unknown, or required
/// verb args are missing.
func parseMappingCommand(argv: [String]) -> MappingCommand? {
  guard let first = argv.first else { return nil }
  if mappingCommandHeadNamesFlash(first) {
    let tail = Array(argv.dropFirst())
    guard let verb = tail.first, !verb.isEmpty else { return nil }
    let args = parseVerbArgs(tail.dropFirst())
    guard let cmd = URLEventHandler.parse(verb: verb, args: args) else { return nil }
    return .flashCommand(cmd)
  }
  return .shellCommand(argv)
}

func mappingCommandHeadNamesFlash(_ value: String) -> Bool {
  let expanded = CommandMappingRunner.expandLeadingTilde(value)
  return URL(fileURLWithPath: expanded).lastPathComponent == "flash"
}

/// Parse `["--k1=v1", "--k2", "--k3=v with spaces"]` into a dict. Standard
/// long-flag shell syntax:
///   - `--name=value` → `{ "name": "value" }`
///   - `--flag`       → `{ "flag": "1" }` (bare flag, value `"1"` so
///                       `VerbArgs.bool` reports true)
///   - `name` / `name=value` without the leading `--` → silently dropped
///     to avoid a stale pre-`--` config sneaking in. The verb dispatcher
///     will fail validation if the required arg never arrives.
///
/// Hyphens in the flag name are normalized to underscores so
/// `--restore-mode` and `--restore_mode` both land in the dict as
/// `restore_mode` — the internal key always uses snake_case.
private func parseVerbArgs(_ entries: ArraySlice<String>) -> [String: String] {
  var out: [String: String] = [:]
  for entry in entries {
    guard entry.hasPrefix("--") else { continue }
    let body = String(entry.dropFirst(2))
    guard !body.isEmpty else { continue }
    if let eq = body.firstIndex(of: "=") {
      let key = String(body[..<eq]).replacingOccurrences(of: "-", with: "_")
      let value = String(body[body.index(after: eq)...])
      out[key] = value
    } else {
      out[body.replacingOccurrences(of: "-", with: "_")] = "1"
    }
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
