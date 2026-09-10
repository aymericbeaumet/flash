import Foundation
import TOMLKit

enum ConfigLoader {
  /// Every candidate path in lookup order. Used by the config-file
  /// watcher: a watcher per path catches both edits to the active
  /// config AND creation of a higher-precedence one (e.g. user adds
  /// `$XDG_CONFIG_HOME/flash/flash.toml` while running with
  /// `~/.config/flash/flash.toml`).
  static func candidatePaths(environment: [String: String]) -> [URL] {
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

  static func resolvePath(environment: [String: String]) -> URL {
    let candidates = candidatePaths(environment: environment)
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
  /// file, then environment-variable overrides.
  /// **Precedence (high → low): env var > user TOML > embedded
  /// default TOML > built-in Swift default.** Parsing the embedded default
  /// on every launch also revalidates it: any diagnostic it produces is a
  /// Flash bug, and is logged with the file's name.
  static func load() -> Config {
    let env = ProcessInfo.processInfo.environment
    var layers: [Layer] = []
    if let defaults = embeddedDefaultLayer() { layers.append(defaults) }
    let url = resolvePath(environment: env)
    if let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    {
      layers.append(Layer(text: text, sourceURL: url.resolvingSymlinksInPath()))
    }
    return parseLayers(layers, environment: env)
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

    for layer in layers + environmentLayers(environment) {
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

    let terminalNames = Set(config.terminals.keys).union(config.invalidTerminalNames)
    for name in config.statusBar.popups.keys.sorted() where terminalNames.contains(name) {
      let path = "statusbar.popup.\(name)"
      config.addDiagnostic(
        "\(path) is already a terminal name; rename the popup document",
        location: config.valueLocations[path])
      config.statusBar.popups.removeValue(forKey: name)
      config.statusBar.popupSourceURLs.removeValue(forKey: name)
      config.clearLocation(path: path)
    }
    applyPendingModeMappings(pendingModeMappings, into: &config)
    applyStatusBarTemplates(into: &config)
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
    case invalidCommand(String)
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
      case .invalidCommand(let command):
        return "mapping \"\(mappingKey)\": " + URLEventHandler.rejectionMessage(command)
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
    applyTerminals(section("terminal"), locations: locations, sourceURL: sourceURL, into: &config)
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
      "statusbar": [
        "enabled", "template", "monitor", "interval", "click", "font_size",
        "command_timeout", "notch_margin", "popup", "options", "sources", "popup_fg", "popup_bg",
        "popup_border", "popup_border_size", "popup_corner_radius", "popup_padding",
        "popup_max_width", "popup_offset",
      ],
      "flashlight": [
        "suggestion_count", "precedence_alive_bonus", "aliases", "precedence",
        "frecency_half_life_days", "frecency_max_boost",
        "live_query_timeout_ms",
      ],
      "mode": [
        "labels", "sequence_timeout_ms", "normal", "all", "insert", "command", "terminal",
        "scroll_step",
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
    // Plugin settings and terminal declarations use user-defined table names.
    let knownSections = Set(sectionKeys.keys).union(["plugin", "terminal"])
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
      validate: { !$0.trimmed.isEmpty && Alphabet.resolve($0).warning == nil },
      assign: { value, config in
        config.hints.keys = value
      })
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
      // Diagnose unknown tokens instead of silently dropping them, and assign
      // only the recognised ones.
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
      // Retain the defining layer rather than the last layer parsed.
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
    applyDouble(
      table["notch_margin"], path: ["statusbar", "notch_margin"],
      message: "statusbar.notch_margin must be a number between 0 and 64 (points)",
      locations: locations, into: &config, validate: { (0.0...64.0).contains($0) },
      assign: { value, config in
        config.statusBar.notchMargin = value
      })
    applyString(
      table["popup_fg"], path: ["statusbar", "popup_fg"],
      message: "statusbar.popup_fg must be a hex color like #RRGGBB",
      locations: locations, into: &config,
      validate: { $0.count == 7 && isValidHexColor($0) },
      assign: { value, config in config.statusBar.popupStyle.foreground = value })
    applyString(
      table["popup_bg"], path: ["statusbar", "popup_bg"],
      message: "statusbar.popup_bg must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in config.statusBar.popupStyle.background = value })
    applyString(
      table["popup_border"], path: ["statusbar", "popup_border"],
      message: "statusbar.popup_border must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in config.statusBar.popupStyle.borderColor = value })
    applyDouble(
      table["popup_border_size"], path: ["statusbar", "popup_border_size"],
      message: "statusbar.popup_border_size must be a number between 0 and 12 (points)",
      locations: locations, into: &config, validate: { (0...12).contains($0) },
      assign: { value, config in config.statusBar.popupStyle.borderWidth = value })
    applyDouble(
      table["popup_corner_radius"], path: ["statusbar", "popup_corner_radius"],
      message: "statusbar.popup_corner_radius must be a number between 0 and 64 (points)",
      locations: locations, into: &config, validate: { (0...64).contains($0) },
      assign: { value, config in config.statusBar.popupStyle.cornerRadius = value })
    applyDouble(
      table["popup_padding"], path: ["statusbar", "popup_padding"],
      message: "statusbar.popup_padding must be a number between 0 and 64 (points)",
      locations: locations, into: &config, validate: { (0...64).contains($0) },
      assign: { value, config in config.statusBar.popupStyle.padding = value })
    applyDouble(
      table["popup_max_width"], path: ["statusbar", "popup_max_width"],
      message: "statusbar.popup_max_width must be a number between 80 and 2000 (points)",
      locations: locations, into: &config, validate: { (80...2_000).contains($0) },
      assign: { value, config in config.statusBar.popupStyle.maxWidth = value })
    applyDouble(
      table["popup_offset"], path: ["statusbar", "popup_offset"],
      message: "statusbar.popup_offset must be a number between 0 and 64 (points)",
      locations: locations, into: &config, validate: { (0...64).contains($0) },
      assign: { value, config in config.statusBar.popupStyle.offset = value })
    if let popups = sectionTable(
      table["popup"], name: "statusbar.popup", locations: locations, into: &config)
    {
      for (name, value) in popups {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let location = locations.location(for: ["statusbar", "popup", name])
        guard !trimmedName.isEmpty else { continue }
        guard let template = value.string else {
          config.addDiagnostic(
            "statusbar.popup.\(name) must be a template string; declare commands in [terminal.\(name)]",
            location: location)
          continue
        }
        config.statusBar.popups[trimmedName] = FlashStatusBarTemplate(
          template: template, variables: [])
        if let sourceURL { config.statusBar.popupSourceURLs[trimmedName] = sourceURL }
        config.recordLocation(path: "statusbar.popup.\(trimmedName)", location: location)
      }
    }
    applyStatusBarOptionsAndSources(
      table, locations: locations, sourceURL: sourceURL, into: &config)
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

  private static func statusProcessInteger(
    _ table: TOMLTable, key: String, fallback: Int, range: ClosedRange<Int>,
    path: String, location: ConfigLocation?, into config: inout Config
  ) -> Int? {
    guard let value = table[key] else { return fallback }
    guard let integer = value.int ?? value.double.flatMap({ Int(exactly: $0) }),
      range.contains(integer)
    else {
      config.addDiagnostic(
        "\(path).\(key) must be an integer between \(range.lowerBound) and \(range.upperBound)",
        location: location)
      return nil
    }
    return integer
  }

  private static func parseStatusProcess(
    _ table: TOMLTable, path: String, sourceURL: URL?, allowedKeys: Set<String>,
    location: ConfigLocation?, into config: inout Config
  ) -> (command: [String], workingDirectory: String?, environment: [String: String])? {
    func invalid(_ message: String) {
      config.addDiagnostic("\(path) \(message)", location: location)
    }
    if let key = table.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
      invalid("contains unknown key \"\(key)\"")
      return nil
    }
    guard let values = table["command"]?.array, !values.isEmpty,
      values.allSatisfy({ $0.string != nil }),
      let head = values.first?.string, !head.isEmpty
    else {
      invalid("command must be a nonempty array of strings")
      return nil
    }
    let command =
      [head.hasPrefix("$") ? head : resolveCommandArgument(head, sourceURL: sourceURL)]
      + values.dropFirst().compactMap(\.string)
    guard command.allSatisfy({ !$0.utf8.contains(0) }) else {
      invalid("command must not contain NUL bytes")
      return nil
    }
    var directory: String?
    if let value = table["working_directory"] {
      guard let raw = value.string, !raw.isEmpty, !raw.utf8.contains(0) else {
        invalid("working_directory must be a nonempty path string")
        return nil
      }
      directory =
        raw.hasPrefix("$")
        ? raw
        : resolveCommandArgument(
          raw.hasPrefix("/") || raw.hasPrefix("~") ? raw : "./" + raw,
          sourceURL: sourceURL)
    }
    var environment: [String: String] = [:]
    if let value = table["env"] {
      guard let entries = value.table else {
        invalid("env must be a table of strings")
        return nil
      }
      for (key, entry) in entries {
        guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0),
          let string = entry.string, !string.utf8.contains(0)
        else {
          invalid("env must have valid environment names and string values")
          return nil
        }
        environment[key] = string
      }
    }
    return (command, directory, environment)
  }

  private static func applyStatusBarOptionsAndSources(
    _ table: TOMLTable, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    if let options = sectionTable(
      table["options"], name: "statusbar.options", locations: locations, into: &config)
    {
      for (key, value) in options {
        guard let string = value.string else {
          config.addDiagnostic(
            "statusbar.options.\(key) must be a string",
            location: locations.location(for: ["statusbar", "options", key]))
          continue
        }
        config.statusBar.options[key] = string
      }
    }
    guard
      let sources = sectionTable(
        table["sources"], name: "statusbar.sources", locations: locations, into: &config)
    else { return }
    for (name, value) in sources {
      let path = "statusbar.sources.\(name)"
      let location = locations.location(for: ["statusbar", "sources", name])
      guard let definition = value.table else {
        config.addDiagnostic("\(path) must be a table with command argv", location: location)
        continue
      }
      guard
        let parsed = parseStatusProcess(
          definition, path: path, sourceURL: sourceURL,
          allowedKeys: ["command", "working_directory", "env", "interval", "cycle_interval"],
          location: location, into: &config),
        let interval = statusProcessInteger(
          definition, key: "interval",
          fallback: Int(config.statusBar.refreshIntervalSeconds), range: 0...86400,
          path: path, location: location, into: &config)
      else { continue }
      var cycle: Double?
      if definition["cycle_interval"] != nil {
        guard
          let seconds = statusProcessInteger(
            definition, key: "cycle_interval", fallback: 60,
            range: 1...86400, path: path, location: location, into: &config)
        else { continue }
        cycle = Double(seconds)
      }
      config.statusBar.sources[name] = FlashStatusBarSourceDefinition(
        command: parsed.command, workingDirectory: parsed.workingDirectory,
        environment: parsed.environment, intervalSeconds: Double(interval),
        cycleIntervalSeconds: cycle, timeoutSeconds: config.statusBar.commandTimeoutSeconds)
      if definition["interval"] == nil {
        config.statusBar.sourcesUsingDefaultInterval.insert(name)
      } else {
        config.statusBar.sourcesUsingDefaultInterval.remove(name)
      }
    }
  }

  private static func applyTerminals(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    for (name, value) in table {
      let path = "terminal.\(name)"
      let location = locations.location(for: ["terminal", name])
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        config.addDiagnostic(
          "terminal names must be nonempty and contain no control characters", location: location)
        continue
      }
      guard let definition = value.table else {
        config.addDiagnostic("\(path) must be a table with command argv", location: location)
        config.invalidTerminalNames.insert(name)
        continue
      }
      guard definition["persistent"] == nil || definition["persistent"]?.bool != nil else {
        config.addDiagnostic("\(path).persistent must be a boolean", location: location)
        config.invalidTerminalNames.insert(name)
        continue
      }
      guard
        let parsed = parseStatusProcess(
          definition, path: path, sourceURL: sourceURL,
          allowedKeys: ["command", "working_directory", "env", "columns", "rows", "persistent"],
          location: location, into: &config),
        let columns = statusProcessInteger(
          definition, key: "columns", fallback: 100, range: 1...1000,
          path: path, location: location, into: &config),
        let rows = statusProcessInteger(
          definition, key: "rows", fallback: 28, range: 1...1000,
          path: path, location: location, into: &config)
      else {
        config.invalidTerminalNames.insert(name)
        continue
      }
      config.terminals[name] = .init(
        command: parsed.command, workingDirectory: parsed.workingDirectory,
        environment: parsed.environment, columns: columns, rows: rows,
        persistent: definition["persistent"]?.bool ?? false)
      config.invalidTerminalNames.remove(name)
      config.recordLocation(path: path, location: location)
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
      table["live_query_timeout_ms"], path: ["flashlight", "live_query_timeout_ms"],
      message: "flashlight.live_query_timeout_ms must be an integer between 50 and 5000 (ms)",
      locations: locations, into: &config, validate: { (50...5_000).contains($0) },
      assign: { value, config in
        config.flashlight.liveQueryTimeoutMs = value
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
        (1...32).contains(command.count),
        (1...32).contains((parsed["terminal"] ?? config.mode.labels.terminal).count)
      {
        for key in parsed.keys where !["normal", "insert", "command", "terminal"].contains(key) {
          config.addDiagnostic(
            "mode.labels: unknown key '\(key)' (valid keys are normal, insert, command, terminal)",
            location: location)
        }
        config.mode.labels = Config.Mode.Labels(
          normal: normal,
          insert: insert,
          command: command,
          terminal: parsed["terminal"] ?? config.mode.labels.terminal)
        config.recordLocation(path: "mode.labels", location: location)
      } else {
        config.addDiagnostic(
          "mode.labels must be { normal = \"...\", insert = \"...\", command = \"...\", terminal = \"...\" } "
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
      applyModeMappingTable(
        sectionTable(
          normal["mappings"], name: "mode.normal.mappings", locations: locations, into: &config),
        scope: .normal,
        path: ["mode", "normal", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in normal where key != "leader" && key != "mappings" {
        config.addDiagnostic(
          "mode.normal: unknown key '\(key)' — mappings belong under "
            + "[mode.normal.mappings]; valid keys are leader, mappings",
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

    for scope in [ModeScope.insert, .terminal] {
      let name = scope.rawValue
      guard
        let scoped = sectionTable(
          table[name], name: "mode.\(name)", locations: locations, into: &config)
      else { continue }
      applyModeMappingTable(
        sectionTable(
          scoped["mappings"], name: "mode.\(name).mappings", locations: locations, into: &config),
        scope: scope,
        path: ["mode", name, "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in scoped where key != "mappings" {
        config.addDiagnostic(
          "mode.\(name): unknown key '\(key)' — mappings belong under [mode.\(name).mappings]",
          location: locations.location(for: ["mode", name, key]))
      }
    }

    if let command = sectionTable(
      table["command"], name: "mode.command", locations: locations, into: &config)
    {
      applyModeMappingTable(
        sectionTable(
          command["mappings"], name: "mode.command.mappings", locations: locations, into: &config),
        scope: .command,
        path: ["mode", "command", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in command where key != "mappings" {
        config.addDiagnostic(
          "mode.command: unknown key '\(key)' — mappings belong under [mode.command.mappings]",
          location: locations.location(for: ["mode", "command", key]))
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
      message:
        "overlay.window_border_size must be a number between 0 and 20 (points; 0 keeps the per-mode defaults)",
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
    case .terminal:
      config.mode.terminal.removeAll { $0.key == key }
      config.mode.terminal.append(mapping)
    case .command:
      config.mode.command.removeAll { $0.key == key }
      config.mode.command.append(mapping)
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
      if mapping.scope == .command,
        ModeMapping(key: key, action: mapping.action).nativeHotkey == nil
      {
        config.addDiagnostic(
          "mapping \"\(mapping.rawKey)\" in [mode.command.mappings] must be a single modified key",
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

  private static func applyStatusBarTemplates(into config: inout Config) {
    for name in config.statusBar.sources.keys {
      if config.statusBar.sourcesUsingDefaultInterval.contains(name) {
        config.statusBar.sources[name]?.intervalSeconds = config.statusBar.refreshIntervalSeconds
      }
      config.statusBar.sources[name]?.timeoutSeconds = config.statusBar.commandTimeoutSeconds
    }
    var optionDependencies = StatusFormatDependencies()
    for name in config.statusBar.options.keys.sorted() {
      let program = StatusFormatProgram.compile(
        source: config.statusBar.options[name] ?? "",
        origin: StatusFormatOrigin("statusbar.options.\(name)"))
      recordStatusFormatDiagnostics(program, path: "options.\(name)", into: &config)
      optionDependencies.formUnion(program.dependencies)
    }
    func compiled(_ text: String, path: String, into config: inout Config) -> FlashStatusBarTemplate
    {
      let program = StatusFormatProgram.compile(
        source: text, origin: StatusFormatOrigin("statusbar.\(path)"))
      recordStatusFormatDiagnostics(program, path: path, into: &config)
      var dependencies = program.dependencies
      dependencies.formUnion(optionDependencies)
      var variables: [FlashStatusBarTemplateVariable] = []
      for token in dependencies.values.sorted() {
        let source: FlashStatusBarSource?
        if let sdk = FlashStatusBarTemplateEngine.sdkValue(for: token) {
          source = .sdk(sdk)
        } else if token.hasPrefix("flash.plugin.") {
          let field = String(token.dropFirst("flash.plugin.".count))
          switch field {
          case "loaded_count": source = .plugin(.loadedCount)
          case "ready_count": source = .plugin(.readyCount)
          case "error_count": source = .plugin(.errorCount)
          default:
            if let dot = field.lastIndex(of: "."), dot != field.startIndex,
              field.index(after: dot) < field.endIndex
            {
              source = .plugin(
                .statusSegment(
                  pluginID: String(field[..<dot]),
                  name: String(field[field.index(after: dot)...])))
            } else {
              source = nil
              config.addDiagnostic(
                "statusbar.\(path) has invalid plugin value \(token)",
                location: config.valueLocations["statusbar.\(path)"])
            }
          }
        } else if token.hasPrefix("flash.source.") {
          source = nil
          let name = String(token.dropFirst("flash.source.".count))
          if config.statusBar.sources[name] == nil {
            config.addDiagnostic(
              "statusbar.\(path) references undefined source \(name)",
              location: config.valueLocations["statusbar.\(path)"])
          }
        } else {
          source = nil
          if token.hasPrefix("flash.") {
            config.addDiagnostic(
              "statusbar.\(path) has unknown Flash value \(token)",
              location: config.valueLocations["statusbar.\(path)"])
          }
        }
        if let source {
          variables.append(.init(id: "statusbar.\(path).\(token)", token: token, source: source))
        }
      }
      return FlashStatusBarTemplate(
        template: text, variables: variables,
        options: config.statusBar.options, sourceNames: Set(config.statusBar.sources.keys),
        origin: StatusFormatOrigin("statusbar.\(path)"))
    }
    let normalized = FlashStatusBarTemplateEngine.normalizedTemplate(
      config.statusBar.template.template)
    config.statusBar.template = compiled(normalized, path: "template", into: &config)
    for name in config.statusBar.popups.keys.sorted() {
      guard let popup = config.statusBar.popups[name] else { continue }
      let text = popup.template.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      config.statusBar.popups[name] = compiled(text, path: "popup.\(name)", into: &config)
    }
  }

  private static func recordStatusFormatDiagnostics(
    _ program: StatusFormatProgram, path: String, into config: inout Config
  ) {
    for diagnostic in program.diagnostics {
      config.addDiagnostic(
        "statusbar.\(path): \(diagnostic.message) (format byte \(diagnostic.span.bytes.lowerBound))",
        location: config.valueLocations["statusbar.\(path)"])
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
        if let actionValue = table["action"], let argv = stringArrayValue(actionValue),
          !argv.isEmpty
        {
          return .failure(.invalidCommand(argv.joined(separator: " ")))
        }
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
      if let argv = stringArrayValue(value), let head = argv.first, !head.isEmpty {
        return .failure(.invalidCommand(argv.joined(separator: " ")))
      }
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
    return parseMappingCommand(argv: [resolvedHead] + argv.dropFirst())
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
