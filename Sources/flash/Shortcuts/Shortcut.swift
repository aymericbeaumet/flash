import Foundation

enum ModeScope: String, CaseIterable, Hashable {
  case all
  case normal
  case insert
  case terminal
  case command
}

/// One entry from `[mode.all.mappings]`, `[mode.normal.mappings]`, or
/// `[mode.insert.mappings]`, `[mode.command.mappings]`, or `[mode.terminal.mappings]`.
/// Terminal mappings are evaluated locally by the focused terminal popup.
/// The key is the mapping lhs and the action is resolved at config load.
/// `repeatsOnFinalKey` keeps a completed normal-mode sequence armed so each
/// additional press of its final key dispatches the same mapping (`[aaaa`).
struct ModeMapping: Equatable {
  let key: String
  let action: MappingCommand
  let repeatsOnFinalKey: Bool

  var nativeHotkey: ParsedHotkey? {
    let atoms = NormalModeInterpreter.keyAtoms(from: key)
    guard atoms.count == 1, let atom = atoms.first else { return nil }
    let hotkey =
      atom.hasPrefix("ctrl-") && !atom.contains("+")
      ? "ctrl+" + String(atom.dropFirst("ctrl-".count)) : atom
    guard let parsed = HotkeySyntax.parse(hotkey: hotkey), parsed.modifiers != 0 else {
      return nil
    }
    return parsed
  }

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
    guard let args = try? CommandArguments.parse(tail.dropFirst()) else { return nil }
    guard let cmd = URLEventHandler.parse(verb: verb, args: args) else { return nil }
    return .flashCommand(cmd)
  }
  return .shellCommand(argv)
}

func mappingCommandHeadNamesFlash(_ value: String) -> Bool {
  let expanded = CommandLaunchConfiguration.expandLeadingTilde(value)
  return URL(fileURLWithPath: expanded).lastPathComponent == "flash"
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
