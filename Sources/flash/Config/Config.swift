import Foundation
import FlashCore

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
    var showBounds: Bool = false
    /// Fill for the debug outline rectangle. Default transparent.
    var boundsBG: String = "#00000000"
    /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
    /// it's the foreground colour of the bounds shape.
    var boundsFG: String = "#FF3B9A"
    /// Emit a profiling trace for every activation and background
    /// precompute. Slow activations are still logged when this is false
    /// if `slowMs` is positive.
    var profile: Bool = false
    /// Log activation profiles whose end-to-end latency is at least this
    /// many milliseconds. Set to 0 to disable slow-activation logs.
    var slowMs: Int = 100
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `trace` while investigating a
    /// stuck-mode/input issue, `debug` for broader diagnostics, or
    /// `warn` / `error` / `fatal` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
  }
  struct Open {
    var ignoredApps: [String] = []
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
    var labels = Labels()

    static let defaultNormalMappings: [ModeMapping] = [
      ModeMapping(key: "h", action: .flashCommand(.scroll(.left))),
      ModeMapping(key: "j", action: .flashCommand(.scroll(.down))),
      ModeMapping(key: "k", action: .flashCommand(.scroll(.up))),
      ModeMapping(key: "l", action: .flashCommand(.scroll(.right))),
      ModeMapping(key: "ctrl-e", action: .flashCommand(.scroll(.down))),
      ModeMapping(key: "ctrl-y", action: .flashCommand(.scroll(.up))),
      ModeMapping(key: "ctrl-d", action: .flashCommand(.scroll(.halfPageDown))),
      ModeMapping(key: "ctrl-u", action: .flashCommand(.scroll(.halfPageUp))),
      ModeMapping(key: "gg", action: .flashCommand(.scroll(.top))),
      ModeMapping(key: "G", action: .flashCommand(.scroll(.bottom))),
      ModeMapping(key: "gt", action: .flashCommand(.tabNext)),
      ModeMapping(key: "gT", action: .flashCommand(.tabPrev)),
      ModeMapping(key: "gN", action: .flashCommand(.tabSelect(index: nil))),
      ModeMapping(key: "ctrl-o", action: .flashCommand(.appBack)),
      ModeMapping(key: "ctrl-i", action: .flashCommand(.appForward)),
      ModeMapping(key: "gf", action: .flashCommand(.nextFrame)),
      ModeMapping(key: "gF", action: .flashCommand(.mainFrame)),
      ModeMapping(key: "i", action: .flashCommand(.insertMode)),
      ModeMapping(key: "f", action: .flashCommand(.mouseClick(action: .leftClick))),
      ModeMapping(key: "rf", action: .flashCommand(.mouseClick(action: .rightClick))),
      ModeMapping(key: "df", action: .flashCommand(.mouseClick(action: .doubleClick))),
      ModeMapping(key: "mf", action: .flashCommand(.mouseMove)),
      ModeMapping(key: "u", action: .flashCommand(.undo)),
      ModeMapping(key: "ctrl-r", action: .flashCommand(.redo)),
      ModeMapping(key: "x", action: .flashCommand(.close)),
      ModeMapping(key: "t", action: .flashCommand(.tabNewInsert)),
      ModeMapping(key: "/", action: .flashCommand(.find)),
      ModeMapping(key: "o", action: .flashCommand(.candidateFinder(all: true))),
      ModeMapping(key: "O", action: .flashCommand(.candidateFinder(all: true))),
      ModeMapping(key: "r", action: .flashCommand(.reload)),
      ModeMapping(key: "?", action: .flashCommand(.showUsage)),
      ModeMapping(key: ":", action: .flashCommand(.commandMode)),
    ]

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return all + normal
      case .insert:
        return all + insert
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
  var mode = Mode()
  var debug = Debug()
  var warnings: [String] = []
  var diagnostics: [ConfigDiagnostic] = []
  var valueLocations: [String: ConfigLocation] = [:]
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env/CLI
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)

  static let `default` = Config()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func recordLocation(path: String, location: ConfigLocation?) {
    valueLocations[path] = location
  }

  mutating func clearLocation(path: String) {
    valueLocations.removeValue(forKey: path)
  }

  mutating func addDiagnostic(_ message: String, location: ConfigLocation? = nil) {
    diagnostics.append(ConfigDiagnostic(message: message, location: location))
    warnings.append(message)
  }

  mutating func removeDiagnostics(where predicate: (String) -> Bool) {
    diagnostics.removeAll { predicate($0.message) }
    warnings.removeAll(where: predicate)
  }

  mutating func prepareDerivedValues() {
    resolvedAlphabet = Alphabet.resolve(hints.keys)
    removeAmbiguousShiftMagicModifier()
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
    compactJSON([
      "debug": [
        "bounds_bg": debug.boundsBG,
        "bounds_fg": debug.boundsFG,
        "log_level": debug.logLevel.name,
        "profile": debug.profile,
        "show_bounds": debug.showBounds,
        "slow_ms": debug.slowMs,
      ],
      "hints": [
        "keys": hints.keys,
        "magic_modifiers": hints.magicModifiers,
        "min_length": hints.minLength,
      ],
      "mode": [
        "all": mode.all.map(Self.mappingJSONValue),
        "insert": mode.insert.map(Self.mappingJSONValue),
        "labels": [
          "command": mode.labels.command,
          "insert": mode.labels.insert,
          "normal": mode.labels.normal,
        ],
        "normal": mode.normal.map(Self.mappingJSONValue),
      ],
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
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "action": mapping.action.diagnosticDescription,
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
    case .mouseClick(let action):
      switch action {
      case .leftClick:
        return "flash://mouse_click"
      case .rightClick:
        return "flash://mouse_click?right=1"
      case .doubleClick:
        return "flash://mouse_click?double=1"
      }
    case .mouseMove:
      return "flash://mouse_move"
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
    case .reload:
      return "flash://app_reload"
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
    case .copyURL:
      return "flash://url_copy"
    case .nextFrame:
      return "flash://frame_next"
    case .mainFrame:
      return "flash://frame_main"
    case .tabNext:
      return "flash://tab_next"
    case .tabPrev:
      return "flash://tab_previous"
    case .tabSelect(let index):
      if let index {
        return "flash://tab_select?index=\(index)"
      }
      return "flash://tab_select"
    case .appBack:
      return "flash://app_back"
    case .appForward:
      return "flash://app_forward"
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
    case .showUsage:
      return "flash://help_show"
    case .dismissHints:
      return "flash://hints_dismiss"
    case .quit:
      return "flash://flash_quit"
    case .openApp(let name):
      return "flash://app_open?name=\(name)"
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
