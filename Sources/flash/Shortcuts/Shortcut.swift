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
  /// Read before NORMAL while a field is engaged (`TextScope`): Vim's text
  /// motions. NORMAL answers every key it leaves unmapped, and with no
  /// field engaged it is not read at all.
  case text
  /// VISUAL's operators and keys, read before the text table's motions;
  /// any other key is swallowed.
  case visual
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
/// remainder is `<topic> <action> [--name=value ...]`, parsed against the
/// resident command table (``URLEventHandler/parse(words:)``) and dispatched
/// in-process. Otherwise the array is executed as argv (no shell wrap, just
/// env / `~` expansion on each element).
enum MappingCommand: Hashable {
  case flashCommand(URLCommand)
  case shellCommand([String])
}

/// Build a mapping action from a TOML array.
///
///     ["flash", "mouse", "target"]                    → in-process mouseTarget
///     ["flash", "mouse", "target", "--modifiers=cmd"] → preset Command-click
///     ["flash", "mouse", "grid", "--secondary"]       → in-process mouseGrid (bool flag)
///     ["flash", "app", "open", "--name=Alacritty"]    → in-process openApp
///     ["flash", "screenshot", "window"]               → plugin command
///     ["sh", "-c", "echo hi"]                         → exec sh -c "echo hi"
///     ["~/dotfiles/toggle.sh", "off"]                 → exec the expanded path
///
/// Returns nil when the array is empty, the command is unknown, or required
/// arguments are missing. Every Flash command is `flash <topic> <action>`; a
/// plugin command is `flash <command> <subcommand>`, never one word.
func parseMappingCommand(argv: [String]) -> MappingCommand? {
  guard let first = argv.first else { return nil }
  if mappingCommandHeadNamesFlash(first) {
    let tail = Array(argv.dropFirst())
    // `flash screenshot window` before flag parsing. The tail is the command
    // bar's words, not `--name=value` flags.
    if let git = PluginGitInvocation.command(argvAfterFlash: tail) {
      return .flashCommand(git)
    }
    return URLEventHandler.parse(words: tail).map(MappingCommand.flashCommand)
  }
  return .shellCommand(argv)
}

/// `flash <command> <subcommand> [word ...]`, the same words as
/// `:command subcommand word …`. Both words are required. Nil when the
/// command is one of Flash's topics or not declared, or the subcommand is
/// neither an exact registration nor a `*` wildcard.
enum PluginGitInvocation {
  static func command(argvAfterFlash tail: [String]) -> URLCommand? {
    guard let name = tail.first?.lowercased(), !name.isEmpty,
      !URLEventHandler.isTopic(name),
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

  /// Canonical argv. A Flash command is `["flash", "<topic>", "<action>", ...]`,
  /// including flags the parser filled in. A shell mapping keeps the argv that
  /// was written.
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
