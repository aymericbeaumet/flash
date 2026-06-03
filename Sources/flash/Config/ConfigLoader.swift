import Foundation

enum ConfigLoader {
  /// Default lookup chain for the TOML file path:
  ///   1. `--config=<path>` on the command line
  ///   2. `FLASH_CONFIG` environment variable
  ///   3. `$XDG_CONFIG_HOME/flash/config.toml`
  ///   4. `~/.config/flash/config.toml`
  static var defaultPath: URL {
    resolvePath(
      arguments: CommandLine.arguments,
      environment: ProcessInfo.processInfo.environment)
  }

  static func resolvePath(arguments: [String], environment: [String: String]) -> URL {
    for arg in arguments.dropFirst() {
      if arg.hasPrefix("--config=") {
        let p = String(arg.dropFirst("--config=".count))
        if !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
      }
    }
    if let p = environment["FLASH_CONFIG"], !p.isEmpty {
      return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let xdg = environment["XDG_CONFIG_HOME"]
    let base = xdg.flatMap { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
    return base.appendingPathComponent("flash/config.toml")
  }

  /// Production entry point. Resolves the config path, reads the TOML
  /// file (falling back to defaults if it doesn't exist), then layers
  /// environment-variable overrides and command-line overrides on top.
  /// **Precedence (high → low): CLI flag > env var > TOML > built-in default.**
  static func load() -> Config {
    let args = CommandLine.arguments
    let env = ProcessInfo.processInfo.environment
    let url = resolvePath(arguments: args, environment: env)
    let parsed = parseFile(at: url)
    return applyOverrides(to: parsed, arguments: args, environment: env)
  }

  /// Back-compat entry — load from a specific path, with the current
  /// process's environment + arguments still applied as overrides. Used
  /// by hot-reload (it already knows the resolved path).
  static func load(from url: URL) -> Config {
    let parsed = parseFile(at: url)
    return applyOverrides(
      to: parsed,
      arguments: CommandLine.arguments,
      environment: ProcessInfo.processInfo.environment
    )
  }

  private static func parseFile(at url: URL) -> Config {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else {
      return .default
    }
    return parse(text)
  }

  static func parse(_ text: String) -> Config {
    var config = Config()
    var currentTable: [String] = []

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let hashIdx = unquotedCommentIndex(in: line) {
        line = String(line[..<hashIdx]).trimmingCharacters(in: .whitespaces)
      }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        currentTable = splitTablePath(inner)
        continue
      }
      guard let eqIdx = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
      let val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
      apply(table: currentTable, key: key, value: val, into: &config)
    }
    return config
  }

  private static func unquotedCommentIndex(in line: String) -> String.Index? {
    var inString = false
    var i = line.startIndex
    while i < line.endIndex {
      let c = line[i]
      if c == "\"" { inString.toggle() } else if c == "#" && !inString { return i }
      i = line.index(after: i)
    }
    return nil
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

  private static func apply(table: [String], key: String, value: String, into config: inout Config)
  {
    let path = table + [key]
    switch path {
    case ["hints", "keys"]:
      config.hints.keys = parseString(value) ?? config.hints.keys
    case ["hints", "min_length"]:
      config.hints.minLength = parseInt(value) ?? config.hints.minLength

    case ["overlay", "font_size"]:
      config.overlay.fontSize = parseDouble(value) ?? config.overlay.fontSize
    case ["overlay", "hint_fg"]:
      config.overlay.hintFG = parseString(value) ?? config.overlay.hintFG
    case ["overlay", "hint_bg_top"]:
      config.overlay.hintBGTop = parseString(value) ?? config.overlay.hintBGTop
    case ["overlay", "hint_bg_bottom"]:
      config.overlay.hintBGBottom = parseString(value) ?? config.overlay.hintBGBottom
    case ["overlay", "hint_border"]:
      config.overlay.hintBorder = parseString(value) ?? config.overlay.hintBorder

    case ["debug", "show_bounds"]:
      config.debug.showBounds = parseBool(value) ?? config.debug.showBounds
    case ["debug", "bounds_bg"]:
      config.debug.boundsBG = parseString(value) ?? config.debug.boundsBG
    case ["debug", "bounds_fg"]:
      config.debug.boundsFG = parseString(value) ?? config.debug.boundsFG
    case ["debug", "profile"]:
      config.debug.profile = parseBool(value) ?? config.debug.profile
    case ["debug", "slow_ms"]:
      config.debug.slowMs = parseInt(value) ?? config.debug.slowMs
    case ["debug", "dump_ax"]:
      config.debug.dumpAx = parseBool(value) ?? config.debug.dumpAx
    case ["debug", "dump_logs"]:
      config.debug.dumpLogs = parseBool(value) ?? config.debug.dumpLogs

    default:
      break
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

  // MARK: CLI + env overrides
  //
  // Every key in `Config` is exposed via:
  //   - a TOML key (`section.key`, e.g. `hints.scope`)
  //   - an environment variable (`FLASH_<SECTION>_<KEY>`, e.g.
  //     `FLASH_HINTS_SCOPE`)
  //   - a command-line flag (`--<section>-<key>=<value>`, e.g.
  //     `--hints-scope=everywhere`)
  //
  // Precedence is CLI > env > TOML > built-in default. The hot-reload
  // path re-applies env + CLI on every reload, so the overrides stay in
  // effect across `config.toml` edits.
  //
  // **When you add a new field to `Config`, you MUST also add it to the
  // override switch below and to the `--help` table.** This is a hard
  // rule documented in AGENTS.md.

  /// Override flag prefix recognised by the CLI parser.
  static let cliPrefix = "--"
  /// Environment variable prefix recognised by the env parser.
  static let envPrefix = "FLASH_"

  /// Layer env + CLI overrides on top of `config`. The override knobs
  /// are keyed in dash form (`hints-scope`, `overlay-font-size`, …);
  /// `applyEnv` translates `FLASH_HINTS_SCOPE` → `hints-scope` before
  /// calling `applyOverride`.
  static func applyOverrides(
    to config: Config,
    arguments: [String],
    environment: [String: String]
  ) -> Config {
    var result = config
    applyEnv(env: environment, into: &result)
    applyCLI(args: arguments, into: &result)
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
    case "hints-min-length":
      if let i = Int(value) { config.hints.minLength = i }

    case "overlay-font-size":
      if let d = Double(value) { config.overlay.fontSize = d }
    case "overlay-hint-fg":
      config.overlay.hintFG = value
    case "overlay-hint-bg-top":
      config.overlay.hintBGTop = value
    case "overlay-hint-bg-bottom":
      config.overlay.hintBGBottom = value
    case "overlay-hint-border":
      config.overlay.hintBorder = value

    case "debug-show-bounds":
      if let b = boolFromString(value) { config.debug.showBounds = b }
    case "debug-bounds-bg":
      config.debug.boundsBG = value
    case "debug-bounds-fg":
      config.debug.boundsFG = value
    case "debug-profile":
      if let b = boolFromString(value) { config.debug.profile = b }
    case "debug-slow-ms":
      if let i = Int(value) { config.debug.slowMs = i }
    case "debug-dump-ax":
      if let b = boolFromString(value) { config.debug.dumpAx = b }
    case "debug-dump-logs":
      if let b = boolFromString(value) { config.debug.dumpLogs = b }

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
}
