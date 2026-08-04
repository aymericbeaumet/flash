import Foundation

// CLI + env override surface for the resolved config.
//
// Scalar config keys are exposed via three matched names:
//   - a TOML key  (`section.key`, e.g. `hints.min_length`)
//   - an env var  (`FLASH_<SECTION>_<KEY>`, e.g. `FLASH_HINTS_MIN_LENGTH`)
//   - a CLI flag  (`--<section>-<key>=<value>`, e.g. `--hints-min-length=2`)
//
// Precedence: CLI > env > TOML > built-in default. The hot-reload path
// re-applies env + CLI on every reload, so the overrides stay in effect
// across `flash.toml` edits. Mode-mapping tables are TOML-only because
// their keys are arbitrary keystroke strings.
//
// When you add a new scalar field, add it to the override switch below and
// cover it in ConfigLoaderTests.

extension ConfigLoader {
  /// Override flag prefix recognised by the CLI parser.
  static let cliPrefix = "--"
  /// Environment variable prefix recognised by the env parser.
  static let envPrefix = "FLASH_"

  /// Layer env + CLI overrides on top of `config`. The override knobs are
  /// keyed in dash form (`hints-min-length`, `overlay-font-size`, …);
  /// `applyEnv` translates `FLASH_HINTS_MIN_LENGTH` → `hints-min-length`
  /// before calling `applyOverride`.
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
      // Unknown FLASH_* vars are intentionally NOT flagged: the process
      // environment can carry unrelated FLASH_-prefixed vars (e.g.
      // FLASH_PLUGIN_DATA_DIR), so a diagnostic here would false-positive.
      _ = applyOverride(key: key, value: rawVal, into: &config)
    }
  }

  private static func applyCLI(args: [String], into config: inout Config) {
    for arg in args.dropFirst() {
      guard arg.hasPrefix(cliPrefix) else { continue }
      let body = String(arg.dropFirst(cliPrefix.count))
      guard let eq = body.firstIndex(of: "=") else { continue }
      let key = String(body[..<eq])
      let value = String(body[body.index(after: eq)...])
      // A `--key=value` flag is an explicit override attempt; an unrecognized
      // one is almost certainly a typo (`--hints-min-lenght=2`) and was
      // previously discarded in silence. Surface it.
      if !applyOverride(key: key, value: value, into: &config) {
        config.addDiagnostic("unknown command-line flag '--\(key)=…' (no such config override)")
      }
    }
  }

  /// The single source of truth for what `--<key>=<value>` means.
  /// Values arrive as raw strings (no TOML quoting); int/double/bool/color
  /// fields parse + range-check the value and, on failure, add a located
  /// diagnostic (matching the TOML loader's reject-loudly stance) rather than
  /// dropping it silently. Returns true if `key` is a recognized override
  /// (even when its value was malformed and diagnosed); false for an unknown
  /// key, so `applyCLI` can warn.
  @discardableResult
  private static func applyOverride(key: String, value: String, into config: inout Config) -> Bool {
    switch key {
    case "hints-keys":
      config.hints.keys = value
      config.clearLocation(path: "hints.keys")
    case "hints-min-length":
      if let i = Int(value), (1...8).contains(i) {
        config.hints.minLength = i
        config.clearLocation(path: "hints.min_length")
      } else {
        config.addDiagnostic("hints.min_length override must be an integer between 1 and 8")
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
      if let d = Double(value), d >= 1, d <= 200 {
        config.overlay.fontSize = d
        config.clearLocation(path: "overlay.font_size")
      } else {
        config.addDiagnostic("overlay.font_size override must be a number between 1 and 200")
      }
    case "overlay-hint-fg":
      applyColorOverride(value, path: "overlay.hint_fg", into: &config) { $0.overlay.hintFG = $1 }
    case "overlay-hint-bg-top":
      applyColorOverride(value, path: "overlay.hint_bg_top", into: &config) {
        $0.overlay.hintBGTop = $1
      }
    case "overlay-hint-bg-bottom":
      applyColorOverride(value, path: "overlay.hint_bg_bottom", into: &config) {
        $0.overlay.hintBGBottom = $1
      }
    case "overlay-hint-border":
      applyColorOverride(value, path: "overlay.hint_border", into: &config) {
        $0.overlay.hintBorder = $1
      }
    case "overlay-important-hint-fg":
      applyColorOverride(value, path: "overlay.important_hint_fg", into: &config) {
        $0.overlay.importantHintFG = $1
      }
    case "overlay-important-hint-bg-top":
      applyColorOverride(value, path: "overlay.important_hint_bg_top", into: &config) {
        $0.overlay.importantHintBGTop = $1
      }
    case "overlay-important-hint-bg-bottom":
      applyColorOverride(value, path: "overlay.important_hint_bg_bottom", into: &config) {
        $0.overlay.importantHintBGBottom = $1
      }
    case "overlay-important-hint-border":
      applyColorOverride(value, path: "overlay.important_hint_border", into: &config) {
        $0.overlay.importantHintBorder = $1
      }

    case "flashlight-suggestion-count":
      if let i = Int(value), i > 0 {
        config.flashlight.suggestionCount = i
        config.clearLocation(path: "flashlight.suggestion_count")
      } else {
        config.addDiagnostic("flashlight.suggestion_count override must be a positive integer")
      }

    case "debug-show-bounds":
      if let b = boolFromString(value) {
        config.debug.showHintsBounds = b
        config.clearLocation(path: "debug.show_hints_bounds")
      } else {
        config.addDiagnostic("debug.show_hints_bounds override must be true or false")
      }
    case "debug-bounds-bg":
      applyColorOverride(value, path: "debug.hints_bounds_bg", into: &config) {
        $0.debug.hintsBoundsBG = $1
      }
    case "debug-bounds-fg":
      applyColorOverride(value, path: "debug.hints_bounds_fg", into: &config) {
        $0.debug.hintsBoundsFG = $1
      }
    case "debug-log-level":
      if let lvl = FlashLog.Level.parse(value) {
        config.debug.logLevel = lvl
        config.clearLocation(path: "debug.log_level")
      } else {
        config.addDiagnostic(
          "debug.log_level override must be trace/debug/info/warn/error/fatal")
      }
    // `--config=` is consumed by `resolvePath`; recognize it here so it
    // doesn't show up as an unknown flag.
    case "config":
      break

    default:
      return false
    }
    return true
  }

  /// Validate + assign a hex-color override, mirroring the TOML loader's
  /// `isValidHexColor` gate so a malformed `--overlay-hint-fg=garbage` is
  /// rejected loudly instead of assigned raw and silently failing at draw.
  private static func applyColorOverride(
    _ value: String, path: String, into config: inout Config,
    assign: (inout Config, String) -> Void
  ) {
    guard isValidHexColor(value) else {
      config.addDiagnostic("\(path) override must be a hex color (#RRGGBB / #RRGGBBAA)")
      return
    }
    assign(&config, value)
    config.clearLocation(path: path)
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
    if let values = parseOverrideQuotedStringArray(trimmed) {
      return values
    }
    return trimmed.split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func parseOverrideQuotedStringArray(_ v: String) -> [String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var out: [String] = []
    var i = inner.startIndex
    while i < inner.endIndex {
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
          switch inner[i] {
          case "n": current.append("\n")
          case "r": current.append("\r")
          case "t": current.append("\t")
          default: current.append(inner[i])
          }
        } else {
          current.append(inner[i])
        }
        i = inner.index(after: i)
      }
      guard i < inner.endIndex else { return nil }
      out.append(current)
      i = inner.index(after: i)
    }
    return out
  }
}
