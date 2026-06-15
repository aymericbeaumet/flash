import Foundation

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
    var currentTable: [String] = []
    var pendingModeMappings: [PendingModeMapping] = []

    for logicalLine in logicalLines(from: text) {
      let lineNumber = logicalLine.lineNumber
      let rawLine = logicalLine.rawLine
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let hashIdx = unquotedCommentIndex(in: line) {
        line = String(line[..<hashIdx]).trimmingCharacters(in: .whitespaces)
      }
      if line.hasPrefix("[") {
        guard line.hasSuffix("]") else {
          config.addDiagnostic(
            "malformed table header",
            location: ConfigLocation(
              line: lineNumber,
              column: firstNonWhitespaceColumn(in: rawLine)))
          continue
        }
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        currentTable = splitTablePath(inner)
        continue
      }
      guard let eqIdx = line.firstIndex(of: "=") else {
        config.addDiagnostic(
          "expected key = value",
          location: ConfigLocation(
            line: lineNumber,
            column: firstNonWhitespaceColumn(in: rawLine)))
        continue
      }
      var key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
      let val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
      let location = ConfigLocation(
        line: lineNumber,
        column: valueColumn(in: rawLine) ?? firstNonWhitespaceColumn(in: rawLine))
      // Allow quoted keys (TOML spec) so `"cmd+ctrl+a" =
      // ["flash", "mouse_target"]` works in [mode.*] tables — modified
      // mapping keys contain `+`, which is not a valid bare TOML key.
      if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
        key = String(key.dropFirst().dropLast())
      }
      apply(
        table: currentTable,
        key: key,
        value: val,
        location: location,
        sourceURL: sourceURL,
        environment: environment,
        pendingModeMappings: &pendingModeMappings,
        into: &config)
    }
    applyPendingModeMappings(pendingModeMappings, into: &config)
    applyStatusBarTemplate(sourceURL: sourceURL, into: &config)
    config.prepareDerivedValues()
    return config
  }

  private struct PendingModeMapping {
    var scope: ModeScope
    var key: String
    var action: MappingCommand
    var location: ConfigLocation
  }

  private static func apply(
    table: [String],
    key: String,
    value: String,
    location: ConfigLocation,
    sourceURL: URL?,
    environment: [String: String],
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    if table.count == 3, table[0] == "mode", table[2] == "mappings",
      let scope = ModeScope(rawValue: table[1]),
      !key.isEmpty
    {
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        config.addDiagnostic(
          "mapping \"\(key)\" uses invalid syntax — non-letter/number keys must be wrapped in <name>",
          location: location)
        return
      }
      let action = parseMappingValue(value, sourceURL: sourceURL)
      if let action {
        pendingModeMappings.append(
          PendingModeMapping(
            scope: scope, key: canonical, action: action, location: location))
      } else {
        config.addDiagnostic(
          "mapping \"\(key)\" must be a non-empty string array — `[\"flash\", \"<verb>\", \"k=v\"...]` for in-process verbs or `[<argv>...]` for external commands",
          location: location)
      }
      return
    }
    // `[plugin.<id>]` — arbitrary user settings handed to the plugin as
    // JSON. The value type is inferred (bool / int / double / string array
    // / string) so a plugin sees naturally-typed JSON.
    if table.count == 2, table[0] == "plugin", !table[1].isEmpty, !key.isEmpty {
      let pluginID = table[1]
      let parsed = parsePluginConfigValue(value)
      guard let parsed else {
        config.addDiagnostic(
          "plugin.\(pluginID).\(key) must be a string, number, boolean, or array of strings",
          location: location)
        return
      }
      config.plugins.settings[pluginID, default: [:]][key] = parsed
      config.recordLocation(path: "plugin.\(pluginID).\(key)", location: location)
      return
    }
    let path = table + [key]
    if table == ["flashlight", "precedence"] {
      // `[flashlight.precedence]` is a literal source-pattern → weight
      // map. Keys are source labels (or parent prefixes — `firefox`
      // covers `firefox.tabs`/`firefox.bookmarks`). Higher weight =
      // ranks earlier as the score-tie tiebreaker. Negative weights
      // demote a source below the implicit `0` everything else gets.
      let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
      if let parsed = parseInt(value), !trimmedKey.isEmpty {
        config.flashlight.precedence[trimmedKey] = parsed
        config.recordLocation(
          path: "flashlight.precedence.\(trimmedKey)", location: location)
      } else {
        config.addDiagnostic(
          "flashlight.precedence.\(key) must be an integer",
          location: location)
      }
      return
    }
    if table == ["flashlight", "aliases"] {
      // `[flashlight.aliases]` is a literal-word substitution table.
      // The key is the exact token the user types (`!g`, `@ft`, or a
      // bare word) — any sigil is part of the key, not implicit. The
      // value is the literal replacement. Keys with TOML special
      // characters need to be quoted: `"!g" = "!google"`. Both sides
      // must be non-empty.
      let trimmedKey = key.trimmingCharacters(in: .whitespaces)
      if let parsed = parseString(value), !parsed.isEmpty, !trimmedKey.isEmpty {
        config.flashlight.aliases[trimmedKey] = parsed
        config.recordLocation(
          path: "flashlight.aliases.\(trimmedKey)", location: location)
      } else {
        config.addDiagnostic(
          "flashlight.aliases.\(key) must be a non-empty quoted string",
          location: location)
      }
      return
    }
    switch path {
    case ["hints", "keys"]:
      if let parsed = parseString(value) {
        config.hints.keys = parsed
        config.recordLocation(path: "hints.keys", location: location)
      } else {
        config.addDiagnostic("hints.keys must be a quoted string", location: location)
      }
    case ["hints", "min_length"]:
      if let parsed = parseInt(value) {
        config.hints.minLength = parsed
        config.recordLocation(path: "hints.min_length", location: location)
      } else {
        config.addDiagnostic("hints.min_length must be an integer", location: location)
      }
    case ["hints", "magic_modifiers"]:
      if let parsed = parseStringArray(value) {
        config.hints.magicModifiers = parsed
        config.recordLocation(path: "hints.magic_modifiers", location: location)
      } else {
        config.addDiagnostic(
          "hints.magic_modifiers must be an array of strings",
          location: location)
      }
    case ["hints", "mouse_grid_steps"]:
      if let parsed = parseInt(value), parsed >= 2, parsed <= 6 {
        config.hints.mouseGridSteps = parsed
        config.recordLocation(path: "hints.mouse_grid_steps", location: location)
      } else {
        config.addDiagnostic(
          "hints.mouse_grid_steps must be an integer between 2 and 6",
          location: location)
      }
    case ["hints", "mouse_grid_opacity"]:
      if let parsed = parseDouble(value), parsed >= 0.0, parsed <= 1.0 {
        config.hints.mouseGridOpacity = parsed
        config.recordLocation(path: "hints.mouse_grid_opacity", location: location)
      } else {
        config.addDiagnostic(
          "hints.mouse_grid_opacity must be a number between 0.0 and 1.0",
          location: location)
      }

    case ["open", "ignored_apps"]:
      if let parsed = parseStringArray(value) {
        config.open.ignoredApps = parsed
        config.recordLocation(path: "open.ignored_apps", location: location)
      } else {
        config.addDiagnostic(
          "open.ignored_apps must be an array of strings",
          location: location)
      }

    case ["plugins", "watching_enabled"]:
      if let parsed = parseBool(value) {
        config.plugins.watchingEnabled = parsed
        config.recordLocation(path: "plugins.watching_enabled", location: location)
      } else {
        config.addDiagnostic(
          "plugins.watching_enabled must be true or false", location: location)
      }

    case ["plugins", "third_party"]:
      if let parsed = parseStringArray(value) {
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
      } else {
        config.addDiagnostic(
          "plugins.third_party must be an array of strings",
          location: location)
      }

    case ["statusbar", "template"]:
      if let parsed = parseString(value) {
        config.statusBar.template.template = parsed
        config.recordLocation(path: "statusbar.template", location: location)
      } else {
        config.addDiagnostic(
          "statusbar.template must be a quoted template string",
          location: location)
      }

    case ["mode", "labels"]:
      if let parsed = parseInlineStringTable(value),
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

    case ["mode", "normal", "leader"]:
      if let parsed = parseString(value), !parsed.isEmpty {
        config.mode.normalLeader = canonicalNormalModeKeyToken(parsed)
        config.recordLocation(path: "mode.normal.leader", location: location)
      } else {
        config.addDiagnostic(
          "mode.normal.leader must be a non-empty quoted string",
          location: location)
      }

    case ["mode", "sequence_timeout_ms"]:
      if let parsed = parseInt(value), parsed >= 0 {
        config.mode.sequenceTimeoutMs = parsed
        config.recordLocation(path: "mode.sequence_timeout_ms", location: location)
      } else {
        config.addDiagnostic(
          "mode.sequence_timeout_ms must be a non-negative integer",
          location: location)
      }

    case ["overlay", "font_size"]:
      if let parsed = parseDouble(value) {
        config.overlay.fontSize = parsed
        config.recordLocation(path: "overlay.font_size", location: location)
      } else {
        config.addDiagnostic("overlay.font_size must be a number", location: location)
      }
    case ["overlay", "hint_fg"]:
      if let parsed = parseString(value) {
        config.overlay.hintFG = parsed
        config.recordLocation(path: "overlay.hint_fg", location: location)
      } else {
        config.addDiagnostic("overlay.hint_fg must be a quoted string", location: location)
      }
    case ["overlay", "hint_bg_top"]:
      if let parsed = parseString(value) {
        config.overlay.hintBGTop = parsed
        config.recordLocation(path: "overlay.hint_bg_top", location: location)
      } else {
        config.addDiagnostic("overlay.hint_bg_top must be a quoted string", location: location)
      }
    case ["overlay", "hint_bg_bottom"]:
      if let parsed = parseString(value) {
        config.overlay.hintBGBottom = parsed
        config.recordLocation(path: "overlay.hint_bg_bottom", location: location)
      } else {
        config.addDiagnostic(
          "overlay.hint_bg_bottom must be a quoted string",
          location: location)
      }
    case ["overlay", "hint_border"]:
      if let parsed = parseString(value) {
        config.overlay.hintBorder = parsed
        config.recordLocation(path: "overlay.hint_border", location: location)
      } else {
        config.addDiagnostic("overlay.hint_border must be a quoted string", location: location)
      }
    case ["overlay", "important_hint_fg"]:
      if let parsed = parseString(value) {
        config.overlay.importantHintFG = parsed
        config.recordLocation(path: "overlay.important_hint_fg", location: location)
      } else {
        config.addDiagnostic(
          "overlay.important_hint_fg must be a quoted string", location: location)
      }
    case ["overlay", "important_hint_bg_top"]:
      if let parsed = parseString(value) {
        config.overlay.importantHintBGTop = parsed
        config.recordLocation(path: "overlay.important_hint_bg_top", location: location)
      } else {
        config.addDiagnostic(
          "overlay.important_hint_bg_top must be a quoted string", location: location)
      }
    case ["overlay", "important_hint_bg_bottom"]:
      if let parsed = parseString(value) {
        config.overlay.importantHintBGBottom = parsed
        config.recordLocation(path: "overlay.important_hint_bg_bottom", location: location)
      } else {
        config.addDiagnostic(
          "overlay.important_hint_bg_bottom must be a quoted string", location: location)
      }
    case ["overlay", "important_hint_border"]:
      if let parsed = parseString(value) {
        config.overlay.importantHintBorder = parsed
        config.recordLocation(path: "overlay.important_hint_border", location: location)
      } else {
        config.addDiagnostic(
          "overlay.important_hint_border must be a quoted string", location: location)
      }

    case ["flashlight", "suggestion_count"]:
      if let parsed = parseInt(value), parsed > 0 {
        config.flashlight.suggestionCount = parsed
        config.recordLocation(
          path: "flashlight.suggestion_count", location: location)
      } else {
        config.addDiagnostic(
          "flashlight.suggestion_count must be a positive integer",
          location: location)
      }

    case ["flashlight", "precedence_alive_bonus"]:
      if let parsed = parseInt(value), parsed >= 0 {
        config.flashlight.precedenceAliveBonus = parsed
        config.recordLocation(
          path: "flashlight.precedence_alive_bonus", location: location)
      } else {
        config.addDiagnostic(
          "flashlight.precedence_alive_bonus must be a non-negative integer",
          location: location)
      }

    case ["debug", "show_hints_bounds"]:
      if let parsed = parseBool(value) {
        config.debug.showHintsBounds = parsed
        config.recordLocation(path: "debug.show_hints_bounds", location: location)
      } else {
        config.addDiagnostic("debug.show_hints_bounds must be true or false", location: location)
      }
    case ["debug", "hints_bounds_bg"]:
      if let parsed = parseString(value) {
        config.debug.hintsBoundsBG = parsed
        config.recordLocation(path: "debug.hints_bounds_bg", location: location)
      } else {
        config.addDiagnostic("debug.hints_bounds_bg must be a quoted string", location: location)
      }
    case ["debug", "hints_bounds_fg"]:
      if let parsed = parseString(value) {
        config.debug.hintsBoundsFG = parsed
        config.recordLocation(path: "debug.hints_bounds_fg", location: location)
      } else {
        config.addDiagnostic("debug.hints_bounds_fg must be a quoted string", location: location)
      }
    case ["debug", "log_level"]:
      if let raw = parseString(value), let lvl = FlashLog.Level.parse(raw) {
        config.debug.logLevel = lvl
        config.recordLocation(path: "debug.log_level", location: location)
      } else {
        config.addDiagnostic(
          "debug.log_level must be one of: trace, debug, info, warn, error, fatal",
          location: location)
      }
    case ["debug", "http_inspector_enabled"]:
      if let parsed = parseBool(value) {
        config.debug.httpInspectorEnabled = parsed
        config.recordLocation(path: "debug.http_inspector_enabled", location: location)
      } else {
        config.addDiagnostic(
          "debug.http_inspector_enabled must be true or false", location: location)
      }
    case ["debug", "http_inspector_host"]:
      if let raw = parseInspectorHost(value), !raw.isEmpty {
        config.debug.httpInspectorHost = raw
        config.recordLocation(path: "debug.http_inspector_host", location: location)
      } else {
        config.addDiagnostic(
          "debug.http_inspector_host must be \"localhost\", \"127.0.0.1\", or \"::1\"",
          location: location)
      }
    case ["debug", "http_inspector_port"]:
      if let parsed = parseInt(value), (1...65535).contains(parsed) {
        config.debug.httpInspectorPort = parsed
        config.recordLocation(path: "debug.http_inspector_port", location: location)
      } else {
        config.addDiagnostic(
          "debug.http_inspector_port must be an integer in 1..65535", location: location)
      }

    default:
      if table.count == 2, table[0] == "mode", ModeScope(rawValue: table[1]) != nil {
        config.addDiagnostic(
          "mode.\(table[1]) mappings must be declared under [mode.\(table[1]).mappings]",
          location: location)
      }
      break
    }
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
          "mapping \"\(mapping.key)\" uses <leader> outside [mode.normal.mappings]",
          location: mapping.location)
        continue
      }
      guard let key = resolvedMappingKey(mapping.key, scope: mapping.scope, config: config) else {
        config.addDiagnostic(
          "mapping \"\(mapping.key)\" uses <leader> but mode.normal.leader is not set",
          location: mapping.location)
        continue
      }
      setModeMapping(scope: mapping.scope, key: key, action: mapping.action, into: &config)
    }
  }

  private static func applyStatusBarTemplate(sourceURL: URL?, into config: inout Config) {
    let variables = parseStatusBarTemplateVariables(
      config.statusBar.template.template,
      path: "template",
      sourceURL: sourceURL,
      into: &config)
    config.statusBar.template = FlashStatusBarTemplate(
      template: config.statusBar.template.template,
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
          variables.append(
            FlashStatusBarTemplateVariable(
              id: statusBarVariableID(token),
              token: token,
              source: source))
        } else {
          config.addDiagnostic(
            "statusbar.\(path) template variable \"\(body)\" must be mode, active_app_name, active_bundle_identifier, date, plugin:<name>, script:<path>, or command:<shell> (optionally wrapped in #{=N:…} for length-limit)",
            location: config.valueLocations["statusbar.\(path)"])
        }
        index = raw.index(after: close)
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

    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
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
      default: return nil
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

  private static func parseMappingValue(_ value: String, sourceURL: URL?) -> MappingCommand? {
    // Mappings are *always* arrays of strings. Plain TOML strings are
    // rejected on purpose: the array form is the only way to express both
    // in-process verbs (`["flash", "mouse_target"]`) and external argv
    // (`["sh", "-c", "..."]`) in one shape.
    guard
      let argv = parseStringArray(value),
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
