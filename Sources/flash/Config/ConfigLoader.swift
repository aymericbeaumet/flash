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
      // "flash://mouse_click"` works in [mode.*] tables — modified
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
    config.prepareDerivedValues()
    return config
  }

  private struct PendingModeMapping {
    var scope: ModeScope
    var key: String
    var action: MappingAction
    var location: ConfigLocation
  }

  private struct LogicalLine {
    var lineNumber: Int
    var rawLine: String
  }

  private static func logicalLines(from text: String) -> [LogicalLine] {
    var lines: [LogicalLine] = []
    var collectedLineNumber = 0
    var collectedRaw = ""
    var arrayDepth = 0

    func appendCollectedIfComplete() {
      guard arrayDepth <= 0 else { return }
      lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
      collectedLineNumber = 0
      collectedRaw = ""
      arrayDepth = 0
    }

    for (lineOffset, rawLinePart) in text.split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      let lineNumber = lineOffset + 1
      let rawLine = String(rawLinePart)
      let lineWithoutComment = stripUnquotedComment(rawLine)

      if collectedLineNumber != 0 {
        collectedRaw += "\n" + lineWithoutComment
        arrayDepth += bracketDelta(in: lineWithoutComment)
        appendCollectedIfComplete()
        continue
      }

      guard startsMultilineArray(rawLine: lineWithoutComment) else {
        lines.append(LogicalLine(lineNumber: lineNumber, rawLine: rawLine))
        continue
      }

      collectedLineNumber = lineNumber
      collectedRaw = lineWithoutComment
      arrayDepth = bracketDelta(in: lineWithoutComment)
      appendCollectedIfComplete()
    }

    if collectedLineNumber != 0 {
      lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
    }
    return lines
  }

  private static func startsMultilineArray(rawLine: String) -> Bool {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#"), let eqIdx = line.firstIndex(of: "=") else {
      return false
    }
    line = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("[") else { return false }
    return bracketDelta(in: line) > 0
  }

  private static func stripUnquotedComment(_ line: String) -> String {
    guard let hashIdx = unquotedCommentIndex(in: line) else { return line }
    return String(line[..<hashIdx])
  }

  private static func bracketDelta(in line: String) -> Int {
    var delta = 0
    var inString = false
    var escaped = false

    for c in line {
      if escaped {
        escaped = false
        continue
      }
      if inString, c == "\\" {
        escaped = true
        continue
      }
      if c == "\"" {
        inString.toggle()
        continue
      }
      guard !inString else { continue }
      if c == "[" {
        delta += 1
      } else if c == "]" {
        delta -= 1
      }
    }
    return delta
  }

  private static func unquotedCommentIndex(in line: String) -> String.Index? {
    var inString = false
    var escaped = false
    var i = line.startIndex
    while i < line.endIndex {
      let c = line[i]
      if escaped {
        escaped = false
      } else if inString && c == "\\" {
        escaped = true
      } else if c == "\"" {
        inString.toggle()
      } else if c == "#" && !inString {
        return i
      }
      i = line.index(after: i)
    }
    return nil
  }

  private static func firstNonWhitespaceColumn(in rawLine: String) -> Int {
    guard let idx = rawLine.firstIndex(where: { !$0.isWhitespace }) else { return 1 }
    return columnNumber(in: rawLine, at: idx)
  }

  private static func valueColumn(in rawLine: String) -> Int? {
    guard var idx = rawLine.firstIndex(of: "=") else { return nil }
    idx = rawLine.index(after: idx)
    while idx < rawLine.endIndex, rawLine[idx].isWhitespace {
      idx = rawLine.index(after: idx)
    }
    guard idx < rawLine.endIndex else { return columnNumber(in: rawLine, at: rawLine.endIndex) }
    return columnNumber(in: rawLine, at: idx)
  }

  private static func columnNumber(in rawLine: String, at idx: String.Index) -> Int {
    rawLine.distance(from: rawLine.startIndex, to: idx) + 1
  }

  private static func splitTablePath(_ raw: String) -> [String] {
    var parts: [String] = []
    var buf = ""
    var inString = false
    for c in raw {
      if c == "\"" {
        inString.toggle()
        continue
      }
      if c == "." && !inString {
        parts.append(buf)
        buf = ""
        continue
      }
      buf.append(c)
    }
    if !buf.isEmpty { parts.append(buf) }
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }
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
      let action = parseMappingValue(value, sourceURL: sourceURL)
      if let action {
        pendingModeMappings.append(
          PendingModeMapping(scope: scope, key: key, action: action, location: location))
      } else {
        config.addDiagnostic(
          "mapping \"\(key)\" must be a quoted flash:// action or a non-empty string array command",
          location: location)
      }
      return
    }
    let path = table + [key]
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

    case ["open", "ignored_apps"]:
      if let parsed = parseStringArray(value) {
        config.open.ignoredApps = parsed
        config.recordLocation(path: "open.ignored_apps", location: location)
      } else {
        config.addDiagnostic(
          "open.ignored_apps must be an array of strings",
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

    case ["debug", "show_bounds"]:
      if let parsed = parseBool(value) {
        config.debug.showBounds = parsed
        config.recordLocation(path: "debug.show_bounds", location: location)
      } else {
        config.addDiagnostic("debug.show_bounds must be true or false", location: location)
      }
    case ["debug", "bounds_bg"]:
      if let parsed = parseString(value) {
        config.debug.boundsBG = parsed
        config.recordLocation(path: "debug.bounds_bg", location: location)
      } else {
        config.addDiagnostic("debug.bounds_bg must be a quoted string", location: location)
      }
    case ["debug", "bounds_fg"]:
      if let parsed = parseString(value) {
        config.debug.boundsFG = parsed
        config.recordLocation(path: "debug.bounds_fg", location: location)
      } else {
        config.addDiagnostic("debug.bounds_fg must be a quoted string", location: location)
      }
    case ["debug", "profile"]:
      if let parsed = parseBool(value) {
        config.debug.profile = parsed
        config.recordLocation(path: "debug.profile", location: location)
      } else {
        config.addDiagnostic("debug.profile must be true or false", location: location)
      }
    case ["debug", "slow_ms"]:
      if let parsed = parseInt(value) {
        config.debug.slowMs = parsed
        config.recordLocation(path: "debug.slow_ms", location: location)
      } else {
        config.addDiagnostic("debug.slow_ms must be an integer", location: location)
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
    action: MappingAction,
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
      guard let key = resolvedMappingKey(mapping.key, scope: mapping.scope, config: config) else {
        config.addDiagnostic(
          "mapping \"\(mapping.key)\" uses <leader> but mode.normal.leader is not set",
          location: mapping.location)
        continue
      }
      setModeMapping(scope: mapping.scope, key: key, action: mapping.action, into: &config)
    }
  }

  private static func resolvedMappingKey(
    _ key: String,
    scope: ModeScope,
    config: Config
  ) -> String? {
    guard key.contains("<leader>") else { return key }
    guard scope == .normal, let leader = config.mode.normalLeader else { return nil }
    return key.replacingOccurrences(of: "<leader>", with: leader)
  }

  private static func parseMappingValue(_ value: String, sourceURL: URL?) -> MappingAction? {
    if let raw = parseString(value) {
      return parseMappingAction(rawString: raw)
    }
    if let argv = parseStringArray(value),
      let executable = argv.first,
      !executable.isEmpty
    {
      return .shellCommand(argv.map { resolveCommandArgument($0, sourceURL: sourceURL) })
    }
    return nil
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

  private static func parseString(_ v: String) -> String? {
    guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { return nil }
    return String(v.dropFirst().dropLast())
  }
  private static func parseBool(_ v: String) -> Bool? {
    switch v {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }
  private static func parseInt(_ v: String) -> Int? { Int(v) }
  private static func parseDouble(_ v: String) -> Double? { Double(v) }

  /// Parse a TOML inline table with string values:
  /// `{ normal = "N", insert = "I", command = "C" }`.
  /// This intentionally stays smaller than full TOML: bare keys and
  /// quoted string values only.
  static func parseInlineStringTable(_ v: String) -> [String: String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var result: [String: String] = [:]
    var i = inner.startIndex

    func skipWhitespace() {
      while i < inner.endIndex, inner[i].isWhitespace {
        i = inner.index(after: i)
      }
    }

    while true {
      skipWhitespace()
      if i >= inner.endIndex { break }

      let keyStart = i
      while i < inner.endIndex,
        inner[i].isLetter || inner[i].isNumber || inner[i] == "_" || inner[i] == "-"
      {
        i = inner.index(after: i)
      }
      guard keyStart < i else { return nil }
      let key = String(inner[keyStart..<i])

      skipWhitespace()
      guard i < inner.endIndex, inner[i] == "=" else { return nil }
      i = inner.index(after: i)
      skipWhitespace()

      guard i < inner.endIndex, inner[i] == "\"" else { return nil }
      i = inner.index(after: i)
      var value = ""
      while i < inner.endIndex, inner[i] != "\"" {
        if inner[i] == "\\", inner.index(after: i) < inner.endIndex {
          i = inner.index(after: i)
          value.append(inner[i])
        } else {
          value.append(inner[i])
        }
        i = inner.index(after: i)
      }
      guard i < inner.endIndex else { return nil }
      i = inner.index(after: i)
      result[key] = value

      skipWhitespace()
      if i >= inner.endIndex { break }
      guard inner[i] == "," else { return nil }
      i = inner.index(after: i)
    }
    return result
  }

  /// Parse a TOML inline array of strings: `["a", "b", "c"]`.
  /// Returns nil when the input doesn't look like an array. Handles
  /// quoted strings with `\"` and `\\` escapes; rejects malformed
  /// input (unterminated quote, stray garbage) by returning nil.
  static func parseStringArray(_ v: String) -> [String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var out: [String] = []
    var i = inner.startIndex
    while i < inner.endIndex {
      // Skip whitespace + element separators.
      while i < inner.endIndex,
        inner[i].isWhitespace || inner[i] == ","
      {
        i = inner.index(after: i)
      }
      if i >= inner.endIndex { break }
      guard inner[i] == "\"" else { return nil }
      i = inner.index(after: i)
      var current = ""
      while i < inner.endIndex, inner[i] != "\"" {
        if inner[i] == "\\", inner.index(after: i) < inner.endIndex {
          i = inner.index(after: i)
          current.append(inner[i])
        } else {
          current.append(inner[i])
        }
        i = inner.index(after: i)
      }
      guard i < inner.endIndex else { return nil }  // unterminated
      out.append(current)
      i = inner.index(after: i)
    }
    return out
  }

  // MARK: CLI + env overrides
  //
  // Scalar config keys are exposed via:
  //   - a TOML key (`section.key`, e.g. `hints.min_length`)
  //   - an environment variable (`FLASH_<SECTION>_<KEY>`, e.g.
  //     `FLASH_HINTS_MIN_LENGTH`)
  //   - a command-line flag (`--<section>-<key>=<value>`, e.g.
  //     `--hints-min-length=2`)
  //
  // Precedence is CLI > env > TOML > built-in default. The hot-reload
  // path re-applies env + CLI on every reload, so the overrides stay in
  // effect across `flash.toml` edits.
  //
  // Mode mapping tables are TOML-only because their keys are arbitrary
  // keystroke strings. When you add a new scalar field, add it to the
  // override switch below and cover it in ConfigLoaderTests.

  /// Override flag prefix recognised by the CLI parser.
  static let cliPrefix = "--"
  /// Environment variable prefix recognised by the env parser.
  static let envPrefix = "FLASH_"

  /// Layer env + CLI overrides on top of `config`. The override knobs
  /// are keyed in dash form (`hints-min-length`, `overlay-font-size`, …);
  /// `applyEnv` translates `FLASH_HINTS_MIN_LENGTH` →
  /// `hints-min-length` before calling `applyOverride`.
  static func applyOverrides(
    to config: Config,
    arguments: [String],
    environment: [String: String]
  ) -> Config {
    var result = config
    applyEnv(env: environment, into: &result)
    applyCLI(args: arguments, into: &result)
    result.prepareDerivedValues()
    return result
  }

  private static func applyEnv(env: [String: String], into config: inout Config) {
    for (rawKey, rawVal) in env where rawKey.hasPrefix(envPrefix) {
      let key = String(rawKey.dropFirst(envPrefix.count))
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
      applyOverride(key: key, value: rawVal, into: &config)
    }
  }

  private static func applyCLI(args: [String], into config: inout Config) {
    for arg in args.dropFirst() {
      guard arg.hasPrefix(cliPrefix) else { continue }
      let body = String(arg.dropFirst(cliPrefix.count))
      guard let eq = body.firstIndex(of: "=") else { continue }
      let key = String(body[..<eq])
      let value = String(body[body.index(after: eq)...])
      applyOverride(key: key, value: value, into: &config)
    }
  }

  /// The single source of truth for what `--<key>=<value>` means.
  /// Values arrive as raw strings (no TOML quoting); int/double/bool
  /// fields parse the value with the standard initialisers and silently
  /// drop malformed input — matching the TOML loader's behaviour.
  private static func applyOverride(key: String, value: String, into config: inout Config) {
    switch key {
    case "hints-keys":
      config.hints.keys = value
      config.clearLocation(path: "hints.keys")
    case "hints-min-length":
      if let i = Int(value) {
        config.hints.minLength = i
        config.clearLocation(path: "hints.min_length")
      }
    case "hints-magic-modifiers":
      if let values = parseOverrideStringArray(value) {
        config.hints.magicModifiers = values
        config.clearLocation(path: "hints.magic_modifiers")
        if !values.contains(where: { $0.lowercased() == "shift" }) {
          config.removeDiagnostics {
            $0.hasPrefix(Config.ambiguousShiftMagicModifierWarningPrefix)
          }
        }
      }

    case "open-ignored-apps":
      if let values = parseOverrideStringArray(value) {
        config.open.ignoredApps = values
        config.clearLocation(path: "open.ignored_apps")
      }

    case "overlay-font-size":
      if let d = Double(value) {
        config.overlay.fontSize = d
        config.clearLocation(path: "overlay.font_size")
      }
    case "overlay-hint-fg":
      config.overlay.hintFG = value
      config.clearLocation(path: "overlay.hint_fg")
    case "overlay-hint-bg-top":
      config.overlay.hintBGTop = value
      config.clearLocation(path: "overlay.hint_bg_top")
    case "overlay-hint-bg-bottom":
      config.overlay.hintBGBottom = value
      config.clearLocation(path: "overlay.hint_bg_bottom")
    case "overlay-hint-border":
      config.overlay.hintBorder = value
      config.clearLocation(path: "overlay.hint_border")

    case "debug-show-bounds":
      if let b = boolFromString(value) {
        config.debug.showBounds = b
        config.clearLocation(path: "debug.show_bounds")
      }
    case "debug-bounds-bg":
      config.debug.boundsBG = value
      config.clearLocation(path: "debug.bounds_bg")
    case "debug-bounds-fg":
      config.debug.boundsFG = value
      config.clearLocation(path: "debug.bounds_fg")
    case "debug-profile":
      if let b = boolFromString(value) {
        config.debug.profile = b
        config.clearLocation(path: "debug.profile")
      }
    case "debug-slow-ms":
      if let i = Int(value) {
        config.debug.slowMs = i
        config.clearLocation(path: "debug.slow_ms")
      }
    case "debug-log-level":
      if let lvl = FlashLog.Level.parse(value) {
        config.debug.logLevel = lvl
        config.clearLocation(path: "debug.log_level")
      }

    // `--config=` is consumed by `resolvePath`; ignore here so it
    // doesn't show up as an unknown key.
    case "config":
      break

    default:
      break
    }
  }

  private static func boolFromString(_ v: String) -> Bool? {
    switch v.lowercased() {
    case "true", "1", "yes", "on": return true
    case "false", "0", "no", "off": return false
    default: return nil
    }
  }

  private static func parseOverrideStringArray(_ v: String) -> [String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return [] }
    if let values = parseStringArray(trimmed) {
      return values
    }
    return trimmed.split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
