import Foundation
import FlashCore

struct PluginReference: Equatable {
  enum Kind: Equatable {
    case github(owner: String, repository: String)
    case file(path: String)
  }

  var raw: String
  var kind: Kind

  static func parse(_ raw: String, sourceURL: URL? = nil) -> PluginReference? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("github:") {
      let slug = String(trimmed.dropFirst("github:".count))
      let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
      return PluginReference(raw: trimmed, kind: .github(owner: parts[0], repository: parts[1]))
    }
    if trimmed.hasPrefix("file:") {
      let rawPath = String(trimmed.dropFirst("file:".count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rawPath.isEmpty else { return nil }
      let expanded = (rawPath as NSString).expandingTildeInPath
      let resolved: String
      if expanded.hasPrefix("/") {
        resolved = expanded
      } else if let sourceURL {
        resolved = sourceURL.deletingLastPathComponent()
          .appendingPathComponent(expanded)
          .standardizedFileURL
          .path
      } else {
        resolved = expanded
      }
      return PluginReference(raw: trimmed, kind: .file(path: resolved))
    }
    return nil
  }
}

struct ConfigLocation: Equatable {
  let line: Int
  let column: Int
}

struct ConfigDiagnostic: Equatable {
  let message: String
  let location: ConfigLocation?

  var logMessage: String {
    guard let location else { return message }
    return "line \(location.line), col \(location.column): \(message)"
  }

  var alertLine: String { logMessage }
}

struct Config {
  struct Hints {
    var keys: String = Alphabet.defaultKeys
    var minLength: Int = 1
    var magicModifiers: [String] = ["cmd", "ctrl", "alt", "shift"]
    /// Number of selection steps for `flash://mouse_grid`. Larger values
    /// give finer precision but require more keystrokes per click.
    var mouseGridSteps: Int = 3
    /// Opacity (0.0..1.0) applied to every mouse-grid chip so the user
    /// can still see what's underneath the precision overlay. 1.0 is
    /// fully opaque, 0.0 invisible. Default 0.5 — the underlying window
    /// stays clearly visible through the precision grid.
    var mouseGridOpacity: Double = 0.5
  }
  struct Overlay {
    var fontSize: Double = 12
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Set this equal to
    /// `hintBGBottom` for a flat fill.
    var hintBGTop: String = "#FFF785"
    /// Bottom stop of the chip's vertical gradient.
    var hintBGBottom: String = "#FFC542"
    /// 1px border around the chip.
    var hintBorder: String = "#E3BE23"
  }
  struct Debug {
    /// When true, every detected target is outlined alongside its hint chip.
    /// Useful for diagnosing missing or misplaced hints — you can see exactly
    /// which AX rect Flash decided to use.
    var showHintsBounds: Bool = false
    /// Fill for the debug outline rectangle. Default transparent.
    var hintsBoundsBG: String = "#00000000"
    /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
    /// it's the foreground colour of the bounds shape.
    var hintsBoundsFG: String = "#FF3B9A"
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `trace` while investigating a
    /// stuck-mode/input issue, `debug` for broader diagnostics, or
    /// `warn` / `error` / `fatal` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
    /// When true, Flash binds a loopback-only HTTP server that exposes
    /// live logs + state inspection. Off by default — turn on with
    /// `debug.http_inspector_enabled = true`.
    var httpInspectorEnabled: Bool = false
    /// Loopback hostname the inspector binds on. Restricted to
    /// `localhost` / `127.0.0.1` / `::1` (validated at start).
    var httpInspectorHost: String = "localhost"
    /// TCP port the inspector listens on.
    var httpInspectorPort: Int = 4242
  }
  struct Open {
    var ignoredApps: [String] = []
  }
  struct Plugins {
    /// Third-party plugins explicitly requested by the user. Official
    /// bundled plugins are always enabled in v1 and are discovered from
    /// the app bundle, not this list.
    var thirdParty: [PluginReference] = []
    /// When true (the default), each plugin's directory tree is watched
    /// and any file change triggers a plugin reload. Set to false to
    /// disable hot-reload — useful if a plugin keeps a noisy log
    /// somewhere in its tree that would otherwise restart-loop it.
    var watchingEnabled: Bool = true
  }
  struct Mode {
    struct Labels: Equatable {
      var normal: String = "NORMAL"
      var insert: String = "INSERT"
      var command: String = "COMMAND"

      var longestCount: Int {
        max(normal.count, insert.count, command.count)
      }
    }

    var all: [ModeMapping] = []
    var normal: [ModeMapping] = Self.defaultNormalMappings
    var insert: [ModeMapping] = []
    var normalLeader: String? = Self.defaultNormalLeader
    var labels = Labels()
    /// How long the interpreter waits for the next key in a pending
    /// sequence before resolving the longest matching prefix.
    /// Vim's `timeoutlen`. Lower → faster commits, more two-key
    /// collisions; higher → slower commits, fewer surprises.
    var sequenceTimeoutMs: Int = Self.defaultSequenceTimeoutMs
    static let defaultSequenceTimeoutMs = 300

    /// Single-atom key form, parsed via `NormalModeInterpreter.parseKeySequence`.
    /// Use `\` bare or `<backslash>` — both resolve to the same key.
    static let defaultNormalLeader = "\\"

    static let defaultNormalMappings: [ModeMapping] = makeDefaultNormalMappings()

    private static func makeDefaultNormalMappings() -> [ModeMapping] {
      // Bare punctuation is allowed by the parser; defaults stay
      // concise. Use `<name>` only for keys that can't be typed bare
      // (`<leader>`, `<space>`) or for emphasis on a non-obvious key.
      var raw: [(String, MappingCommand)] = [
        ("h", .flashCommand(.scroll(.left))),
        ("j", .flashCommand(.scroll(.down))),
        ("k", .flashCommand(.scroll(.up))),
        ("l", .flashCommand(.scroll(.right))),
        ("ctrl+e", .flashCommand(.scroll(.down))),
        ("ctrl+y", .flashCommand(.scroll(.up))),
        ("ctrl+d", .flashCommand(.scroll(.halfPageDown))),
        ("ctrl+u", .flashCommand(.scroll(.halfPageUp))),
        ("gg", .flashCommand(.scroll(.top))),
        ("G", .flashCommand(.scroll(.bottom))),
        ("[h", .flashCommand(.historyBack)),
        ("]h", .flashCommand(.historyForward)),
        ("[t", .flashCommand(.tabPrev)),
        ("]t", .flashCommand(.tabNext)),
        ("[a", .flashCommand(.appPrev)),
        ("]a", .flashCommand(.appNext)),
        // Shadow the system app switcher so the user stays inside
        // Flash's normal-mode loop. Carbon registration is scope-bound:
        // entering insert mode unregisters the binding and the Dock
        // switcher works as usual.
        ("cmd+tab", .flashCommand(.appNext)),
        ("cmd+shift+tab", .flashCommand(.appPrev)),
        // First / last tab. Vim-style `g^` / `g$` borrowed from
        // line-extreme motions: `^` is the first non-blank, `$` is the
        // end of line. Browsers translate to ⌘1 / ⌘9 (the cross-vendor
        // convention for first / last tab); plugin sources receive the
        // `tab_first` / `tab_last` source action.
        ("g^", .flashCommand(.tabFirst)),
        ("g$", .flashCommand(.tabLast)),
        ("g1", .flashCommand(.tabSelect(index: 1))),
        ("g2", .flashCommand(.tabSelect(index: 2))),
        ("g3", .flashCommand(.tabSelect(index: 3))),
        ("g4", .flashCommand(.tabSelect(index: 4))),
        ("g5", .flashCommand(.tabSelect(index: 5))),
        ("g6", .flashCommand(.tabSelect(index: 6))),
        ("g7", .flashCommand(.tabSelect(index: 7))),
        ("g8", .flashCommand(.tabSelect(index: 8))),
        ("g9", .flashCommand(.tabSelect(index: 9))),
        ("ctrl+o", .flashCommand(.appPrev)),
        ("ctrl+i", .flashCommand(.appNext)),
        ("gt", .flashCommand(.tabNext)),
        ("gT", .flashCommand(.tabPrev)),
        ("i", .flashCommand(.insertMode)),
        ("f", .flashCommand(.mouseTarget(.click(.leftClick)))),
        ("rf", .flashCommand(.mouseTarget(.click(.rightClick)))),
        ("df", .flashCommand(.mouseTarget(.click(.doubleClick)))),
        ("mf", .flashCommand(.mouseTarget(.move))),
        ("F", .flashCommand(.mouseGrid(.click(.leftClick)))),
        ("rF", .flashCommand(.mouseGrid(.click(.rightClick)))),
        ("dF", .flashCommand(.mouseGrid(.click(.doubleClick)))),
        ("mF", .flashCommand(.mouseGrid(.move))),
        ("u", .flashCommand(.undo)),
        ("ctrl+r", .flashCommand(.redo)),
        ("x", .flashCommand(.close)),
        ("n", .flashCommand(.newWindow)),
        ("t", .flashCommand(.tabNewInsert)),
        ("/", .flashCommand(.find)),
        ("<leader><space>", .flashCommand(.flashlight)),
        ("r", .flashCommand(.reload(force: false))),
        ("R", .flashCommand(.reload(force: true))),
        ("?", .flashCommand(.showUsage(topic: nil))),
        (":", .flashCommand(.commandMode)),
      ]
      // Vim-style marks: `m<letter>` sets, `` `<letter> `` jumps.
      // Generated rather than hand-listed so the 52 mappings (26+26)
      // stay in sync if more letter ranges are added later.
      for letter in "abcdefghijklmnopqrstuvwxyz" {
        let l = String(letter)
        raw.append(("m\(l)", .flashCommand(.setMark(letter: l))))
        raw.append(("`\(l)", .flashCommand(.jumpToMark(letter: l))))
      }
      return raw.map { (key, action) in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("default mapping key \"\(key)\" failed canonicalization")
        }
        return ModeMapping(key: canonical, action: action)
      }
    }

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return all + normal
      case .insert:
        return all + insert
      }
    }

    /// O(1)-lookup view used on every keystroke. Refreshed by
    /// `prepareDerivedValues()` after every config load / reload.
    private(set) var compiledNormal = CompiledMappings()
    private(set) var compiledInsert = CompiledMappings()

    func compiledMappings(for mode: FlashMode) -> CompiledMappings {
      switch mode {
      case .normal: return compiledNormal
      case .insert: return compiledInsert
      }
    }

    mutating func recompileMappings() {
      compiledNormal = CompiledMappings(mappings(for: .normal))
      compiledInsert = CompiledMappings(mappings(for: .insert))
    }

    mutating func refreshLeaderDerivedDefaults() {
      let leaderRaw = normalLeader ?? Self.defaultNormalLeader
      guard let leaderInternal = NormalModeInterpreter.translateLeader(leaderRaw) else { return }
      for index in normal.indices where normal[index].key.contains("<leader>") {
        let mapping = normal[index]
        let resolved = mapping.key.replacingOccurrences(of: "<leader>", with: leaderInternal)
        normal[index] = ModeMapping(key: resolved, action: mapping.action)
      }
    }

    var containsNormalModeMapping: Bool {
      (all + normal + insert).contains { mapping in
        mapping.action.command == .normalMode
      }
    }

    var containsAdvancedModeMapping: Bool {
      all.contains { mapping in
        mapping.action.command == .normalMode
      }
    }
  }

  var hints = Hints()
  var overlay = Overlay()
  var open = Open()
  var plugins = Plugins()
  var mode = Mode()
  var debug = Debug()
  var diagnostics: [ConfigDiagnostic] = []
  /// Plain-string view over `diagnostics`. Existed as a parallel
  /// mutable field; collapsed to a computed projection so the two
  /// can't drift.
  var warnings: [String] { diagnostics.map(\.message) }
  var valueLocations: [String: ConfigLocation] = [:]
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env/CLI
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)

  static let `default`: Config = {
    var config = Config()
    config.prepareDerivedValues()
    return config
  }()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func recordLocation(path: String, location: ConfigLocation?) {
    valueLocations[path] = location
  }

  mutating func clearLocation(path: String) {
    valueLocations.removeValue(forKey: path)
  }

  mutating func addDiagnostic(_ message: String, location: ConfigLocation? = nil) {
    diagnostics.append(ConfigDiagnostic(message: message, location: location))
  }

  mutating func removeDiagnostics(where predicate: (String) -> Bool) {
    diagnostics.removeAll { predicate($0.message) }
  }

  mutating func prepareDerivedValues() {
    mode.refreshLeaderDerivedDefaults()
    resolvedAlphabet = Alphabet.resolve(hints.keys)
    removeAmbiguousShiftMagicModifier()
    mode.recompileMappings()
  }

  private mutating func removeAmbiguousShiftMagicModifier() {
    guard resolvedAlphabet.chars.contains(where: { !$0.isLetter }) else {
      removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
      return
    }
    let original = hints.magicModifiers
    hints.magicModifiers.removeAll { $0.lowercased() == "shift" }
    guard original.count != hints.magicModifiers.count else { return }
    removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
    addDiagnostic(
      "hints.magic_modifiers includes \"shift\", but resolved hints.keys "
        + "contains non-letter characters (\(String(resolvedAlphabet.chars))); "
        + "removed \"shift\" because shifted-character input is ambiguous",
      location: valueLocations["hints.keys"] ?? valueLocations["hints.magic_modifiers"]
    )
  }

  var resolvedConfigJSON: String {
    let modeJSON: [String: Any] = [
      "all": mode.all.map(Self.mappingJSONValue),
      "insert": mode.insert.map(Self.mappingJSONValue),
      "labels": [
        "command": mode.labels.command,
        "insert": mode.labels.insert,
        "normal": mode.labels.normal,
      ],
      "normal": mode.normal.map(Self.mappingJSONValue),
      "normal_leader": mode.normalLeader ?? NSNull(),
    ]
    return compactJSON([
      "debug": [
        "hints_bounds_bg": debug.hintsBoundsBG,
        "hints_bounds_fg": debug.hintsBoundsFG,
        "http_inspector_enabled": debug.httpInspectorEnabled,
        "http_inspector_host": debug.httpInspectorHost,
        "http_inspector_port": debug.httpInspectorPort,
        "log_level": debug.logLevel.name,
        "show_hints_bounds": debug.showHintsBounds,
      ],
      "hints": [
        "keys": hints.keys,
        "magic_modifiers": hints.magicModifiers,
        "min_length": hints.minLength,
        "mouse_grid_opacity": hints.mouseGridOpacity,
        "mouse_grid_steps": hints.mouseGridSteps,
      ],
      "mode": modeJSON,
      "open": [
        "ignored_apps": open.ignoredApps
      ],
      "overlay": [
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
      ],
      "plugins": [
        "third_party": plugins.thirdParty.map(\.raw),
        "watching_enabled": plugins.watchingEnabled,
      ],
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "action": mapping.action.configValue,
      "key": mapping.key,
    ]
  }

  var resolvedHintsKeysJSON: String {
    let scores = Dictionary(
      uniqueKeysWithValues: resolvedAlphabet.keyScores.map { (String($0.key), $0.value) }
    )
    return compactJSON([
      "chars": String(resolvedAlphabet.chars),
      "chars_array": resolvedAlphabet.chars.map(String.init),
      "default": Alphabet.defaultKeys,
      "key_scores": scores,
      "layout": resolvedAlphabet.layoutName ?? NSNull(),
      "left_hand": String(resolvedAlphabet.leftHand.sorted()),
      "raw": hints.keys,
      "warning": resolvedAlphabet.warning ?? NSNull(),
    ])
  }

  var loadingDiagnostics: [ConfigDiagnostic] {
    var diagnostics = self.diagnostics
    if let warning = resolvedAlphabet.warning {
      diagnostics.append(
        ConfigDiagnostic(
          message: warning,
          location: valueLocations["hints.keys"]))
    }
    return diagnostics
  }

  var loadingErrorAlertMessage: String? {
    let diagnostics = loadingDiagnostics
    guard !diagnostics.isEmpty else { return nil }
    let visibleDiagnostics = diagnostics.prefix(3).map { "- \($0.alertLine)" }
    var lines = ["[Flash]", diagnostics.count == 1 ? "Config error" : "Config errors"]
    lines.append(contentsOf: visibleDiagnostics)
    let remaining = diagnostics.count - visibleDiagnostics.count
    if remaining > 0 {
      lines.append("- \(remaining) more config issue\(remaining == 1 ? "" : "s")")
    }
    return lines.joined(separator: "\n")
  }

  private func compactJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }
}

extension URLCommand {
  var diagnosticDescription: String {
    switch self {
    case .mouseTarget(let command):
      return "flash://mouse_target\(command.querySuffix)"
    case .mouseGrid(let command):
      return "flash://mouse_grid\(command.querySuffix)"
    case .normalMode:
      return "flash://mode_normal"
    case .insertMode:
      return "flash://mode_insert"
    case .commandMode:
      return "flash://mode_command"
    case .scroll(let kind):
      switch kind {
      case .left: return "flash://scroll_left"
      case .right: return "flash://scroll_right"
      case .up: return "flash://scroll_up"
      case .down: return "flash://scroll_down"
      case .halfPageUp: return "flash://scroll_half_page_up"
      case .halfPageDown: return "flash://scroll_half_page_down"
      case .top: return "flash://scroll_top"
      case .bottom: return "flash://scroll_bottom"
      }
    case .reload(let force):
      return force ? "flash://app_reload?force=1" : "flash://app_reload"
    case .undo:
      return "flash://app_undo"
    case .redo:
      return "flash://app_redo"
    case .close:
      return "flash://window_close"
    case .tabClose:
      return "flash://tab_close"
    case .find:
      return "flash://app_find"
    case .candidateFinder(let all):
      return all ? "flash://app_open_finder?all=1" : "flash://app_open_finder"
    case .flashlight:
      return "flash://flashlight"
    case .emojiPicker:
      return "flash://emojis"
    case .copyURL:
      return "flash://url_copy"
    case .tabNext:
      return "flash://tab_next"
    case .tabPrev:
      return "flash://tab_previous"
    case .tabFirst:
      return "flash://tab_first"
    case .tabLast:
      return "flash://tab_last"
    case .tabSelect(let index):
      if let index {
        return "flash://tab_select?index=\(index)"
      }
      return "flash://tab_select"
    case .historyBack:
      return "flash://history_back"
    case .historyForward:
      return "flash://history_forward"
    case .movementBack:
      return "flash://movement_back"
    case .movementForward:
      return "flash://movement_forward"
    case .appPrev:
      return "flash://app_previous"
    case .appNext:
      return "flash://app_next"
    case .setMark(let letter):
      return "flash://set_mark?letter=\(letter)"
    case .jumpToMark(let letter):
      return "flash://jump_to_mark?letter=\(letter)"
    case .quitApp(let force):
      return force ? "flash://app_quit?force=1" : "flash://app_quit"
    case .save:
      return "flash://app_save"
    case .saveAndQuit(let force):
      return force ? "flash://app_save_and_quit?force=1" : "flash://app_save_and_quit"
    case .print:
      return "flash://app_print"
    case .openDocument:
      return "flash://document_open"
    case .newWindow:
      return "flash://window_new"
    case .tabNew:
      return "flash://tab_new"
    case .tabNewInsert:
      return "flash://tab_new_insert"
    case .copy:
      return "flash://clipboard_copy"
    case .cut:
      return "flash://clipboard_cut"
    case .paste:
      return "flash://clipboard_paste"
    case .copyAll:
      return "flash://clipboard_copy_all"
    case .showAlert(let message):
      return "flash://alert_show?message=\(message)"
    case .dismissAlert:
      return "flash://alert_dismiss"
    case .showUsage(let topic):
      if let topic, !topic.isEmpty {
        return "flash://help_show?topic=\(topic)"
      }
      return "flash://help_show"
    case .showPlugins:
      return "flash://plugins"
    case .dismissHints:
      return "flash://hints_dismiss"
    case .quit:
      return "flash://flash_quit"
    case .openApp(let name):
      return "flash://app_open?name=\(name)"
    case .pluginAction(let command, let name, let args):
      var parts = ["command=\(command)", "name=\(name)"]
      if !args.isEmpty {
        parts.append("args=\(args.joined(separator: " "))")
      }
      return "flash://plugin_action?\(parts.joined(separator: "&"))"
    case .moveWindow(let params):
      var parts: [String] = []
      if let position = params.position {
        parts.append("position=\(position.rawValue)")
      }
      parts.append("screen=\(params.screen)")
      return "flash://window_move?\(parts.joined(separator: "&"))"
    }
  }
}

extension MouseCommand {
  var querySuffix: String {
    switch self {
    case .move:
      return "?move=1"
    case .click(let action):
      switch action {
      case .leftClick:
        return ""
      case .rightClick:
        return "?right=1"
      case .doubleClick:
        return "?double=1"
      }
    }
  }
}

extension Config {
  static let helpTopic = HelpTopic(
    name: "config",
    title: "Configuration",
    summary: "flash.toml sections, defaults, and live reload.",
    body: """
      # Configuration

      Flash reads `$XDG_CONFIG_HOME/flash/flash.toml`, then
      `~/.config/flash/flash.toml` when XDG is unset. The active file is
      watched and reloaded live.

      User-facing sections are:

      - `[hints]`
      - `[open]`
      - `[plugins]`
      - `[mode]`
      - `[mode.all.mappings]`
      - `[mode.normal]`
      - `[mode.normal.mappings]`
      - `[mode.insert.mappings]`
      - `[debug]`

      Mapping values must be `flash://...` URLs or explicit argv arrays.
      Relative argv paths containing `/` resolve from the config file.

      `config.default.toml` is the canonical reference for all accepted keys.
      """)
}
