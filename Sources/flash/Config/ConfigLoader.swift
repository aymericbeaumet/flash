import FlashCore
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
    /// Nil for the bundled default. A user file, environment variable, or
    /// other later layer sets the writer the inspector shows on overrides.
    var valueSource: ConfigValueSource?

    init(
      text: String, sourceURL: URL? = nil, diagnosticLabel: String? = nil,
      valueSource: ConfigValueSource? = nil
    ) {
      self.text = text
      self.sourceURL = sourceURL
      self.diagnosticLabel = diagnosticLabel
      self.valueSource = valueSource
    }
  }

  /// The user's configuration file as one read: the path that resolved and
  /// its bytes, nil when it is missing or unreadable. The resident compares
  /// two reads to tell a save from a watcher that only re-armed, and parses
  /// the read it compared.
  struct UserFile: Equatable {
    var url: URL
    var contents: Data?
  }

  static func userFile(environment: [String: String]) -> UserFile {
    let url = resolvePath(environment: environment)
    return UserFile(url: url, contents: try? Data(contentsOf: url))
  }

  /// Production entry point. Layers, in override order (low → high):
  /// the default config embedded in the app bundle, then the user's TOML
  /// file, then environment-variable overrides.
  /// **Precedence (high → low): env var > user TOML > embedded
  /// default TOML > built-in Swift default.** Parsing the embedded default
  /// on every load also revalidates it: any diagnostic it produces is a
  /// Flash bug, and is logged with the file's name. `[plugins.<id>]` tables
  /// are checked against the bundled manifests.
  static func load(_ file: UserFile, environment: [String: String]) -> Config {
    var layers: [Layer] = []
    if let defaults = embeddedDefaultLayer() { layers.append(defaults) }
    if let data = file.contents, let text = String(data: data, encoding: .utf8) {
      let resolved = file.url.resolvingSymlinksInPath()
      let name = resolved.lastPathComponent
      // A file that is itself the bundled default stays the base layer.
      let source: ConfigValueSource? =
        name == "config.default.toml" ? nil : ConfigValueSource(layer: "config", detail: name)
      layers.append(Layer(text: text, sourceURL: resolved, valueSource: source))
    }
    return parseLayers(layers, environment: environment, pluginSettings: .bundled())
  }

  /// The default config bundled into the app (`Resources/config.default.toml`
  /// at build time). nil in unit tests and non-bundle contexts — the Swift
  /// struct defaults then stand alone, as before.
  static func embeddedDefaultLayer(in bundle: Bundle = .main) -> Layer? {
    guard
      let url = bundle.url(forResource: "config.default", withExtension: "toml"),
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
  /// defined it last. `pluginSettings` is what `[plugins.<id>]` tables are
  /// checked against; nil leaves every one unchecked.
  static func parseLayers(
    _ layers: [Layer],
    environment: [String: String] = [:],
    pluginSettings: PluginSettingsCatalog? = nil
  ) -> Config {
    var config = Config()
    var pendingModeMappings: [PendingModeMapping] = []

    for layer in layers + environmentLayers(environment) {
      config.activeValueSource = layer.valueSource
      let diagnosticsBefore = config.diagnostics.count
      let locations = ConfigSourceLocationIndex(text: layer.text)
      do {
        let root = try TOMLTable(string: layer.text)
        apply(
          root: root,
          locations: locations,
          sourceURL: layer.sourceURL,
          pluginSettings: pluginSettings,
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
      for index in diagnosticsBefore..<config.diagnostics.count {
        let diagnostic = config.diagnostics[index]
        config.diagnostics[index] = ConfigDiagnostic(
          message: layer.diagnosticLabel.map { "\($0): \(diagnostic.message)" }
            ?? diagnostic.message,
          location: diagnostic.location,
          file: diagnostic.file ?? layer.sourceURL?.path)
      }
    }
    config.activeValueSource = nil

    // Resolve built-in `<leader>` keys before the file's mappings land.
    // Otherwise a placeholder `<leader>…` and the file's already-resolved
    // key sit side by side, and the later refresh turns them into a duplicate.
    config.mode.refreshLeaderDerivedDefaults()
    applyPendingModeMappings(pendingModeMappings, into: &config)
    applyStatusBarTemplates(into: &config)
    diagnoseMonitors(into: &config)
    diagnoseTelemetry(into: &config)
    config.prepareDerivedValues()
    return config
  }

  private static func apply(
    root: TOMLTable,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pluginSettings: PluginSettingsCatalog?,
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
    applyKeyboard(section("keyboard"), locations: locations, into: &config)
    applyClipboard(section("clipboard"), locations: locations, into: &config)
    applyTiling(section("tiling"), locations: locations, into: &config)
    applyHints(section("hints"), locations: locations, into: &config)
    let plugins = section("plugins")
    applyPlugins(plugins, locations: locations, sourceURL: sourceURL, into: &config)
    applyPluginSettings(plugins, locations: locations, catalog: pluginSettings, into: &config)
    applyStatusBar(
      section("statusbar"), locations: locations, sourceURL: sourceURL, into: &config)
    applyPopups(section("popup"), locations: locations, sourceURL: sourceURL, into: &config)
    applyWidgets(section("widgets"), locations: locations, into: &config)
    applyMonitors(section("monitors"), locations: locations, sourceURL: sourceURL, into: &config)
    applyFlashlight(section("flashlight"), locations: locations, into: &config)
    applyMode(
      section("mode"),
      locations: locations,
      sourceURL: sourceURL,
      pendingModeMappings: &pendingModeMappings,
      into: &config)
    applyWindowRules(root["window_rules"], locations: locations, into: &config)
    applyOverlay(section("overlay"), locations: locations, into: &config)
    applyDebug(section("debug"), locations: locations, into: &config)
    applyTelemetry(section("telemetry"), locations: locations, into: &config)
    applyStartup(section("startup"), locations: locations, sourceURL: sourceURL, into: &config)
    for name in removedSections.keys.sorted() where root[name] != nil {
      config.addDiagnostic(
        "[\(name)] was removed; \(removedSections[name] ?? "")",
        location: locations.location(for: [name]))
    }
    warnUnknownConfigKeys(root: root, locations: locations, into: &config)
  }

  /// Top-level tables Flash no longer reads, with what replaced them. A
  /// file still declaring one is diagnosed where it does, never applied.
  static let removedSections: [String: String] = [
    "macos":
      "Flash no longer writes macOS preferences. Run defaults write (and killall Dock, "
      + "Finder or SystemUIServer) from [startup] run instead; see docs/startup.md"
  ]

  /// A section's table, or a located diagnostic when the key exists with a
  /// non-table value. nil when absent or invalid.
  static func sectionTable(
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
  /// Sections with user-defined keys (`[plugins.<id>]`, and the
  /// `flashlight.aliases`/`flashlight.precedence` subtables) are deliberately
  /// not enumerated. The schema map lives here, in one place, so it can't drift
  /// across the scattered appliers.
  private static func warnUnknownConfigKeys(
    root: TOMLTable,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    warnUnknownKeys(
      in: root, known: topLevelSections.union(removedSections.keys), path: [],
      locations: locations, into: &config)
    for (section, known) in sectionKeys {
      guard let table = root[section]?.table else { continue }
      // A table under `[plugins]` is a plugin's settings, checked by
      // `applyPluginSettings`.
      let known =
        section == "plugins"
        ? known.union(table.keys.filter { table[$0]?.table != nil }) : known
      warnUnknownKeys(in: table, known: known, path: [section], locations: locations, into: &config)
    }
  }

  /// The keys of every section whose keys are fixed. One table for the
  /// loader's unknown-key check and the JSON Schema (`ConfigSchema`).
  static let sectionKeys: [String: Set<String>] = [
    "app": ["menu_bar_icon", "autostart", "keyboard_layout", "updates", "hide_from_capture"],
    "keyboard": ["layout"],
    "clipboard": ["history_size"],
    "tiling": [
      "enabled", "persist", "layout", "orientation", "accordion_padding", "workspaces", "gaps",
      "monitors",
      "rules",
    ],
    "hints": [
      "keys", "min_length", "magic_modifiers", "key_priority", "label_order", "adjust_digits",
      "position_history_size", "position_history_scope", "pointer_follows_focus",
      "pointer_step", "pointer_acceleration", "pointer_max_step",
      "mouse_grid_steps", "mouse_grid_opacity", "mouse_grid_keys", "mouse_grid_cursor_follow",
      "mouse_grid_preview", "restore_pointer",
    ],
    "plugins": pluginsSettingKeys,
    "statusbar": [
      "enabled", "template", "monitor", "interval", "click", "font_size",
      "command_timeout", "notch_margin", "link_schemes", "sources",
    ],
    "flashlight": [
      "suggestion_count", "precedence_alive_bonus", "aliases", "bangs", "precedence",
      "frecency_half_life_days", "frecency_max_boost",
      "live_query_timeout_ms", "ignored_apps", "app_directories",
    ],
    "mode": [
      "labels", "sequence_timeout_ms", "which_key_ms", "normal", "all", "insert", "command",
      "terminal", "hyper",
      "hold", "text", "visual",
      "apps", "layers",
      "scroll_step", "scroll_step_lines", "scroll_page_lines", "move_page_lines",
      "scroll_smooth_ms",
      "click_hold_ms", "send_key_interval_ms",
    ],
    "overlay": [
      "font_size", "hint_fg", "hint_bg_top", "hint_bg_bottom", "hint_border",
      "important_hint_fg", "important_hint_bg_top", "important_hint_bg_bottom",
      "important_hint_border", "window_border", "window_border_size",
      "window_border_color", "alert_duration", "banner_duration_ms", "hint_placement",
      "dark", "click_feedback",
    ],
    "debug": [
      "show_hints_bounds", "hints_bounds_bg", "hints_bounds_fg", "log_level",
      "http_inspector_enabled", "http_inspector_host", "http_inspector_port",
    ],
    "startup": ["run", "timeout"],
  ]

  /// Every top-level table. Plugin settings, popups, widgets and monitors use
  /// user-defined table names; `applyPopups`, `applyWidgets` and
  /// `applyMonitors` check their own keys, as `applyTelemetry` does for its
  /// two subtables.
  static let topLevelSections: Set<String> = Set(sectionKeys.keys).union([
    "popup", "widgets", "monitors", "window_rules", "telemetry",
  ])

  /// Emit a located "unknown config key" diagnostic for every key in `table`
  /// not in `known`, with a Levenshtein "did you mean" when a close match exists.
  static func warnUnknownKeys(
    in table: TOMLTable,
    known: Set<String>,
    path: [String],
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    for key in table.keys where !known.contains(key) {
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
  static func closestKnownKey(to typo: String, in known: Set<String>) -> String? {
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

  /// `[mode.labels]`, `[mode.normal]`, `[mode.layers.<name>]`, a
  /// `[[window_rules]]` entry, and a `[statusbar.sources.<name>]` with a
  /// command or (pushed, `status set`) without one.
  static let modeLabelKeys: Set<String> = [
    "normal", "insert", "command", "terminal", "hyper", "hold", "visual", "visual_line",
  ]
  static let modeNormalKeys: Set<String> = ["leader", "hyper", "mappings"]
  static let modeTextKeys: Set<String> = ["enabled", "mappings"]
  static let layerKeys: Set<String> = ["label", "sticky", "mappings"]
  static let windowRuleKeys: Set<String> = [
    "bundle_id", "title_contains", "position", "x", "y", "width", "height", "screen",
  ]
  static let statusSourceKeys: Set<String> = [
    "command", "working_directory", "env", "interval", "cycle_interval", "history", "output",
  ]
  static let pushedStatusSourceKeys: Set<String> = ["history", "cycle_interval"]
}
