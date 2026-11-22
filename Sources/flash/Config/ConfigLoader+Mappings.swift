import FlashCore
import Foundation
import TOMLKit

/// Mapping entries: parsed per layer, then applied once every layer is read.
extension ConfigLoader {
  struct PendingModeMapping {
    var scope: ModeScope
    var bundleID: String?
    /// The `[mode.layers.<name>]` table it belongs to; `scope` is then unused.
    var layer: String?
    var rawKey: String
    var key: String
    var value: ParsedModeMappingValue
    var location: ConfigLocation
    /// The file that defined it, for diagnostics raised after every layer.
    var file: String?
  }

  /// A mapping entry's value: a command, or `false`, which removes the key
  /// from its table.
  enum ParsedModeMappingValue {
    case mapping(MappingCommand, repeatsOnFinalKey: Bool)
    case removal
  }

  enum ModeMappingValueError: Error {
    case invalidShape
    case invalidCommandValue
    case invalidRepeat
    case invalidCommand(String)
    case queryCommand(String)
    case unknownOption(String)

    func message(mappingKey: String) -> String {
      switch self {
      case .invalidShape:
        return
          "mapping \"\(mappingKey)\" must be a non-empty string array, "
          + "{ command = [\"flash\", \"<topic>\", \"<action>\", ...], repeat = true }, "
          + "or false to remove it"
      case .invalidCommandValue:
        return
          "mapping \"\(mappingKey)\".command must be a non-empty string array — "
          + "[\"flash\", \"<topic>\", \"<action>\", ...] or [<argv>...]; write "
          + "\"\(mappingKey)\" = false to remove it"
      case .invalidCommand(let command):
        return "mapping \"\(mappingKey)\": " + URLEventHandler.rejectionMessage(command)
      case .queryCommand(let message):
        return "mapping \"\(mappingKey)\": \(message), not from a mapping"
      case .invalidRepeat:
        return "mapping \"\(mappingKey)\".repeat must be true or false"
      case .unknownOption(let option):
        return
          "mapping \"\(mappingKey)\": unknown option '\(option)' — "
          + "valid options are command and repeat"
      }
    }
  }

  private static func setModeMapping(
    scope: ModeScope,
    key: String,
    action: MappingCommand,
    repeatsOnFinalKey: Bool,
    origin: String,
    into config: inout Config
  ) {
    let mapping = ModeMapping(
      key: key,
      action: action,
      repeatsOnFinalKey: repeatsOnFinalKey,
      origin: origin)
    // Mapping a key a lower layer removed takes it back.
    if let removed = config.mode.unmapped[scope] {
      let remaining = removed.filter {
        $0 != key
          && (mapping.nativeHotkey == nil
            || ModeMapping.parseNativeHotkey($0) != mapping.nativeHotkey)
      }
      config.mode.unmapped[scope] = remaining.isEmpty ? nil : remaining
    }
    switch scope {
    case .all:
      config.mode.all.removeAll { $0.key == key }
      config.mode.all.append(mapping)
    case .normal:
      config.mode.normal.removeAll { $0.key == key }
      config.mode.normal.append(mapping)
    case .insert:
      config.mode.insert.removeAll { $0.key == key }
      config.mode.insert.append(mapping)
    case .terminal:
      config.mode.terminal.removeAll { $0.key == key }
      config.mode.terminal.append(mapping)
    case .command:
      config.mode.command.removeAll { $0.key == key }
      config.mode.command.append(mapping)
    case .hyper:
      config.mode.hyper.removeAll { $0.key == key }
      config.mode.hyper.append(mapping)
    case .hold:
      config.mode.hold.removeAll { $0.key == key }
      config.mode.hold.append(mapping)
    case .text:
      config.mode.text.removeAll { $0.key == key }
      config.mode.text.append(mapping)
    case .visual:
      config.mode.visual.removeAll { $0.key == key }
      config.mode.visual.append(mapping)
    }
  }

  /// `"<key>" = false`: delete the key from its table, including a chord
  /// spelled another way, and remember it so plugin mappings, and derived and
  /// inherited entries (HYPER arrows, HOLD, terminal popups), stay off it.
  private static func removeModeMapping(scope: ModeScope, key: String, into config: inout Config) {
    config.mode.unmapped[scope, default: []].insert(key)
    let chord = ModeMapping.parseNativeHotkey(key)
    let removed: (ModeMapping) -> Bool = { mapping in
      mapping.key == key || (chord != nil && mapping.nativeHotkey == chord)
    }
    switch scope {
    case .all: config.mode.all.removeAll(where: removed)
    case .normal: config.mode.normal.removeAll(where: removed)
    case .insert: config.mode.insert.removeAll(where: removed)
    case .terminal: config.mode.terminal.removeAll(where: removed)
    case .command: config.mode.command.removeAll(where: removed)
    case .hyper: config.mode.hyper.removeAll(where: removed)
    case .hold: config.mode.hold.removeAll(where: removed)
    case .text: config.mode.text.removeAll(where: removed)
    case .visual: config.mode.visual.removeAll(where: removed)
    }
  }

  /// Every layer's entries in layer order, so a later layer's removal or
  /// re-mapping of a key wins.
  static func applyPendingModeMappings(
    _ mappings: [PendingModeMapping],
    into config: inout Config
  ) {
    for mapping in mappings {
      if case .mapping(.flashCommand(.layerMode(let name)), _) = mapping.value,
        config.mode.layers[name] == nil
      {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" enters layer \(name), but no [mode.layers.\(name)] "
            + "declares it",
          location: mapping.location, file: mapping.file)
        continue
      }
      if let layer = mapping.layer {
        applyPendingLayerMapping(mapping, layer: layer, into: &config)
        continue
      }
      if mapping.key.contains("<leader>"), mapping.scope != .normal {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" uses <leader> outside a normal mappings table",
          location: mapping.location, file: mapping.file)
        continue
      }
      guard let key = resolvedMappingKey(mapping.key, scope: mapping.scope, config: config) else {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" uses <leader> but mode.normal.leader is not set",
          location: mapping.location, file: mapping.file)
        continue
      }
      if mapping.scope == .command, ModeMapping.parseNativeHotkey(key) == nil {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" in a command mappings table must be a single modified key",
          location: mapping.location, file: mapping.file)
        continue
      }
      switch mapping.value {
      case .mapping(let action, let repeatsOnFinalKey):
        let origin = ModeMapping.configOrigin(file: mapping.file)
        if let bundleID = mapping.bundleID {
          let entry = ModeMapping(
            key: key, action: action, repeatsOnFinalKey: repeatsOnFinalKey, origin: origin)
          config.mode.appMappings[bundleID, default: .init()].set(entry, in: mapping.scope)
          continue
        }
        setModeMapping(
          scope: mapping.scope,
          key: key,
          action: action,
          repeatsOnFinalKey: repeatsOnFinalKey,
          origin: origin,
          into: &config)
      case .removal:
        if let bundleID = mapping.bundleID {
          config.mode.appMappings[bundleID, default: .init()].remove(key, in: mapping.scope)
          continue
        }
        removeModeMapping(scope: mapping.scope, key: key, into: &config)
      }
    }
  }

  /// A `[mode.layers.<name>.mappings]` entry. `<leader>` is NORMAL's prefix,
  /// so a layer cannot use it; `false` takes a key out of what the layer
  /// inherits (Escape's `mode leave`, an `[mode.all]` chord).
  private static func applyPendingLayerMapping(
    _ mapping: PendingModeMapping, layer: String, into config: inout Config
  ) {
    guard !mapping.key.contains("<leader>") else {
      config.addDiagnostic(
        "mapping \"\(mapping.rawKey)\" uses <leader> outside a normal mappings table",
        location: mapping.location, file: mapping.file)
      return
    }
    switch mapping.value {
    case .mapping(let action, let repeatsOnFinalKey):
      config.mode.layers[layer, default: .init()].set(
        ModeMapping(
          key: mapping.key, action: action, repeatsOnFinalKey: repeatsOnFinalKey,
          origin: ModeMapping.configOrigin(file: mapping.file)))
    case .removal:
      config.mode.layers[layer, default: .init()].remove(mapping.key)
    }
  }

  private static func resolvedMappingKey(
    _ key: String,
    scope: ModeScope,
    config: Config
  ) -> String? {
    guard key.contains("<leader>") else { return key }
    guard scope == .normal, let leaderRaw = config.mode.normalLeader else { return nil }
    guard let leaderInternal = leaderToInternal(leaderRaw) else { return nil }
    return key.replacingOccurrences(of: "<leader>", with: leaderInternal)
  }

  private static func leaderToInternal(_ raw: String) -> String? {
    NormalModeInterpreter.translateLeader(raw)
  }

  static func parseMappingValue(
    _ value: any TOMLValueConvertible,
    sourceURL: URL?
  ) -> Result<ParsedModeMappingValue, ModeMappingValueError> {
    // `false` removes the key; `true` means nothing.
    if let flag = value.bool {
      return flag ? .failure(.invalidShape) : .success(.removal)
    }
    if let table = value.table {
      if let unknown = table.keys.sorted().first(where: { $0 != "command" && $0 != "repeat" }) {
        return .failure(.unknownOption(unknown))
      }
      guard let commandValue = table["command"],
        let action = parseMappingCommandValue(commandValue, sourceURL: sourceURL)
      else {
        if let commandValue = table["command"], let argv = stringArrayValue(commandValue),
          !argv.isEmpty
        {
          return .failure(commandError(argv))
        }
        return .failure(.invalidCommandValue)
      }
      let repeatsOnFinalKey: Bool
      if let repeatValue = table["repeat"] {
        guard let parsed = repeatValue.bool else { return .failure(.invalidRepeat) }
        repeatsOnFinalKey = parsed
      } else {
        repeatsOnFinalKey = false
      }
      return .success(.mapping(action, repeatsOnFinalKey: repeatsOnFinalKey))
    }
    guard let action = parseMappingCommandValue(value, sourceURL: sourceURL) else {
      if let argv = stringArrayValue(value), let head = argv.first, !head.isEmpty {
        return .failure(commandError(argv))
      }
      return .failure(.invalidShape)
    }
    return .success(.mapping(action, repeatsOnFinalKey: false))
  }

  /// Why a non-empty argv did not resolve: a CLI query named as a Flash
  /// command, or an unknown command or invalid arguments.
  private static func commandError(_ argv: [String]) -> ModeMappingValueError {
    if argv.count >= 3, mappingCommandHeadNamesFlash(argv[0]),
      let message = FlashQuery.reservationMessage(topic: argv[1], action: argv[2])
    {
      return .queryCommand(message)
    }
    return .invalidCommand(argv.joined(separator: " "))
  }

  static func parseMappingCommandValue(
    _ value: any TOMLValueConvertible,
    sourceURL: URL?
  ) -> MappingCommand? {
    guard
      let argv = stringArrayValue(value),
      let head = argv.first,
      !head.isEmpty
    else { return nil }
    // Resolve only the executable head before Flash-command classification.
    // Flash command args may legitimately contain slashes (`--input=...`,
    // `--name=/Applications/...`) and must not be path-resolved.
    let resolvedHead = resolveCommandArgument(head, sourceURL: sourceURL)
    return parseMappingCommand(argv: [resolvedHead] + argv.dropFirst())
  }

  static func resolveCommandArgument(_ value: String, sourceURL: URL?) -> String {
    guard value.contains("/"), !value.hasPrefix("/"), !value.hasPrefix("~"),
      let sourceURL
    else {
      return value
    }
    let bases = commandResolutionBases(sourceURL: sourceURL)
    let candidates = bases.map {
      $0.appendingPathComponent(value).standardizedFileURL
    }
    if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      return existing.path
    }
    return candidates.first?.path ?? value
  }

  private static func commandResolutionBases(sourceURL: URL) -> [URL] {
    var bases = [sourceURL.deletingLastPathComponent()]
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dotfilesURL = home.appendingPathComponent(".dotfiles/.config/flash/flash.toml")
    if sameFile(sourceURL, dotfilesURL) {
      bases.append(dotfilesURL.deletingLastPathComponent())
    }
    return bases
  }

  private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    let fm = FileManager.default
    guard
      let lhsAttrs = try? fm.attributesOfItem(atPath: lhs.path),
      let rhsAttrs = try? fm.attributesOfItem(atPath: rhs.path),
      let lhsDevice = lhsAttrs[.systemNumber] as? NSNumber,
      let rhsDevice = rhsAttrs[.systemNumber] as? NSNumber,
      let lhsFile = lhsAttrs[.systemFileNumber] as? NSNumber,
      let rhsFile = rhsAttrs[.systemFileNumber] as? NSNumber
    else {
      return false
    }
    return lhsDevice == rhsDevice && lhsFile == rhsFile
  }

  static func canonicalNormalModeKeyToken(_ value: String) -> String {
    switch value {
    case " ":
      return "space"
    default:
      return value
    }
  }
}
