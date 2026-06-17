import Foundation
import TOMLKit

enum ConfigLoader {
  /// Lookup chain for the TOML file path. First existing wins.
  ///   1. `--config=<path>` on the command line
  ///   2. `FLASH_CONFIG` environment variable
  ///   3. `$XDG_CONFIG_HOME/flash/flash.toml`
  ///   4. `~/.config/flash/flash.toml`
  static var defaultPath: URL {
    resolvePath(
      arguments: CommandLine.arguments,
      environment: ProcessInfo.processInfo.environment)
  }

  /// Every candidate path in lookup order. Used by the config-file
  /// watcher: a watcher per path catches both edits to the active
  /// config AND creation of a higher-precedence one (e.g. user adds
  /// `$XDG_CONFIG_HOME/flash/flash.toml` while running with
  /// `~/.config/flash/flash.toml`).
  static func candidatePaths(arguments: [String], environment: [String: String]) -> [URL] {
    for arg in arguments.dropFirst() {
      if arg.hasPrefix("--config=") {
        let p = String(arg.dropFirst("--config=".count))
        if !p.isEmpty {
          return [URL(fileURLWithPath: (p as NSString).expandingTildeInPath)]
        }
      }
    }
    if let p = environment["FLASH_CONFIG"], !p.isEmpty {
      return [URL(fileURLWithPath: (p as NSString).expandingTildeInPath)]
    }
    var out: [URL] = []
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      out.append(
        URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
          .appendingPathComponent("flash/flash.toml"))
    }
    out.append(home.appendingPathComponent(".config/flash/flash.toml"))
    return out
  }

  static func resolvePath(arguments: [String], environment: [String: String]) -> URL {
    let candidates = candidatePaths(arguments: arguments, environment: environment)
    let fm = FileManager.default
    if let existing = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
      return existing
    }
    // Fall back to the canonical xdg-style path when nothing exists
    // yet. `parseFile` handles missing files gracefully.
    return candidates.first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/flash/flash.toml")
  }

  /// Production entry point. Resolves the config path, reads the TOML
  /// file (falling back to defaults if it doesn't exist), then layers
  /// environment-variable overrides and command-line overrides on top.
  /// **Precedence (high → low): CLI flag > env var > TOML > built-in default.**
  static func load() -> Config {
    let args = CommandLine.arguments
    let env = ProcessInfo.processInfo.environment
    let url = resolvePath(arguments: args, environment: env)
    let parsed = parseFile(at: url, environment: env)
    return applyOverrides(to: parsed, arguments: args, environment: env)
  }

  /// Load from a specific path, with the current process's environment
  /// + arguments still applied as overrides. Used by hot-reload (it
  /// already knows the resolved path).
  static func load(from url: URL) -> Config {
    let env = ProcessInfo.processInfo.environment
    let parsed = parseFile(at: url, environment: env)
    return applyOverrides(
      to: parsed,
      arguments: CommandLine.arguments,
      environment: env
    )
  }

  private static func parseFile(at url: URL, environment: [String: String]) -> Config {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else {
      var config = Config.default
      config.prepareDerivedValues()
      return config
    }
    return parse(text, sourceURL: url.resolvingSymlinksInPath(), environment: environment)
  }

  static func parse(
    _ text: String,
    sourceURL: URL? = nil,
    environment: [String: String] = [:]
  ) -> Config {
    var config = Config()
    var pendingModeMappings: [PendingModeMapping] = []
    let locations = ConfigSourceLocationIndex(text: text)

    let root: TOMLTable
    do {
      root = try TOMLTable(string: text)
    } catch let error as TOMLParseError {
      config.addDiagnostic(
        "TOML parse error: \(error.description)",
        location: ConfigLocation(line: error.source.begin.line, column: error.source.begin.column))
      config.prepareDerivedValues()
      return config
    } catch {
      config.addDiagnostic("TOML parse error: \(error)")
      config.prepareDerivedValues()
      return config
    }

    apply(
      root: root,
      locations: locations,
      sourceURL: sourceURL,
      pendingModeMappings: &pendingModeMappings,
      into: &config)
    applyPendingModeMappings(pendingModeMappings, into: &config)
    applyStatusBarTemplate(sourceURL: sourceURL, into: &config)
    config.prepareDerivedValues()
    return config
  }

  private struct ConfigSourceLocationIndex {
    private var locations: [[String]: ConfigLocation] = [:]

    init(text: String) {
      var tablePath: [String] = []
      var inMultilineBasicString = false

      for (offset, linePart) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let lineNumber = offset + 1
        let rawLine = String(linePart)

        if inMultilineBasicString {
          if rawLine.contains("\"\"\"") {
            inMultilineBasicString = false
          }
          continue
        }

        let line = Self.stripLineComment(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        if line.hasPrefix("["),
          let close = line.firstIndex(of: "]")
        {
          let body = String(line[line.index(after: line.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
          tablePath = Self.splitDottedKey(body)
          continue
        }

        guard let equals = Self.firstUnquotedEquals(in: rawLine) else { continue }
        let rawKey = String(rawLine[..<equals]).trimmingCharacters(in: .whitespaces)
        let keyPath = Self.splitDottedKey(rawKey)
        guard !keyPath.isEmpty else { continue }

        if Self.startsMultilineBasicString(after: equals, in: rawLine) {
          inMultilineBasicString = true
        }
        let column = Self.valueColumn(after: equals, in: rawLine)
        locations[tablePath + keyPath] = ConfigLocation(line: lineNumber, column: column)
      }
    }

    func location(for path: [String]) -> ConfigLocation? {
      locations[path]
    }

    private static func stripLineComment(_ raw: String) -> String {
      var result = ""
      var inString = false
      var escaping = false
      var quote: Character?
      for ch in raw {
        if inString {
          result.append(ch)
          if escaping {
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          }
          continue
        }
        if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
          result.append(ch)
          continue
        }
        if ch == "#" { break }
        result.append(ch)
      }
      return result
    }

    private static func firstUnquotedEquals(in raw: String) -> String.Index? {
      var inString = false
      var escaping = false
      var quote: Character?
      var index = raw.startIndex
      while index < raw.endIndex {
        let ch = raw[index]
        if inString {
          if escaping {
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          }
        } else if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
        } else if ch == "=" {
          return index
        }
        index = raw.index(after: index)
      }
      return nil
    }

    private static func valueColumn(after equals: String.Index, in raw: String) -> Int {
      var index = raw.index(after: equals)
      while index < raw.endIndex, raw[index].isWhitespace {
        index = raw.index(after: index)
      }
      return raw.distance(from: raw.startIndex, to: index) + 1
    }

    private static func startsMultilineBasicString(after equals: String.Index, in raw: String)
      -> Bool
    {
      var index = raw.index(after: equals)
      while index < raw.endIndex, raw[index].isWhitespace {
        index = raw.index(after: index)
      }
      guard index < raw.endIndex else { return false }
      return raw[index...].hasPrefix("\"\"\"")
        && raw[index...].dropFirst(3).contains("\"\"\"") == false
    }

    private static func splitDottedKey(_ raw: String) -> [String] {
      var parts: [String] = []
      var current = ""
      var inString = false
      var escaping = false
      var quote: Character?

      func appendCurrent() {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          parts.append(trimmed)
        }
        current = ""
      }

      for ch in raw {
        if inString {
          if escaping {
            current.append(ch)
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          } else {
            current.append(ch)
          }
          continue
        }

        if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
          continue
        }
        if ch == "." {
          appendCurrent()
          continue
        }
        current.append(ch)
      }
      appendCurrent()
      return parts
    }
  }

  private struct PendingModeMapping {
    var scope: ModeScope
    var rawKey: String
    var key: String
    var action: MappingCommand
    var location: ConfigLocation
  }

  private static func apply(
    root: TOMLTable,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    applyHints(root["hints"]?.table, locations: locations, into: &config)
    applyOpen(root["open"]?.table, locations: locations, into: &config)
    applyPlugins(root["plugins"]?.table, locations: locations, sourceURL: sourceURL, into: &config)
    applyPluginSettings(root["plugin"]?.table, locations: locations, into: &config)
    applyStatusBar(root["statusbar"]?.table, locations: locations, into: &config)
    applyFlashlight(root["flashlight"]?.table, locations: locations, into: &config)
    applyMode(
      root["mode"]?.table,
      locations: locations,
      sourceURL: sourceURL,
      pendingModeMappings: &pendingModeMappings,
      into: &config)
    applyOverlay(root["overlay"]?.table, locations: locations, into: &config)
    applyDebug(root["debug"]?.table, locations: locations, into: &config)
  }

  private static func applyHints(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyString(table["keys"], path: ["hints", "keys"], message: "hints.keys must be a quoted string", locations: locations, into: &config) { value, config in
      config.hints.keys = value
    }
    applyInt(table["min_length"], path: ["hints", "min_length"], message: "hints.min_length must be an integer", locations: locations, into: &config) { value, config in
      config.hints.minLength = value
    }
    applyStringArray(table["magic_modifiers"], path: ["hints", "magic_modifiers"], message: "hints.magic_modifiers must be an array of strings", locations: locations, into: &config) { value, config in
      config.hints.magicModifiers = value
    }
    applyInt(table["mouse_grid_steps"], path: ["hints", "mouse_grid_steps"], message: "hints.mouse_grid_steps must be an integer between 2 and 6", locations: locations, into: &config, validate: { (2...6).contains($0) }) { value, config in
      config.hints.mouseGridSteps = value
    }
    applyDouble(table["mouse_grid_opacity"], path: ["hints", "mouse_grid_opacity"], message: "hints.mouse_grid_opacity must be a number between 0.0 and 1.0", locations: locations, into: &config, validate: { (0.0...1.0).contains($0) }) { value, config in
      config.hints.mouseGridOpacity = value
    }
  }

  private static func applyOpen(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyStringArray(table["ignored_apps"], path: ["open", "ignored_apps"], message: "open.ignored_apps must be an array of strings", locations: locations, into: &config) { value, config in
      config.open.ignoredApps = value
    }
  }

  private static func applyPlugins(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(table["watching_enabled"], path: ["plugins", "watching_enabled"], message: "plugins.watching_enabled must be true or false", locations: locations, into: &config) { value, config in
      config.plugins.watchingEnabled = value
    }

    let thirdPartyPath = ["plugins", "third_party"]
    if let value = table["third_party"] {
      let location = locations.location(for: thirdPartyPath)
      guard let parsed = stringArrayValue(value) else {
        config.addDiagnostic(
          "plugins.third_party must be an array of strings",
          location: location)
        return
      }
      var refs: [PluginReference] = []
      var invalid: [String] = []
      for raw in parsed {
        if let ref = PluginReference.parse(raw, sourceURL: sourceURL) {
          refs.append(ref)
        } else {
          invalid.append(raw)
        }
      }
      if invalid.isEmpty {
        config.plugins.thirdParty = refs
        config.recordLocation(path: "plugins.third_party", location: location)
      } else {
        config.addDiagnostic(
          "plugins.third_party entries must be github:user/project or file:<path>: \(invalid.joined(separator: ", "))",
          location: location)
      }
    }
  }

  private static func applyPluginSettings(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    for (pluginID, value) in table {
      guard let settings = value.table, !pluginID.isEmpty else { continue }
      for (key, settingValue) in settings where !key.isEmpty {
        let locationPath = ["plugin", pluginID, key]
        let location = locations.location(for: locationPath)
        guard let parsed = pluginConfigValue(settingValue) else {
          config.addDiagnostic(
            "plugin.\(pluginID).\(key) must be a string, number, boolean, or array of strings",
            location: location)
          continue
        }
        config.plugins.settings[pluginID, default: [:]][key] = parsed
        config.recordLocation(path: "plugin.\(pluginID).\(key)", location: location)
      }
    }
  }

  private static func applyStatusBar(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyString(table["template"], path: ["statusbar", "template"], message: "statusbar.template must be a quoted template string", locations: locations, into: &config) { value, config in
      config.statusBar.template.template = value
    }
  }

  private static func applyFlashlight(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyInt(table["suggestion_count"], path: ["flashlight", "suggestion_count"], message: "flashlight.suggestion_count must be a positive integer", locations: locations, into: &config, validate: { $0 > 0 }) { value, config in
      config.flashlight.suggestionCount = value
    }
    applyInt(table["precedence_alive_bonus"], path: ["flashlight", "precedence_alive_bonus"], message: "flashlight.precedence_alive_bonus must be a non-negative integer", locations: locations, into: &config, validate: { $0 >= 0 }) { value, config in
      config.flashlight.precedenceAliveBonus = value
    }

    if let aliases = table["aliases"]?.table {
      for (key, value) in aliases {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let locationPath = ["flashlight", "aliases", key]
        let location = locations.location(for: locationPath)
        if let parsed = value.string, !parsed.isEmpty, !trimmedKey.isEmpty {
          config.flashlight.aliases[trimmedKey] = parsed
          config.recordLocation(path: "flashlight.aliases.\(trimmedKey)", location: location)
        } else {
          config.addDiagnostic(
            "flashlight.aliases.\(key) must be a non-empty quoted string",
            location: location)
        }
      }
    }

    if let precedence = table["precedence"]?.table {
      for (key, value) in precedence {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        let locationPath = ["flashlight", "precedence", key]
        let location = locations.location(for: locationPath)
        if let parsed = value.int, !trimmedKey.isEmpty {
          config.flashlight.precedence[trimmedKey] = parsed
          config.recordLocation(path: "flashlight.precedence.\(trimmedKey)", location: location)
        } else {
          config.addDiagnostic(
            "flashlight.precedence.\(key) must be an integer",
            location: location)
        }
      }
    }
  }

  private static func applyMode(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    guard let table else { return }

    let labelsPath = ["mode", "labels"]
    if let value = table["labels"] {
      let location = locations.location(for: labelsPath)
      if let parsed = stringTableValue(value),
        let normal = parsed["normal"],
        let insert = parsed["insert"],
        let command = parsed["command"],
        !normal.isEmpty,
        !insert.isEmpty,
        !command.isEmpty
      {
        config.mode.labels = Config.Mode.Labels(
          normal: normal,
          insert: insert,
          command: command)
        config.recordLocation(path: "mode.labels", location: location)
      } else {
        config.addDiagnostic(
          "mode.labels must be { normal = \"...\", insert = \"...\", command = \"...\" }",
          location: location)
      }
    }

    applyInt(table["sequence_timeout_ms"], path: ["mode", "sequence_timeout_ms"], message: "mode.sequence_timeout_ms must be a non-negative integer", locations: locations, into: &config, validate: { $0 >= 0 }) { value, config in
      config.mode.sequenceTimeoutMs = value
    }

    if let normal = table["normal"]?.table {
      applyString(normal["leader"], path: ["mode", "normal", "leader"], message: "mode.normal.leader must be a non-empty quoted string", locations: locations, into: &config, validate: { !$0.isEmpty }) { value, config in
        config.mode.normalLeader = canonicalNormalModeKeyToken(value)
      }
      applyModeMappingTable(
        normal["mappings"]?.table,
        scope: .normal,
        path: ["mode", "normal", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in normal where key != "leader" && key != "mappings" {
        config.addDiagnostic(
          "mode.normal mappings must be declared under [mode.normal.mappings]",
          location: locations.location(for: ["mode", "normal", key]))
      }
    }

    if let all = table["all"]?.table {
      applyModeMappingTable(
        all["mappings"]?.table,
        scope: .all,
        path: ["mode", "all", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)
    }

    if let insert = table["insert"]?.table {
      applyModeMappingTable(
        insert["mappings"]?.table,
        scope: .insert,
        path: ["mode", "insert", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in insert where key != "mappings" {
        config.addDiagnostic(
          "mode.insert mappings must be declared under [mode.insert.mappings]",
          location: locations.location(for: ["mode", "insert", key]))
      }
    }
  }

  private static func applyOverlay(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyDouble(table["font_size"], path: ["overlay", "font_size"], message: "overlay.font_size must be a number", locations: locations, into: &config) { value, config in
      config.overlay.fontSize = value
    }
    applyString(table["hint_fg"], path: ["overlay", "hint_fg"], message: "overlay.hint_fg must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.hintFG = value
    }
    applyString(table["hint_bg_top"], path: ["overlay", "hint_bg_top"], message: "overlay.hint_bg_top must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.hintBGTop = value
    }
    applyString(table["hint_bg_bottom"], path: ["overlay", "hint_bg_bottom"], message: "overlay.hint_bg_bottom must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.hintBGBottom = value
    }
    applyString(table["hint_border"], path: ["overlay", "hint_border"], message: "overlay.hint_border must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.hintBorder = value
    }
    applyString(table["important_hint_fg"], path: ["overlay", "important_hint_fg"], message: "overlay.important_hint_fg must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.importantHintFG = value
    }
    applyString(table["important_hint_bg_top"], path: ["overlay", "important_hint_bg_top"], message: "overlay.important_hint_bg_top must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.importantHintBGTop = value
    }
    applyString(table["important_hint_bg_bottom"], path: ["overlay", "important_hint_bg_bottom"], message: "overlay.important_hint_bg_bottom must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.importantHintBGBottom = value
    }
    applyString(table["important_hint_border"], path: ["overlay", "important_hint_border"], message: "overlay.important_hint_border must be a quoted string", locations: locations, into: &config) { value, config in
      config.overlay.importantHintBorder = value
    }
  }

  private static func applyDebug(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(table["show_hints_bounds"], path: ["debug", "show_hints_bounds"], message: "debug.show_hints_bounds must be true or false", locations: locations, into: &config) { value, config in
      config.debug.showHintsBounds = value
    }
    applyString(table["hints_bounds_bg"], path: ["debug", "hints_bounds_bg"], message: "debug.hints_bounds_bg must be a quoted string", locations: locations, into: &config) { value, config in
      config.debug.hintsBoundsBG = value
    }
    applyString(table["hints_bounds_fg"], path: ["debug", "hints_bounds_fg"], message: "debug.hints_bounds_fg must be a quoted string", locations: locations, into: &config) { value, config in
      config.debug.hintsBoundsFG = value
    }

    let logLevelPath = ["debug", "log_level"]
    if let value = table["log_level"] {
      let location = locations.location(for: logLevelPath)
      if let raw = value.string, let lvl = FlashLog.Level.parse(raw) {
        config.debug.logLevel = lvl
        config.recordLocation(path: "debug.log_level", location: location)
      } else {
        config.addDiagnostic(
          "debug.log_level must be one of: trace, debug, info, warn, error, fatal",
          location: location)
      }
    }

    applyBool(table["http_inspector_enabled"], path: ["debug", "http_inspector_enabled"], message: "debug.http_inspector_enabled must be true or false", locations: locations, into: &config) { value, config in
      config.debug.httpInspectorEnabled = value
    }

    let hostPath = ["debug", "http_inspector_host"]
    if let value = table["http_inspector_host"] {
      let location = locations.location(for: hostPath)
      if let raw = value.string, ["localhost", "127.0.0.1", "::1"].contains(raw) {
        config.debug.httpInspectorHost = raw
        config.recordLocation(path: "debug.http_inspector_host", location: location)
      } else {
        config.addDiagnostic(
          "debug.http_inspector_host must be \"localhost\", \"127.0.0.1\", or \"::1\"",
          location: location)
      }
    }

    applyInt(table["http_inspector_port"], path: ["debug", "http_inspector_port"], message: "debug.http_inspector_port must be an integer in 1..65535", locations: locations, into: &config, validate: { (1...65535).contains($0) }) { value, config in
      config.debug.httpInspectorPort = value
    }
  }

  private static func applyModeMappingTable(
    _ table: TOMLTable?,
    scope: ModeScope,
    path: [String],
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    guard let table else { return }
    for (key, value) in table where !key.isEmpty {
      let location = locations.location(for: path + [key])
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        config.addDiagnostic(
          "mapping \"\(key)\" uses invalid syntax — non-letter/number keys must be wrapped in <name>",
          location: location)
        continue
      }
      if let action = parseMappingValue(value, sourceURL: sourceURL) {
        pendingModeMappings.append(
          PendingModeMapping(
            scope: scope,
            rawKey: key,
            key: canonical,
            action: action,
            location: location ?? ConfigLocation(line: 1, column: 1)))
      } else {
        config.addDiagnostic(
          "mapping \"\(key)\" must be a non-empty string array — `[\"flash\", \"<verb>\", \"k=v\"...]` for in-process verbs or `[<argv>...]` for external commands",
          location: location)
      }
    }
  }

  private static func applyString(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (String) -> Bool = { _ in true },
    assign: (String, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = value.string, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  private static func applyStringArray(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    assign: ([String], inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = stringArrayValue(value) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  private static func applyBool(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    assign: (Bool, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = value.bool else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  private static func applyInt(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (Int) -> Bool = { _ in true },
    assign: (Int, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = value.int, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  private static func applyDouble(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (Double) -> Bool = { _ in true },
    assign: (Double, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    let parsed = value.double ?? value.int.map(Double.init)
    guard let parsed, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  private static func stringArrayValue(_ value: any TOMLValueConvertible) -> [String]? {
    guard let array = value.array else { return nil }
    var result: [String] = []
    for item in array {
      guard let string = item.string else { return nil }
      result.append(string)
    }
    return result
  }

  private static func stringTableValue(_ value: any TOMLValueConvertible) -> [String: String]? {
    guard let table = value.table else { return nil }
    var result: [String: String] = [:]
    for (key, value) in table {
      guard let string = value.string else { return nil }
      result[key] = string
    }
    return result
  }

  private static func pluginConfigValue(_ value: any TOMLValueConvertible) -> PluginConfigValue? {
    if let bool = value.bool { return .bool(bool) }
    if let int = value.int { return .int(int) }
    if let double = value.double { return .double(double) }
    if let array = stringArrayValue(value) { return .stringArray(array) }
    if let string = value.string { return .string(string) }
    return nil
  }

  private static func setModeMapping(
    scope: ModeScope,
    key: String,
    action: MappingCommand,
    into config: inout Config
  ) {
    let mapping = ModeMapping(key: key, action: action)
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
    }
  }

  private static func applyPendingModeMappings(
    _ mappings: [PendingModeMapping],
    into config: inout Config
  ) {
    for mapping in mappings {
      if mapping.key.contains("<leader>"), mapping.scope != .normal {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" uses <leader> outside [mode.normal.mappings]",
          location: mapping.location)
        continue
      }
      guard let key = resolvedMappingKey(mapping.key, scope: mapping.scope, config: config) else {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" uses <leader> but mode.normal.leader is not set",
          location: mapping.location)
        continue
      }
      setModeMapping(scope: mapping.scope, key: key, action: mapping.action, into: &config)
    }
  }

  private static func applyStatusBarTemplate(sourceURL: URL?, into config: inout Config) {
    let normalizedTemplate = FlashStatusBarTemplateEngine.normalizedTemplate(
      config.statusBar.template.template)
    let variables = parseStatusBarTemplateVariables(
      normalizedTemplate,
      path: "template",
      sourceURL: sourceURL,
      into: &config)
    config.statusBar.template = FlashStatusBarTemplate(
      template: normalizedTemplate,
      variables: variables)
  }

  private static func parseStatusBarTemplateVariables(
    _ raw: String,
    path: String,
    sourceURL: URL?,
    into config: inout Config
  ) -> [FlashStatusBarTemplateVariable] {
    var variables: [FlashStatusBarTemplateVariable] = []
    var index = raw.startIndex

    func appendToken(_ token: String, source: FlashStatusBarSource) {
      if variables.contains(where: { $0.token == token }) {
        return
      }
      variables.append(
        FlashStatusBarTemplateVariable(
          id: statusBarVariableID(token),
          token: token,
          source: source))
    }

    while index < raw.endIndex {
      // `##` is a literal `#` per tmux's escape convention — skip both so
      // we don't trip on the second `#` looking like the start of a token.
      if raw[index] == "#",
        let next = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        next < raw.endIndex,
        raw[next] == "#"
      {
        index = raw.index(after: next)
        continue
      }
      if raw[index] == "#",
        let open = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        open < raw.endIndex,
        raw[open] == "{"
      {
        guard let close = raw[open...].firstIndex(of: "}") else {
          config.addDiagnostic(
            "statusbar.\(path) contains an unterminated template variable",
            location: config.valueLocations["statusbar.\(path)"])
          return variables
        }
        let bodyStart = raw.index(after: open)
        let body = String(raw[bodyStart..<close]).trimmed
        // `#{=N:token}` / `#{=-N:token}` truncation operators carry the
        // real token after the `:`. Resolve through the same helper the
        // renderer uses so the two stay in sync.
        let (token, _) = FlashStatusBarTemplateEngine.parseTokenTruncation(body)
        if let source = parseStatusBarTemplateSource(token, sourceURL: sourceURL) {
          appendToken(token, source: source)
        } else {
          config.addDiagnostic(
            "statusbar.\(path) template variable \"\(body)\" must be mode, active_app_name, active_bundle_identifier, date, a tmux variable, plugin:<name>, plugin:<plugin>.<segment>, script:<path>, or command:<shell> (optionally wrapped in #{=N:…} for length-limit)",
            location: config.valueLocations["statusbar.\(path)"])
        }
        index = raw.index(after: close)
        continue
      }
      if raw[index] == "#",
        let aliasIndex = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        aliasIndex < raw.endIndex,
        let token = FlashStatusBarTemplateEngine.tmuxShortFormatToken(for: raw[aliasIndex]),
        let source = parseStatusBarTemplateSource(token, sourceURL: sourceURL)
      {
        appendToken(token, source: source)
        index = raw.index(after: aliasIndex)
        continue
      }
      index = raw.index(after: index)
    }

    return variables
  }

  private static func statusBarVariableID(_ token: String) -> String {
    "statusbar.template.\(token)"
  }

  private static func parseStatusBarTemplateSource(
    _ token: String,
    sourceURL: URL?
  ) -> FlashStatusBarSource? {
    let trimmed = token.trimmed
    guard !trimmed.isEmpty else { return nil }
    switch trimmed {
    case "mode": return .sdk(.modeLabel)
    case "active_app_name": return .sdk(.activeAppName)
    case "active_bundle_identifier": return .sdk(.activeBundleIdentifier)
    case "date": return .sdk(.date)
    default: break
    }

    guard let colon = trimmed.firstIndex(of: ":") else {
      guard FlashStatusBarTemplateEngine.isTmuxFormatVariable(trimmed) else { return nil }
      return .tmux(trimmed)
    }
    let kind = String(trimmed[..<colon]).lowercased()
    let body = String(trimmed[trimmed.index(after: colon)...])
      .trimmed
    guard !body.isEmpty else { return nil }
    switch kind {
    case "plugin":
      switch body {
      case "loaded_count": return .plugin(.loadedCount)
      case "ready_count": return .plugin(.readyCount)
      case "error_count": return .plugin(.errorCount)
      default:
        guard let dot = body.lastIndex(of: ".") else { return nil }
        let pluginID = String(body[..<dot]).trimmed
        let segmentName = String(body[body.index(after: dot)...]).trimmed
        guard !pluginID.isEmpty, !segmentName.isEmpty else { return nil }
        return .plugin(.statusSegment(pluginID: pluginID, name: segmentName))
      }
    case "script":
      // `#{script:path}` runs the script with no args; `#{script:path --foo
      // --bar}` passes the trailing whitespace-separated tokens through as
      // positional argv. Splitting on whitespace is intentionally crude —
      // the templates only pass simple option flags and the user wrote the
      // string by hand.
      let parts = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard let scriptPath = parts.first else { return nil }
      let resolved = resolveCommandArgument(scriptPath, sourceURL: sourceURL)
      let args = Array(parts.dropFirst())
      if args.isEmpty {
        return .command(.script(resolved))
      }
      return .command(.scriptWithArgs(resolved, args: args))
    case "command":
      return .command(.shell(body))
    default:
      return nil
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

  private static func parseMappingValue(
    _ value: any TOMLValueConvertible,
    sourceURL: URL?
  ) -> MappingCommand? {
    // Mappings are *always* arrays of strings. Plain TOML strings are
    // rejected on purpose: the array form is the only way to express both
    // in-process verbs (`["flash", "mouse_target"]`) and external argv
    // (`["sh", "-c", "..."]`) in one shape.
    guard
      let argv = stringArrayValue(value),
      let head = argv.first,
      !head.isEmpty
    else { return nil }
    // External argv: resolve each element (tilde expansion + path search
    // relative to the config file) before handing to the runner. The
    // in-process branch routes through the verb parser instead.
    if head != "flash" {
      let resolved = argv.map { resolveCommandArgument($0, sourceURL: sourceURL) }
      return .shellCommand(resolved)
    }
    return parseMappingCommand(argv: argv)
  }

  private static func resolveCommandArgument(_ value: String, sourceURL: URL?) -> String {
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

  private static func canonicalNormalModeKeyToken(_ value: String) -> String {
    switch value {
    case " ":
      return "space"
    default:
      return value
    }
  }

}
