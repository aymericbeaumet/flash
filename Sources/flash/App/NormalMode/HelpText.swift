import Foundation

/// The configured mappings as rows for the browser help's Mappings page,
/// with the key and action spellings that back them.
extension NormalModeDispatcher {
  private struct MappingRow {
    var scope: String
    var key: String
    var action: String
    var origin: String
    var explanation: String
  }

  /// The configured mappings as structured rows for the inspector's Mappings
  /// page, scope by scope.
  static func mappingsJSON(mode: Config.Mode) -> [[String: String]] {
    (mappingRows(scope: "all", mappings: Config.Mode.resolveMappings(mode.all))
      + mappingRows(scope: "normal", mappings: Config.Mode.resolveMappings(mode.normal))
      + mappingRows(scope: "text", mappings: Config.Mode.resolveMappings(mode.text))
      + mappingRows(scope: "visual", mappings: Config.Mode.resolveMappings(mode.visual))
      + mappingRows(scope: "hold", mappings: Config.Mode.resolveMappings(mode.hold))
      + mappingRows(scope: "hyper", mappings: Config.Mode.resolveMappings(mode.hyper))
      + mappingRows(scope: "insert", mappings: Config.Mode.resolveMappings(mode.insert))
      + mappingRows(scope: "terminal", mappings: mode.effectiveTerminalMappings)
      + mappingRows(scope: "command", mappings: Config.Mode.resolveMappings(mode.command))
      + mode.layers.keys.sorted().flatMap { name in
        // A layer's own keys and its Escape; `[mode.all]`'s are listed once,
        // under `all`.
        mappingRows(
          scope: "layers.\(name)",
          mappings: mode.layerMappings(name).filter { mapping in
            !mode.all.contains { $0.key == mapping.key && $0.action == mapping.action }
          })
      })
      .map {
        [
          "scope": $0.scope, "key": $0.key, "action": $0.action, "origin": $0.origin,
          "explanation": $0.explanation,
        ]
      }
  }

  private static func mappingRows(scope: String, mappings: [ModeMapping]) -> [MappingRow] {
    mappings.map { mapping in
      MappingRow(
        scope: scope,
        key: displayMappingKey(mapping.key),
        action: mapping.action.diagnosticDescription,
        origin: mapping.origin,
        explanation: mapping.action.explanation
      )
    }
  }

  static func displayMappingKey(_ key: String) -> String {
    if key.contains(NormalModeInterpreter.keyAtomSeparator) {
      return displayAtoms(key).joined()
    }
    if let chord = displayModifierChord(key) { return chord }
    return displayAtoms(key).joined()
  }

  private static func displayModifierChord(_ key: String) -> String? {
    let tokens = key.split(separator: "+", omittingEmptySubsequences: false)
    if tokens.count >= 2,
      tokens.dropLast().allSatisfy({ isModifierToken(String($0)) })
    {
      let modifiers = tokens.dropLast().map(String.init).joined(separator: "+")
      let key = displaySingleAtom(String(tokens.last ?? ""))
      return modifiers + "+" + key
    }
    if key.hasPrefix("ctrl-") {
      let suffix = String(key.dropFirst("ctrl-".count))
      return "ctrl-" + displaySingleAtom(suffix)
    }
    return nil
  }

  private static func isModifierToken(_ token: String) -> Bool {
    ["cmd", "command", "ctrl", "control", "shift", "alt", "opt", "option"]
      .contains(token.lowercased())
  }

  private static func displaySingleAtom(_ raw: String) -> String {
    if displayNamedKeyTokens.contains(raw) {
      return "<\(raw)>"
    }
    if raw.count == 1, let ch = raw.first,
      let fullName = NormalModeInterpreter.fullName(forCharacter: ch),
      ["+", "<", ">"].contains(ch)
    {
      return "<\(fullName)>"
    }
    return raw
  }

  private static func displayAtoms(_ key: String) -> [String] {
    if key.contains(NormalModeInterpreter.keyAtomSeparator) {
      return NormalModeInterpreter.keyAtoms(from: key).map(displaySingleAtom)
    }
    var atoms: [String] = []
    var index = key.startIndex
    while index < key.endIndex {
      if let named = displayNamedKeyTokens.first(where: { token in
        key[index...].hasPrefix(token)
      }) {
        atoms.append(displaySingleAtom(named))
        index = key.index(index, offsetBy: named.count)
        continue
      }
      atoms.append(displaySingleAtom(String(key[index])))
      index = key.index(after: index)
    }
    return atoms
  }

  /// Longest first, so `f12` is never read as `f1` then `2`.
  private static let displayNamedKeyTokens =
    namedKeyWords + HotkeySyntax.functionKeyNames.sorted { $0.count > $1.count }

  private static let namedKeyWords = [
    "delete_forward",
    "forward_delete",
    "backspace",
    "pagedown",
    "pageup",
    "delete",
    "escape",
    "return",
    "enter",
    "space",
    "right",
    "down",
    "left",
    "home",
    "end",
    "tab",
    "esc",
    "up",
  ]
}
