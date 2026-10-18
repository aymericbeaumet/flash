import Foundation

enum ModeScope: String, CaseIterable, Hashable {
  case all
  case normal
  case insert
  case terminal
  case command
  case hyper
  /// Read before NORMAL in HOLD (a held button dragging); NORMAL answers
  /// every key HOLD leaves unmapped.
  case hold
}

/// One entry from `[mode.all.mappings]`, `[mode.normal.mappings]`,
/// `[mode.insert.mappings]`, `[mode.command.mappings]`, `[mode.terminal.mappings]`,
/// `[mode.hyper.mappings]` or `[mode.hold.mappings]`.
/// Terminal mappings are evaluated locally by the focused terminal popup.
/// The key is the mapping lhs and the action is resolved at config load.
/// `repeatsOnFinalKey` keeps a completed normal-mode sequence armed so each
/// additional press of its final key dispatches the same mapping (`[aaaa`).
struct ModeMapping: Equatable {
  /// Built-in bindings, including the bundled `config.default.toml` layer.
  static let defaultOrigin = "default"

  let key: String
  let action: MappingCommand
  let repeatsOnFinalKey: Bool
  /// The single modified chord this mapping registers natively, parsed once
  /// at construction (config load) so scope changes and Carbon reconciliation
  /// never re-parse mapping keys.
  let nativeHotkey: ParsedHotkey?
  /// Where the binding was declared: `default`, `config` or
  /// `config:<filename>`, or `plugin:<name>`. Display metadata. Equality
  /// ignores it so the reference TOML, which restates the built-ins, still
  /// matches `Config()`'s defaults.
  let origin: String

  init(
    key: String, action: MappingCommand, repeatsOnFinalKey: Bool = false,
    origin: String = ModeMapping.defaultOrigin
  ) {
    self.key = key
    self.action = action
    self.repeatsOnFinalKey = repeatsOnFinalKey
    self.nativeHotkey = Self.parseNativeHotkey(key)
    self.origin = origin
  }

  static func configOrigin(file: String?) -> String {
    guard let file, !file.isEmpty else { return "config" }
    let name = URL(fileURLWithPath: file).lastPathComponent
    if name == "config.default.toml" { return defaultOrigin }
    return "config:\(name)"
  }

  static func pluginOrigin(id: String, name: String) -> String {
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return "plugin:\(label.isEmpty ? id : label)"
  }

  static func == (lhs: ModeMapping, rhs: ModeMapping) -> Bool {
    lhs.key == rhs.key && lhs.action == rhs.action
      && lhs.repeatsOnFinalKey == rhs.repeatsOnFinalKey
      && lhs.nativeHotkey == rhs.nativeHotkey
  }

  static func parseNativeHotkey(_ key: String) -> ParsedHotkey? {
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
}

/// What a mapping fires. Resolved at config load so Carbon callbacks
/// and overlay key handling never re-parse on the hot path.
///
/// The command's TOML form is always an array of strings, either directly as a
/// compact mapping value or under `command` in an inline mapping table. If
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
/// verb args are missing. A plugin command is `flash <command> <subcommand>`
/// (`caffeinate toggle`), never a one-word name.
func parseMappingCommand(argv: [String]) -> MappingCommand? {
  guard let first = argv.first else { return nil }
  if mappingCommandHeadNamesFlash(first) {
    let tail = Array(argv.dropFirst())
    guard let verb = tail.first, !verb.isEmpty else { return nil }
    // `flash media volumedown` before flag parsing. The tail is the command
    // bar's words, not `--name=value` flags.
    if let git = PluginGitInvocation.command(argvAfterFlash: tail) {
      return .flashCommand(git)
    }
    guard let args = try? CommandArguments.parse(tail.dropFirst()) else { return nil }
    if let cmd = URLEventHandler.parse(verb: verb, args: args) {
      return .flashCommand(cmd)
    }
    // A one-word name is only a Flash verb. Plugin commands are
    // `flash <command> <subcommand>` and were handled above.
    return nil
  }
  return .shellCommand(argv)
}

/// `flash <command> <subcommand> [word ...]`, the same words as
/// `:command subcommand word …`. Both words are required. Nil when the
/// command is not declared, or the subcommand is neither an exact
/// registration nor a `*` wildcard.
enum PluginGitInvocation {
  static func command(argvAfterFlash tail: [String]) -> URLCommand? {
    guard let name = tail.first?.lowercased(), !name.isEmpty,
      !URLEventHandler.isBuiltInVerb(name),
      FlashQuery(rawValue: name) == nil,
      PluginRepository.declaresCommand(name)
    else { return nil }
    let rest = Array(tail.dropFirst())
    guard let subcommand = rest.first, !subcommand.isEmpty else { return nil }
    guard PluginRepository.declaresCommand(name, subcommand: subcommand) else { return nil }
    return .pluginCommand(command: name, subcommand: subcommand, args: Array(rest.dropFirst()))
  }
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

  /// Canonical argv. A Flash verb is `["flash", "<verb>", ...]`, including
  /// flags the parser filled in. A shell mapping keeps the argv that was written.
  var argv: [String] {
    switch self {
    case .flashCommand(let command):
      return command.argv
    case .shellCommand(let words):
      return words
    }
  }

  var configValue: [String] { argv }

  private static func tomlQuotedString(_ value: String) -> String {
    "\""
      + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
