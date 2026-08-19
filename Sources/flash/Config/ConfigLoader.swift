import Foundation
import TOMLKit

enum ConfigLoader {
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

  /// One TOML document in an ordered layer stack. Later layers override
  /// keys set by earlier ones; keys a layer doesn't mention are inherited.
  struct Layer {
    var text: String
    var sourceURL: URL?
    /// Short name prefixed onto this layer's diagnostics so a problem in a
    /// non-primary layer (e.g. the embedded default config) names its file.
    /// nil for the primary (user) config, whose diagnostics stay unprefixed.
    var diagnosticLabel: String?

    init(text: String, sourceURL: URL? = nil, diagnosticLabel: String? = nil) {
      self.text = text
      self.sourceURL = sourceURL
      self.diagnosticLabel = diagnosticLabel
    }
  }

  /// Production entry point. Layers, in override order (low → high):
  /// the default config embedded in the app bundle, then the user's TOML
  /// file, then environment-variable overrides and command-line overrides.
  /// **Precedence (high → low): CLI flag > env var > user TOML > embedded
  /// default TOML > built-in Swift default.** Parsing the embedded default
  /// on every launch also revalidates it: any diagnostic it produces is a
  /// Flash bug, and is logged with the file's name.
  static func load() -> Config {
    let args = CommandLine.arguments
    let env = ProcessInfo.processInfo.environment
    var layers: [Layer] = []
    if let defaults = embeddedDefaultLayer() { layers.append(defaults) }
    let url = resolvePath(arguments: args, environment: env)
    if let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    {
      layers.append(Layer(text: text, sourceURL: url.resolvingSymlinksInPath()))
    }
    let parsed = parseLayers(layers, environment: env)
    return applyOverrides(to: parsed, arguments: args, environment: env)
  }

  /// The default config bundled into the app (`Resources/config.default.toml`
  /// at build time). nil in unit tests and non-bundle contexts — the Swift
  /// struct defaults then stand alone, as before.
  static func embeddedDefaultLayer() -> Layer? {
    guard
      let url = Bundle.main.url(forResource: "config.default", withExtension: "toml"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return Layer(
      text: text,
      sourceURL: url.resolvingSymlinksInPath(),
      diagnosticLabel: "config.default.toml")
  }

  static func parse(
    _ text: String,
    sourceURL: URL? = nil,
    environment: [String: String] = [:]
  ) -> Config {
    parseLayers(
      [Layer(text: text, sourceURL: sourceURL)],
      environment: environment)
  }

  /// Parse an ordered layer stack into one Config. Each layer's tables are
  /// applied onto the same accumulating value, so "later overrides earlier"
  /// falls out of the assign-only-when-present loader design. Mode mappings
  /// are collected across all layers and resolved once at the end (a
  /// `<leader>` may be defined in a different layer than the mapping using
  /// it); the status-bar template is compiled once from whichever layer
  /// defined it last.
  static func parseLayers(
    _ layers: [Layer],
    environment: [String: String] = [:]
  ) -> Config {
    var config = Config()
    var pendingModeMappings: [PendingModeMapping] = []

    for layer in layers {
      let diagnosticsBefore = config.diagnostics.count
      let locations = ConfigSourceLocationIndex(text: layer.text)
      do {
        let root = try TOMLTable(string: layer.text)
        apply(
          root: root,
          locations: locations,
          sourceURL: layer.sourceURL,
          pendingModeMappings: &pendingModeMappings,
          into: &config)
      } catch let error as TOMLParseError {
        config.addDiagnostic(
          "TOML parse error: \(error.description)",
          location: ConfigLocation(
            line: error.source.begin.line, column: error.source.begin.column))
      } catch {
        config.addDiagnostic("TOML parse error: \(error)")
      }
      if let label = layer.diagnosticLabel {
        for index in diagnosticsBefore..<config.diagnostics.count {
          config.diagnostics[index] = ConfigDiagnostic(
            message: "\(label): \(config.diagnostics[index].message)",
            location: config.diagnostics[index].location)
        }
      }
    }

    applyPendingModeMappings(pendingModeMappings, into: &config)
    applyStatusBarTemplate(sourceURL: config.statusBar.templateSourceURL, into: &config)
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
    var repeatsOnFinalKey: Bool
    var location: ConfigLocation
  }

  private struct ParsedModeMappingValue {
    var action: MappingCommand
    var repeatsOnFinalKey: Bool
  }

  private enum ModeMappingValueError: Error {
    case invalidShape
    case invalidAction
    case invalidRepeat
    case unknownOption(String)

    func message(mappingKey: String) -> String {
      switch self {
      case .invalidShape:
        return
          "mapping \"\(mappingKey)\" must be a non-empty string array or "
          + "{ action = [\"flash\", \"<verb>\", ...], repeat = true }"
      case .invalidAction:
        return
          "mapping \"\(mappingKey)\".action must be a non-empty string array — "
          + "[\"flash\", \"<verb>\", ...] or [<argv>...]"
      case .invalidRepeat:
        return "mapping \"\(mappingKey)\".repeat must be true or false"
      case .unknownOption(let option):
        return
          "mapping \"\(mappingKey)\": unknown option '\(option)' — "
          + "valid options are action and repeat"
      }
    }
  }

  private static func apply(
    root: TOMLTable,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    // Route every section through `sectionTable` so a section present with a
    // non-table value (`hints = 5`) diagnoses instead of silently vanishing —
    // `warnUnknownConfigKeys` can't catch that case because the name IS known.
    func section(_ name: String) -> TOMLTable? {
      sectionTable(root[name], name: name, locations: locations, into: &config)
    }
    applyApp(section("app"), locations: locations, into: &config)
    applyHints(section("hints"), locations: locations, into: &config)
    applyOpen(section("open"), locations: locations, into: &config)
    applyPlugins(section("plugins"), locations: locations, sourceURL: sourceURL, into: &config)
    applyPluginSettings(section("plugin"), locations: locations, into: &config)
    applyStatusBar(
      section("statusbar"), locations: locations, sourceURL: sourceURL, into: &config)
    applyFlashlight(section("flashlight"), locations: locations, into: &config)
    applyMode(
      section("mode"),
      locations: locations,
      sourceURL: sourceURL,
      pendingModeMappings: &pendingModeMappings,
      into: &config)
    applyOverlay(section("overlay"), locations: locations, into: &config)
    applyDebug(section("debug"), locations: locations, into: &config)
    warnUnknownConfigKeys(root: root, locations: locations, into: &config)
  }

  /// A section's table, or a located diagnostic when the key exists with a
  /// non-table value. nil when absent or invalid.
  private static func sectionTable(
    _ value: (any TOMLValueConvertible)?,
    name: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) -> TOMLTable? {
    guard let value else { return nil }
    guard let table = value.table else {
      config.addDiagnostic(
        "[\(name)] must be a table of keys ([\(name)] on its own line), not a single value",
        location: locations.location(for: [name]))
      return nil
    }
    return table
  }

  /// After every known section is applied, warn on keys the loader doesn't
  /// recognize so a typo surfaces (located, with a suggestion) instead of being
  /// silently dropped — the single biggest config UX cliff: `[hint]` for
  /// `[hints]`, `mouse_grid_step` for `mouse_grid_steps`, a stray top-level key.
  /// Sections with user-defined keys (`[plugin.<id>]`, and the
  /// `flashlight.aliases`/`flashlight.precedence` subtables) are deliberately
  /// not enumerated. The schema map lives here, in one place, so it can't drift
  /// across the scattered appliers.
  private static func warnUnknownConfigKeys(
    root: TOMLTable,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    let sectionKeys: [String: Set<String>] = [
      "app": ["menu_bar_icon", "autostart"],
      "hints": ["keys", "min_length", "magic_modifiers", "mouse_grid_steps", "mouse_grid_opacity"],
      "open": ["ignored_apps", "app_directories"],
      "plugins": [
        "watching_enabled", "disabled", "third_party", "install_timeout", "startup_timeout",
      ],
      "statusbar": ["enabled", "template", "monitor", "interval", "click", "font_size", "command_timeout"],
      "flashlight": [
        "suggestion_count", "precedence_alive_bonus", "aliases", "precedence",
        "frecency_half_life_days", "frecency_max_boost", "snapshot_timeout_ms",
      ],
      "mode": [
        "labels", "sequence_timeout_ms", "normal", "all", "insert", "scroll_step",
        "scroll_page_fraction", "click_hold_ms", "send_key_interval_ms",
      ],
      "overlay": [
        "font_size", "hint_fg", "hint_bg_top", "hint_bg_bottom", "hint_border",
        "important_hint_fg", "important_hint_bg_top", "important_hint_bg_bottom",
        "important_hint_border", "window_border", "window_border_size",
        "window_border_color", "alert_duration", "banner_duration_ms",
      ],
      "debug": [
        "show_hints_bounds", "hints_bounds_bg", "hints_bounds_fg", "log_level",
        "http_inspector_enabled", "http_inspector_host", "http_inspector_port",
      ],
    ]
    // `plugin` is a known top-level section but carries user-defined
    // `[plugin.<id>]` tables, so its keys are not enumerated.
    let knownSections = Set(sectionKeys.keys).union(["plugin"])
    warnUnknownKeys(in: root, known: knownSections, path: [], locations: locations, into: &config)
    for (section, known) in sectionKeys {
      guard let table = root[section]?.table else { continue }
      warnUnknownKeys(in: table, known: known, path: [section], locations: locations, into: &config)
    }
  }

  /// Emit a located "unknown config key" diagnostic for every key in `table`
  /// not in `known`, with a Levenshtein "did you mean" when a close match exists.
  private static func warnUnknownKeys(
    in table: TOMLTable,
    known: Set<String>,
    path: [String],
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    for (key, _) in table where !known.contains(key) {
      let fullPath = path + [key]
      let dotted = fullPath.joined(separator: ".")
      let suggestion = closestKnownKey(to: key, in: known).map { " — did you mean '\($0)'?" } ?? ""
      config.addDiagnostic(
        "unknown config key '\(dotted)'\(suggestion)",
        location: locations.location(for: fullPath))
    }
  }

  /// The known key closest to `typo` by edit distance, when within a small
  /// budget — so we suggest only on plausible misspellings, not unrelated keys.
  private static func closestKnownKey(to typo: String, in known: Set<String>) -> String? {
    var best: (key: String, distance: Int)?
    for candidate in known {
      let distance = levenshtein(typo, candidate)
      if best == nil || distance < best!.distance { best = (candidate, distance) }
    }
    guard let best, best.distance <= 3, best.distance < typo.count else { return nil }
    return best.key
  }

  private static func levenshtein(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1)
    let b = Array(s2)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  private static func applyHints(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyString(
      table["keys"], path: ["hints", "keys"],
      message:
        "hints.keys must be a layout selector like \"<qwerty_homerow+qwerty_toprow>\" or a string of ASCII letters",
      locations: locations, into: &config,
      validate: { !$0.trimmed.isEmpty && Alphabet.resolve($0).warning == nil }
    ) { value, config in
      config.hints.keys = value
    }
    applyInt(
      table["min_length"], path: ["hints", "min_length"],
      message: "hints.min_length must be an integer between 1 and 8", locations: locations,
      into: &config, validate: { (1...8).contains($0) },
      assign: { value, config in
        config.hints.minLength = value
      })
    applyStringArray(
      table["magic_modifiers"], path: ["hints", "magic_modifiers"],
      message: "hints.magic_modifiers must be an array of strings", locations: locations,
      into: &config
    ) { value, config in
      // Diagnose unknown tokens instead of silently dropping them (the
      // passthrough_modifiers list already diagnoses this exact typo class),
      // and assign only the recognised ones.
      let unknown = KeyModifier.parseList(value).unknown
      if !unknown.isEmpty {
        config.addDiagnostic(
          "hints.magic_modifiers: unknown modifier(s) \(unknown.joined(separator: ", ")) "
            + "(use cmd/ctrl/alt/shift)",
          location: locations.location(for: ["hints", "magic_modifiers"]))
      }
      let unknownSet = Set(unknown)
      config.hints.magicModifiers = value.filter { !unknownSet.contains($0) }
    }
    applyInt(
      table["mouse_grid_steps"], path: ["hints", "mouse_grid_steps"],
      message: "hints.mouse_grid_steps must be an integer between 2 and 6", locations: locations,
      into: &config, validate: { (2...6).contains($0) },
      assign: { value, config in
        config.hints.mouseGridSteps = value
      })
    applyDouble(
      table["mouse_grid_opacity"], path: ["hints", "mouse_grid_opacity"],
      message: "hints.mouse_grid_opacity must be a number between 0.0 and 1.0",
      locations: locations, into: &config, validate: { (0.0...1.0).contains($0) },
      assign: { value, config in
        config.hints.mouseGridOpacity = value
      })
  }

  private static func applyOpen(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyStringArray(
      table["ignored_apps"], path: ["open", "ignored_apps"],
      message: "open.ignored_apps must be an array of strings", locations: locations, into: &config
    ) { value, config in
      config.open.ignoredApps = value
    }
    applyStringArray(
      table["app_directories"], path: ["open", "app_directories"],
      message: "open.app_directories must be an array of directory paths",
      locations: locations, into: &config
    ) { value, config in
      let location = locations.location(for: ["open", "app_directories"])
      // An empty list would silently kill the whole app catalog — keep the
      // defaults and say so.
      guard !value.isEmpty else {
        config.addDiagnostic(
          "open.app_directories must not be empty (remove the key to use the defaults)",
          location: location)
        return
      }
      // Scanning from a filesystem root would walk the entire volume on
      // every reload; refuse those outright. Missing directories are only
      // warned about — an entry may legitimately appear later.
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let roots = value.filter {
        let expanded = ($0 as NSString).expandingTildeInPath
        return expanded == "/" || expanded == home
      }
      guard roots.isEmpty else {
        config.addDiagnostic(
          "open.app_directories must not include a filesystem root or the bare home directory: "
            + roots.joined(separator: ", "),
          location: location)
        return
      }
      // Missing directories are fine — the watcher picks them up if they
      // appear later, so no existence check here.
      config.open.appDirectories = value
    }
  }

  private static func applyPlugins(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["watching_enabled"], path: ["plugins", "watching_enabled"],
      message: "plugins.watching_enabled must be true or false", locations: locations, into: &config
    ) { value, config in
      config.plugins.watchingEnabled = value
    }
    applyInt(
      table["install_timeout"], path: ["plugins", "install_timeout"],
      message: "plugins.install_timeout must be an integer between 10 and 1800 (seconds)",
      locations: locations, into: &config, validate: { (10...1_800).contains($0) },
      assign: { value, config in
        config.plugins.installTimeoutSeconds = value
      })
    applyInt(
      table["startup_timeout"], path: ["plugins", "startup_timeout"],
      message: "plugins.startup_timeout must be an integer between 1 and 120 (seconds)",
      locations: locations, into: &config, validate: { (1...120).contains($0) },
      assign: { value, config in
        config.plugins.startupTimeoutSeconds = value
      })

    let disabledPath = ["plugins", "disabled"]
    // A malformed `disabled` must not abort the rest of the section (it
    // used to `return`, silently dropping `third_party` with it).
    if let value = table["disabled"] {
      let location = locations.location(for: disabledPath)
      if let parsed = stringArrayValue(value) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        var disabled = Set<String>()
        var invalid: [String] = []
        for raw in parsed {
          let id = raw.trimmed.lowercased()
          if !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            disabled.insert(id)
          } else {
            invalid.append(raw)
          }
        }
        if invalid.isEmpty {
          config.plugins.disabled = disabled
          config.recordLocation(path: "plugins.disabled", location: location)
        } else {
          config.addDiagnostic(
            "plugins.disabled entries must be lowercase [a-z0-9._-]: \(invalid.joined(separator: ", "))",
            location: location)
        }
      } else {
        config.addDiagnostic(
          "plugins.disabled must be an array of plugin ids",
          location: location)
      }
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
    let allowedIDChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    for (pluginID, value) in table {
      guard
        !pluginID.isEmpty,
        pluginID.unicodeScalars.allSatisfy({ allowedIDChars.contains($0) })
      else {
        config.addDiagnostic(
          "[plugin.\(pluginID)] plugin ids must be lowercase [a-z0-9._-]",
          location: locations.location(for: ["plugin", pluginID]))
        continue
      }
      guard let settings = value.table else {
        config.addDiagnostic(
          "plugin.\(pluginID) must be a [plugin.\(pluginID)] table of settings, not a single value",
          location: locations.location(for: ["plugin", pluginID]))
        continue
      }
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
    sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["enabled"], path: ["statusbar", "enabled"],
      message: "statusbar.enabled must be true or false", locations: locations, into: &config
    ) { value, config in
      config.statusBar.enabled = value
    }
    return applyStatusBarTail(table, locations: locations, sourceURL: sourceURL, into: &config)
  }

  private static func applyApp(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["menu_bar_icon"], path: ["app", "menu_bar_icon"],
      message: "app.menu_bar_icon must be true or false", locations: locations, into: &config
    ) { value, config in
      config.app.menuBarIcon = value
    }
    applyBool(
      table["autostart"], path: ["app", "autostart"],
      message: "app.autostart must be true or false", locations: locations, into: &config
    ) { value, config in
      config.app.autostart = value
    }
  }

  private static func applyStatusBarTail(
    _ table: TOMLTable,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    applyString(
      table["template"], path: ["statusbar", "template"],
      message: "statusbar.template must be a quoted template string", locations: locations,
      into: &config
    ) { value, config in
      config.statusBar.template.template = value
      // Relative `#{script:…}` paths resolve against the file that DEFINED
      // the template — with layered configs that may be an earlier layer
      // than the last one parsed, so remember it here.
      config.statusBar.templateSourceURL = sourceURL
    }
    applyString(
      table["monitor"], path: ["statusbar", "monitor"],
      message: "statusbar.monitor must be \"all\" or \"primary\"", locations: locations,
      into: &config, validate: { Config.StatusBar.Monitor(rawValue: $0.lowercased()) != nil },
      assign: { value, config in
        config.statusBar.monitor = Config.StatusBar.Monitor(rawValue: value.lowercased()) ?? .all
      })
    applyInt(
      table["interval"], path: ["statusbar", "interval"],
      message:
        "statusbar.interval must be an integer between 0 and 86400 (seconds; 0 disables polling)",
      locations: locations, into: &config, validate: { (0...86_400).contains($0) },
      assign: { value, config in
        config.statusBar.refreshIntervalSeconds = Double(value)
      })
    applyDouble(
      table["font_size"], path: ["statusbar", "font_size"],
      message: "statusbar.font_size must be a number between 8 and 32 (points)",
      locations: locations, into: &config, validate: { (8.0...32.0).contains($0) },
      assign: { value, config in
        config.statusBar.fontSize = value
      })
    applyDouble(
      table["command_timeout"], path: ["statusbar", "command_timeout"],
      message: "statusbar.command_timeout must be a number between 1 and 60 (seconds)",
      locations: locations, into: &config, validate: { (1.0...60.0).contains($0) },
      assign: { value, config in
        config.statusBar.commandTimeoutSeconds = value
      })
    if let click = sectionTable(
      table["click"], name: "statusbar.click", locations: locations, into: &config)
    {
      for (name, value) in click {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let location = locations.location(for: ["statusbar", "click", name])
        guard !trimmedName.isEmpty else { continue }
        if let url = value.string {
          if URL(string: url) != nil, !url.isEmpty {
            config.statusBar.clickActions[trimmedName] = .url(url)
            config.recordLocation(path: "statusbar.click.\(trimmedName)", location: location)
          } else {
            config.addDiagnostic(
              "statusbar.click.\(name) must be a valid URL or a [\"flash\", \"<verb>\", …] action array",
              location: location)
          }
        } else if let action = parseMappingActionValue(value, sourceURL: sourceURL) {
          config.statusBar.clickActions[trimmedName] = .command(action)
          config.recordLocation(path: "statusbar.click.\(trimmedName)", location: location)
        } else {
          config.addDiagnostic(
            "statusbar.click.\(name) must be a URL string or a [\"flash\", \"<verb>\", …] action array",
            location: location)
        }
      }
    }
  }

  private static func applyFlashlight(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyInt(
      table["suggestion_count"], path: ["flashlight", "suggestion_count"],
      message: "flashlight.suggestion_count must be an integer between 1 and 100",
      locations: locations,
      into: &config, validate: { (1...100).contains($0) },
      assign: { value, config in
        config.flashlight.suggestionCount = value
      })
    applyInt(
      table["precedence_alive_bonus"], path: ["flashlight", "precedence_alive_bonus"],
      message: "flashlight.precedence_alive_bonus must be an integer between 0 and 10000",
      locations: locations, into: &config,
      validate: { (0...Self.precedenceBound).contains($0) },
      assign: { value, config in
        config.flashlight.precedenceAliveBonus = value
      })
    applyDouble(
      table["frecency_half_life_days"], path: ["flashlight", "frecency_half_life_days"],
      message: "flashlight.frecency_half_life_days must be a number between 0.5 and 365",
      locations: locations, into: &config, validate: { (0.5...365.0).contains($0) },
      assign: { value, config in
        config.flashlight.frecencyHalfLifeDays = value
      })
    applyInt(
      table["frecency_max_boost"], path: ["flashlight", "frecency_max_boost"],
      message: "flashlight.frecency_max_boost must be an integer between 0 and 10000 (0 = off)",
      locations: locations, into: &config, validate: { (0...10_000).contains($0) },
      assign: { value, config in
        config.flashlight.frecencyMaxBoost = value
      })
    applyInt(
      table["snapshot_timeout_ms"], path: ["flashlight", "snapshot_timeout_ms"],
      message: "flashlight.snapshot_timeout_ms must be an integer between 20 and 2000 (ms)",
      locations: locations, into: &config, validate: { (20...2_000).contains($0) },
      assign: { value, config in
        config.flashlight.snapshotTimeoutMs = value
      })

    if let aliases = sectionTable(
      table["aliases"], name: "flashlight.aliases", locations: locations, into: &config)
    {
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

    if let precedence = sectionTable(
      table["precedence"], name: "flashlight.precedence", locations: locations, into: &config)
    {
      for (key, value) in precedence {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        let locationPath = ["flashlight", "precedence", key]
        let location = locations.location(for: locationPath)
        // Bounded so the ranking sum (base + alive bonus) can never
        // overflow Int and trap on the first flashlight query.
        if let parsed = value.int, !trimmedKey.isEmpty,
          (-Self.precedenceBound...Self.precedenceBound).contains(parsed)
        {
          config.flashlight.precedence[trimmedKey] = parsed
          config.recordLocation(path: "flashlight.precedence.\(trimmedKey)", location: location)
        } else {
          config.addDiagnostic(
            "flashlight.precedence.\(key) must be an integer between -10000 and 10000",
            location: location)
        }
      }
    }
  }

  /// Precedence values are user-tunable ranking weights, not magnitudes —
  /// ±10k spans every sensible tier while keeping additions overflow-proof.
  private static let precedenceBound = 10_000

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
      // Labels drive status-bar width math (`longestCount`), so bound their
      // length; unknown sub-keys are typos worth naming.
      if let parsed = stringTableValue(value),
        let normal = parsed["normal"],
        let insert = parsed["insert"],
        let command = parsed["command"],
        (1...32).contains(normal.count),
        (1...32).contains(insert.count),
        (1...32).contains(command.count)
      {
        for key in parsed.keys where !["normal", "insert", "command"].contains(key) {
          config.addDiagnostic(
            "mode.labels: unknown key '\(key)' (valid keys are normal, insert, command)",
            location: location)
        }
        config.mode.labels = Config.Mode.Labels(
          normal: normal,
          insert: insert,
          command: command)
        config.recordLocation(path: "mode.labels", location: location)
      } else {
        config.addDiagnostic(
          "mode.labels must be { normal = \"...\", insert = \"...\", command = \"...\" } "
            + "with each label 1-32 characters",
          location: location)
      }
    }

    applyInt(
      table["sequence_timeout_ms"], path: ["mode", "sequence_timeout_ms"],
      message: "mode.sequence_timeout_ms must be an integer between 0 and 10000 (ms)",
      locations: locations,
      into: &config, validate: { (0...10_000).contains($0) },
      assign: { value, config in
        config.mode.sequenceTimeoutMs = value
      })
    applyInt(
      table["scroll_step"], path: ["mode", "scroll_step"],
      message: "mode.scroll_step must be an integer between 10 and 500 (pixels)",
      locations: locations, into: &config, validate: { (10...500).contains($0) },
      assign: { value, config in
        config.mode.scrollStep = value
      })
    applyDouble(
      table["scroll_page_fraction"], path: ["mode", "scroll_page_fraction"],
      message: "mode.scroll_page_fraction must be a number between 0.05 and 1.0",
      locations: locations, into: &config, validate: { (0.05...1.0).contains($0) },
      assign: { value, config in
        config.mode.scrollPageFraction = value
      })
    applyInt(
      table["click_hold_ms"], path: ["mode", "click_hold_ms"],
      message: "mode.click_hold_ms must be an integer between 0 and 200 (ms)",
      locations: locations, into: &config, validate: { (0...200).contains($0) },
      assign: { value, config in
        config.mode.clickHoldMs = value
      })
    applyInt(
      table["send_key_interval_ms"], path: ["mode", "send_key_interval_ms"],
      message: "mode.send_key_interval_ms must be an integer between 0 and 500 (ms)",
      locations: locations, into: &config, validate: { (0...500).contains($0) },
      assign: { value, config in
        config.mode.sendKeyIntervalMs = value
      })

    if let normal = sectionTable(
      table["normal"], name: "mode.normal", locations: locations, into: &config)
    {
      applyString(
        normal["leader"], path: ["mode", "normal", "leader"],
        message: "mode.normal.leader must be a single key (e.g. \"\\\\\" or \",\")",
        locations: locations,
        into: &config,
        validate: {
          // Reject multi-atom strings here — otherwise every <leader>
          // mapping later fails with a misleading "leader is not set".
          NormalModeInterpreter.translateLeader(canonicalNormalModeKeyToken($0)) != nil
        },
        assign: { value, config in
          config.mode.normalLeader = canonicalNormalModeKeyToken(value)
        })
      applyStringArray(
        normal["passthrough_keys"], path: ["mode", "normal", "passthrough_keys"],
        message: "mode.normal.passthrough_keys must be an array of key names",
        locations: locations, into: &config,
        assign: { value, config in
          for token in value where HotkeySyntax.parseKey(token) == nil {
            config.addDiagnostic(
              "mode.normal.passthrough_keys: unknown key \"\(token)\"",
              location: locations.location(for: ["mode", "normal", "passthrough_keys"]))
          }
          // Keep only the tokens that parse — carrying known-invalid
          // entries in the live config helps nobody.
          config.mode.normalPassthroughKeys = value.filter { HotkeySyntax.parseKey($0) != nil }
        })
      applyStringArray(
        normal["passthrough_modifiers"], path: ["mode", "normal", "passthrough_modifiers"],
        message:
          "mode.normal.passthrough_modifiers must be an array of "
          + "\"cmd\"/\"ctrl\"/\"shift\"/\"alt\"",
        locations: locations, into: &config,
        assign: { value, config in
          let unknown = KeyModifier.parseList(value).unknown
          for token in unknown {
            config.addDiagnostic(
              "mode.normal.passthrough_modifiers: unknown modifier \"\(token)\" "
                + "(use cmd/ctrl/shift/alt)",
              location: locations.location(for: ["mode", "normal", "passthrough_modifiers"]))
          }
          let unknownSet = Set(unknown)
          config.mode.normalPassthroughModifiers = value.filter { !unknownSet.contains($0) }
        })
      applyModeMappingTable(
        sectionTable(
          normal["mappings"], name: "mode.normal.mappings", locations: locations, into: &config),
        scope: .normal,
        path: ["mode", "normal", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in normal
      where key != "leader" && key != "passthrough_keys" && key != "passthrough_modifiers"
        && key != "mappings"
      {
        config.addDiagnostic(
          "mode.normal: unknown key '\(key)' — mappings belong under "
            + "[mode.normal.mappings]; valid keys are leader, "
            + "passthrough_keys, passthrough_modifiers, mappings",
          location: locations.location(for: ["mode", "normal", key]))
      }
    }

    if let all = sectionTable(table["all"], name: "mode.all", locations: locations, into: &config) {
      applyModeMappingTable(
        sectionTable(
          all["mappings"], name: "mode.all.mappings", locations: locations, into: &config),
        scope: .all,
        path: ["mode", "all", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in all where key != "mappings" {
        config.addDiagnostic(
          "mode.all: unknown key '\(key)' — mappings belong under [mode.all.mappings]",
          location: locations.location(for: ["mode", "all", key]))
      }
    }

    if let insert = sectionTable(
      table["insert"], name: "mode.insert", locations: locations, into: &config)
    {
      applyModeMappingTable(
        sectionTable(
          insert["mappings"], name: "mode.insert.mappings", locations: locations, into: &config),
        scope: .insert,
        path: ["mode", "insert", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in insert where key != "mappings" {
        config.addDiagnostic(
          "mode.insert: unknown key '\(key)' — mappings belong under [mode.insert.mappings]",
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
    applyDouble(
      table["font_size"], path: ["overlay", "font_size"],
      message: "overlay.font_size must be a number between 1 and 200", locations: locations,
      into: &config, validate: { $0 >= 1 && $0 <= 200 },
      assign: { value, config in
        config.overlay.fontSize = value
      })
    applyString(
      table["hint_fg"], path: ["overlay", "hint_fg"],
      message: "overlay.hint_fg must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.hintFG = value
      })
    applyString(
      table["hint_bg_top"], path: ["overlay", "hint_bg_top"],
      message: "overlay.hint_bg_top must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.hintBGTop = value
      })
    applyString(
      table["hint_bg_bottom"], path: ["overlay", "hint_bg_bottom"],
      message: "overlay.hint_bg_bottom must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.hintBGBottom = value
      })
    applyString(
      table["hint_border"], path: ["overlay", "hint_border"],
      message: "overlay.hint_border must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.hintBorder = value
      })
    applyString(
      table["important_hint_fg"], path: ["overlay", "important_hint_fg"],
      message: "overlay.important_hint_fg must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.importantHintFG = value
      })
    applyString(
      table["important_hint_bg_top"], path: ["overlay", "important_hint_bg_top"],
      message: "overlay.important_hint_bg_top must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.importantHintBGTop = value
      })
    applyString(
      table["important_hint_bg_bottom"], path: ["overlay", "important_hint_bg_bottom"],
      message: "overlay.important_hint_bg_bottom must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.importantHintBGBottom = value
      })
    applyString(
      table["important_hint_border"], path: ["overlay", "important_hint_border"],
      message: "overlay.important_hint_border must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.overlay.importantHintBorder = value
      })
    applyBool(
      table["window_border"], path: ["overlay", "window_border"],
      message: "overlay.window_border must be true or false", locations: locations, into: &config
    ) { value, config in
      config.overlay.windowBorder = value
    }
    applyDouble(
      table["window_border_size"], path: ["overlay", "window_border_size"],
      message: "overlay.window_border_size must be a number between 0 and 20 (points; 0 keeps the per-mode defaults)",
      locations: locations, into: &config, validate: { $0 >= 0 && $0 <= 20 },
      assign: { value, config in
        config.overlay.windowBorderSize = value
      })
    applyString(
      table["window_border_color"], path: ["overlay", "window_border_color"],
      message:
        "overlay.window_border_color must be a hex color like #RRGGBB or #RRGGBBAA (empty keeps the per-mode colors)",
      locations: locations, into: &config, validate: { $0.isEmpty || isValidHexColor($0) },
      assign: { value, config in
        config.overlay.windowBorderColor = value
      })
    applyDouble(
      table["alert_duration"], path: ["overlay", "alert_duration"],
      message: "overlay.alert_duration must be a number between 0.2 and 30 (seconds)",
      locations: locations, into: &config, validate: { (0.2...30.0).contains($0) },
      assign: { value, config in
        config.overlay.alertDuration = value
      })
    applyInt(
      table["banner_duration_ms"], path: ["overlay", "banner_duration_ms"],
      message: "overlay.banner_duration_ms must be an integer between 100 and 10000 (ms)",
      locations: locations, into: &config, validate: { (100...10_000).contains($0) },
      assign: { value, config in
        config.overlay.bannerDurationMs = value
      })
  }

  private static func applyDebug(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["show_hints_bounds"], path: ["debug", "show_hints_bounds"],
      message: "debug.show_hints_bounds must be true or false", locations: locations, into: &config
    ) { value, config in
      config.debug.showHintsBounds = value
    }
    applyString(
      table["hints_bounds_bg"], path: ["debug", "hints_bounds_bg"],
      message: "debug.hints_bounds_bg must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.debug.hintsBoundsBG = value
      })
    applyString(
      table["hints_bounds_fg"], path: ["debug", "hints_bounds_fg"],
      message: "debug.hints_bounds_fg must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in
        config.debug.hintsBoundsFG = value
      })

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

    applyBool(
      table["http_inspector_enabled"], path: ["debug", "http_inspector_enabled"],
      message: "debug.http_inspector_enabled must be true or false", locations: locations,
      into: &config
    ) { value, config in
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

    applyInt(
      table["http_inspector_port"], path: ["debug", "http_inspector_port"],
      message: "debug.http_inspector_port must be an integer in 1..65535", locations: locations,
      into: &config, validate: { (1...65535).contains($0) },
      assign: { value, config in
        config.debug.httpInspectorPort = value
      })
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
      switch parseMappingValue(value, sourceURL: sourceURL) {
      case .success(let parsed):
        pendingModeMappings.append(
          PendingModeMapping(
            scope: scope,
            rawKey: key,
            key: canonical,
            action: parsed.action,
            repeatsOnFinalKey: parsed.repeatsOnFinalKey,
            location: location ?? ConfigLocation(line: 1, column: 1)))
      case .failure(let error):
        config.addDiagnostic(
          error.message(mappingKey: key),
          location: location)
      }
    }
  }

  /// A hint / bounds color is `#`-optional 6- or 8-digit hex (`RRGGBB` or
  /// `RRGGBBAA`), matching `OverlayPanel.nsColor(fromHex:)`. Empty is allowed
  /// (renders as no color). Anything else is a typo and is rejected loudly
  /// rather than silently falling back to a default at draw time.
  static func isValidHexColor(_ raw: String) -> Bool {
    var s = raw.trimmingCharacters(in: .whitespaces)
    // Empty is NOT a color. Keys where empty means "use the default"
    // (window_border_color) opt in explicitly at their call site.
    if s.isEmpty { return false }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8 else { return false }
    return s.allSatisfy(\.isHexDigit)
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
    // Accept exactly-integral doubles (`interval = 5.0`) — rejecting them
    // while `applyDouble` accepts ints would be a gratuitous asymmetry.
    let parsed = value.int ?? value.double.flatMap { Int(exactly: $0) }
    guard let parsed, validate(parsed) else {
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
    repeatsOnFinalKey: Bool,
    into config: inout Config
  ) {
    let mapping = ModeMapping(
      key: key,
      action: action,
      repeatsOnFinalKey: repeatsOnFinalKey)
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
      setModeMapping(
        scope: mapping.scope,
        key: key,
        action: mapping.action,
        repeatsOnFinalKey: mapping.repeatsOnFinalKey,
        into: &config)
    }
  }

  private static func applyStatusBarTemplate(sourceURL: URL?, into config: inout Config) {
    let normalizedTemplate = FlashStatusBarTemplateEngine.normalizedTemplate(
      config.statusBar.template.template)
    let variables = parseStatusBarTemplateVariables(
      normalizedTemplate,
      path: "template",
      sourceURL: sourceURL,
      commandTimeout: config.statusBar.commandTimeoutSeconds,
      into: &config)
    config.statusBar.template = FlashStatusBarTemplate(
      template: normalizedTemplate,
      variables: variables)
  }

  private static func parseStatusBarTemplateVariables(
    _ raw: String,
    path: String,
    sourceURL: URL?,
    commandTimeout: TimeInterval = 6,
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

    // Recursive registration: a `#{…}` body may be a plain variable, a
    // modifier wrapping one (`=N:`, `s///:`, `pN:`), or a conditional /
    // comparator whose arguments are themselves format strings. Command and
    // cycle sources must be discovered wherever they sit so their sections
    // get scheduled.
    func registerLeaf(_ token: String, rawBody: String) {
      if let source = parseStatusBarTemplateSource(
        token, sourceURL: sourceURL, commandTimeout: commandTimeout)
      {
        appendToken(token, source: source)
      } else {
        config.addDiagnostic(
          "statusbar.\(path) template variable \"\(rawBody)\" must be mode, active_app_name, active_bundle_identifier, date, a tmux variable, plugin:<name>, plugin:<plugin>.<segment>, script:<path>, or command:<shell> (optionally wrapped in a tmux modifier: #{=N:…}, #{?cond,a,b}, #{s/re/repl/:…}, #{pN:…})",
          location: config.valueLocations["statusbar.\(path)"])
      }
    }

    func registerOperand(_ operand: String, rawBody: String) {
      let trimmed = operand.trimmed
      guard !trimmed.isEmpty else { return }
      if trimmed.contains("#{") {
        registerFormatString(trimmed)
      } else {
        registerLeaf(trimmed, rawBody: rawBody)
      }
    }

    func registerBody(_ body: String) {
      if body.hasPrefix("?") {
        let args = FlashStatusBarMarkup.splitFormatArguments(body.dropFirst())
        guard args.count >= 2 else {
          config.addDiagnostic(
            "statusbar.\(path) conditional \"#{\(body)}\" must be #{?condition,true,false}",
            location: config.valueLocations["statusbar.\(path)"])
          return
        }
        registerOperand(args[0], rawBody: body)
        for branch in args.dropFirst() { registerFormatString(branch) }
        return
      }
      for op in FlashStatusBarTemplateEngine.FormatExpansion.comparators
      where body.hasPrefix(op + ":") {
        for arg in FlashStatusBarMarkup.splitFormatArguments(body.dropFirst(op.count + 1)) {
          registerOperand(arg, rawBody: body)
        }
        return
      }
      if body.hasPrefix("s/") {
        if let substitution =
          FlashStatusBarTemplateEngine.FormatExpansion.parseSubstitution(body)
        {
          registerOperand(substitution.operand, rawBody: body)
        } else {
          config.addDiagnostic(
            "statusbar.\(path) substitution \"#{\(body)}\" must be #{s/pattern/replacement/:variable}",
            location: config.valueLocations["statusbar.\(path)"])
        }
        return
      }
      if let padding = FlashStatusBarTemplateEngine.FormatExpansion.parsePadding(body) {
        registerOperand(padding.operand, rawBody: body)
        return
      }
      let (token, _) = FlashStatusBarTemplateEngine.parseTokenTruncation(body)
      registerOperand(token, rawBody: body)
    }

    func registerFormatString(_ format: String) {
      var i = format.startIndex
      while i < format.endIndex {
        guard format[i] == "#",
          let next = format.index(i, offsetBy: 1, limitedBy: format.endIndex),
          next < format.endIndex
        else {
          i = format.index(after: i)
          continue
        }
        if format[next] == "#" {
          i = format.index(after: next)
          continue
        }
        if format[next] == "{",
          let close = FlashStatusBarMarkup.matchingBrace(in: format, openingAt: next)
        {
          registerBody(String(format[format.index(after: next)..<close]).trimmed)
          i = format.index(after: close)
          continue
        }
        i = format.index(after: i)
      }
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
        guard let close = FlashStatusBarMarkup.matchingBrace(in: raw, openingAt: open) else {
          config.addDiagnostic(
            "statusbar.\(path) contains an unterminated template variable",
            location: config.valueLocations["statusbar.\(path)"])
          return variables
        }
        let bodyStart = raw.index(after: open)
        registerBody(String(raw[bodyStart..<close]).trimmed)
        index = raw.index(after: close)
        continue
      }
      if raw[index] == "#",
        let aliasIndex = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        aliasIndex < raw.endIndex,
        let token = FlashStatusBarTemplateEngine.tmuxShortFormatToken(for: raw[aliasIndex]),
        let source = parseStatusBarTemplateSource(
          token, sourceURL: sourceURL, commandTimeout: commandTimeout)
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
    sourceURL: URL?,
    commandTimeout: TimeInterval = 6
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

    // Split an optional `=arg` off the kind: `script=30` → ("script", "30").
    // The arg is a per-source poll cadence in seconds (`#{script=30:…}`,
    // `#{command=30:…}`), except for cycle where it is `R` (rotation) or
    // `R/N` (rotation / poll).
    let kindName: String
    let kindArg: String?
    if let eq = kind.firstIndex(of: "=") {
      kindName = String(kind[..<eq])
      kindArg = String(kind[kind.index(after: eq)...])
    } else {
      kindName = kind
      kindArg = nil
    }

    func parsedRefreshSeconds(_ raw: String?) -> TimeInterval?? {
      // Returns .some(nil) for "no arg", .some(value) for a valid arg, and
      // nil (outer) for an invalid arg so callers can reject the token.
      guard let raw else { return .some(nil) }
      guard let value = Int(raw), value > 0 else { return nil }
      return .some(TimeInterval(value))
    }

    func scriptCommand(_ body: String, refreshSeconds: TimeInterval?) -> FlashStatusBarCommand? {
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
        return .script(
          resolved, timeoutSeconds: commandTimeout, refreshSeconds: refreshSeconds)
      }
      return .scriptWithArgs(
        resolved, args: args, timeoutSeconds: commandTimeout, refreshSeconds: refreshSeconds)
    }

    switch kindName {
    case "plugin":
      guard kindArg == nil else { return nil }
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
      guard let refresh = parsedRefreshSeconds(kindArg) else { return nil }
      guard let command = scriptCommand(body, refreshSeconds: refresh) else { return nil }
      return .command(command)
    case "command":
      guard let refresh = parsedRefreshSeconds(kindArg) else { return nil }
      return .command(.shell(body, timeoutSeconds: commandTimeout, refreshSeconds: refresh))
    case "cycle":
      // `#{cycle:path}` rotates its output lines every 60 s; `#{cycle=R:path}`
      // every R seconds. `#{cycle=R/N:path}` additionally re-runs the script
      // every N seconds (default: max(R, [statusbar] interval) — a cycle can't
      // show lines faster than it rotates, so polling faster is waste).
      var period = 60
      var refresh: TimeInterval?
      if let kindArg {
        let pieces = kindArg.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let parsedPeriod = Int(pieces[0]), parsedPeriod > 0 else {
          return nil
        }
        period = parsedPeriod
        if pieces.count == 2 {
          guard let parsedRefresh = Int(pieces[1]), parsedRefresh > 0 else { return nil }
          refresh = TimeInterval(parsedRefresh)
        }
      }
      guard let command = scriptCommand(body, refreshSeconds: refresh) else { return nil }
      return .cycle(command: command, periodSeconds: period)
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
  ) -> Result<ParsedModeMappingValue, ModeMappingValueError> {
    if let table = value.table {
      if let unknown = table.keys.sorted().first(where: { $0 != "action" && $0 != "repeat" }) {
        return .failure(.unknownOption(unknown))
      }
      guard let actionValue = table["action"],
        let action = parseMappingActionValue(actionValue, sourceURL: sourceURL)
      else {
        return .failure(.invalidAction)
      }
      let repeatsOnFinalKey: Bool
      if let repeatValue = table["repeat"] {
        guard let parsed = repeatValue.bool else { return .failure(.invalidRepeat) }
        repeatsOnFinalKey = parsed
      } else {
        repeatsOnFinalKey = false
      }
      return .success(
        ParsedModeMappingValue(action: action, repeatsOnFinalKey: repeatsOnFinalKey))
    }
    guard let action = parseMappingActionValue(value, sourceURL: sourceURL) else {
      return .failure(.invalidShape)
    }
    return .success(ParsedModeMappingValue(action: action, repeatsOnFinalKey: false))
  }

  private static func parseMappingActionValue(
    _ value: any TOMLValueConvertible,
    sourceURL: URL?
  ) -> MappingCommand? {
    guard
      let argv = stringArrayValue(value),
      let head = argv.first,
      !head.isEmpty
    else { return nil }
    // Resolve only the executable head before Flash-command classification.
    // Flash verb args may legitimately contain slashes (`--input=...`,
    // `--name=/Applications/...`) and must not be path-resolved.
    let resolvedHead = resolveCommandArgument(head, sourceURL: sourceURL)
    if mappingCommandHeadNamesFlash(head) || mappingCommandHeadNamesFlash(resolvedHead) {
      return parseMappingCommand(argv: [resolvedHead] + argv.dropFirst())
    }
    let resolved = argv.map { resolveCommandArgument($0, sourceURL: sourceURL) }
    return parseMappingCommand(argv: resolved)
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
