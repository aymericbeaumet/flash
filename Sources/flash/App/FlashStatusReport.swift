import Foundation

/// `flash status`: the resident's state as one versioned JSON object, built
/// for the CLI alone. It carries facts about Flash itself — never clipboard
/// contents, typed keys, window titles or hint targets (only apps' bundle
/// identifiers and activation counts and timings) — and its key set is
/// pinned by a test, so a scripted consumer can rely on `schema`.
struct FlashStatusReport: Equatable {
  static let schema = 2

  /// Every top-level key, in the order the text rendering lists them.
  static let keys = [
    "schema", "version", "build", "mode", "hint_session", "focused_app", "accessibility",
    "capture", "secure_input", "input_source", "keyboard_layout", "reference_layout",
    "config_path", "config_diagnostics", "plugins", "statusbar", "autostart", "hints",
  ]

  /// Apps the text rendering lists under `hints`, busiest first.
  static let renderedHintApps = 3

  struct PluginCounts: Equatable {
    var loaded = 0
    var ready = 0
    var error = 0

    /// The counts `#{flash.plugin.*_count}` shows.
    init(_ infos: [PluginStatusBarInfo]) {
      loaded = infos.filter { $0.state != "failed" }.count
      ready = infos.filter { ["running", "manifest_only"].contains($0.state) }.count
      error = infos.filter(\.hasError).count
    }

    init(loaded: Int, ready: Int, error: Int) {
      self.loaded = loaded
      self.ready = ready
      self.error = error
    }
  }

  var version: String
  var build: String
  /// `disabled`, `insert`, `normal`, `command` or `terminal`.
  var mode: String
  /// `idle`, `discovering`, `labels`, `grid`, `search`, `adjusting`, `pointer`
  /// or `bigram`.
  var hintSession: String
  var focusedApp: String?
  var accessibility: Bool
  /// `tap` or `key_window`: how the keys of the current (or next) hint
  /// session arrive.
  var capture: KeyboardCaptureTap.SessionCapture
  var secureInput: Bool
  var inputSource: String?
  /// `[app] keyboard_layout` as configured.
  var keyboardLayout: String
  /// The layout keys are read against, or nil while they read as typed.
  var referenceLayout: String?
  var configPath: String
  var configDiagnostics: Int
  var plugins: PluginCounts
  var statusBar: Bool
  var autostart: Bool
  /// Recent target activations per app (`HintActivationStats`).
  var hints: [HintActivationStats.Summary]

  static func modeName(_ mode: Mode) -> String {
    switch mode {
    case .disabled: return "disabled"
    case .insert: return "insert"
    case .normal: return "normal"
    case .command: return "command"
    case .terminal: return "terminal"
    case .hyper: return "hyper"
    }
  }

  /// What the hint session is doing: nothing, walking for targets, or which
  /// interpreter owns its keys.
  static func hintSessionPhase(route: HintKeyRoute, active: Bool, discovering: Bool) -> String {
    guard active else { return discovering ? "discovering" : "idle" }
    switch route {
    case .labels: return "labels"
    case .grid: return "grid"
    case .search: return "search"
    case .adjustment: return "adjusting"
    case .pointer: return "pointer"
    case .bigram: return "bigram"
    }
  }

  /// The running session's capture, or the one a session starting now
  /// would get.
  static func capture(
    tapInstalled: Bool, secureInputEnabled: Bool, session: KeyboardCaptureTap.SessionCapture?
  ) -> KeyboardCaptureTap.SessionCapture {
    session
      ?? KeyboardCaptureTap.sessionCapture(
        tapInstalled: tapInstalled, secureInputEnabled: secureInputEnabled)
  }

  var json: [String: Any] {
    [
      "schema": Self.schema,
      "version": version,
      "build": build,
      "mode": mode,
      "hint_session": hintSession,
      "focused_app": focusedApp ?? NSNull(),
      "accessibility": accessibility,
      "capture": capture.rawValue,
      "secure_input": secureInput,
      "input_source": inputSource ?? NSNull(),
      "keyboard_layout": keyboardLayout,
      "reference_layout": referenceLayout ?? NSNull(),
      "config_path": configPath,
      "config_diagnostics": configDiagnostics,
      "plugins": ["loaded": plugins.loaded, "ready": plugins.ready, "error": plugins.error],
      "statusbar": statusBar,
      "autostart": autostart,
      "hints": Dictionary(
        uniqueKeysWithValues: hints.map { summary in
          (
            summary.bundleIdentifier,
            [
              "count": summary.count,
              "empty": summary.empty,
              "p50_ms": summary.p50Ms.map(Self.tenths) ?? NSNull(),
              "p95_ms": summary.p95Ms.map(Self.tenths) ?? NSNull(),
            ] as [String: Any]
          )
        }),
    ]
  }

  private static func tenths(_ ms: Double) -> Double {
    (ms * 10).rounded() / 10
  }

  /// UTF-8 JSON for the AppleEvent reply.
  var data: Data {
    (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
  }

  /// The CLI's readable rendering of a status reply.
  static func render(_ object: [String: Any]) -> String {
    func text(_ key: String) -> String {
      switch object[key] {
      case let value as String: return value
      case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
        return value.boolValue ? "yes" : "no"
      case let value as NSNumber: return value.stringValue
      default: return "-"
      }
    }
    let plugins = object["plugins"] as? [String: Any] ?? [:]
    let reference = object["reference_layout"] as? String
    let rows: [(String, String)] =
      [
        ("mode", text("mode")),
        ("hint session", text("hint_session")),
        ("focused app", text("focused_app")),
        ("accessibility", text("accessibility") == "yes" ? "granted" : "not granted"),
        ("key capture", text("capture")),
        ("secure input", text("secure_input") == "yes" ? "on" : "off"),
        ("input source", text("input_source")),
        (
          "keyboard layout",
          "\(text("keyboard_layout")) (\(reference.map { "keys read on \($0)" } ?? "keys read as typed"))"
        ),
        ("config", "\(text("config_path")) (\(text("config_diagnostics")) diagnostics)"),
        (
          "plugins",
          "\(plugins["loaded"] ?? 0) loaded, \(plugins["ready"] ?? 0) ready, "
            + "\(plugins["error"] ?? 0) with errors"
        ),
        ("status bar", text("statusbar") == "yes" ? "on" : "off"),
        ("autostart", text("autostart") == "yes" ? "on" : "off"),
      ] + hintRows(object["hints"] as? [String: Any] ?? [:])
    let width = rows.map(\.0.count).max() ?? 0
    return
      (["Flash \(text("version")) (\(text("build")))"]
      + rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 })
      .joined(separator: "\n")
  }

  /// The busiest apps' recent activations, one per line under `hints`.
  private static func hintRows(_ hints: [String: Any]) -> [(String, String)] {
    let apps = hints.compactMap { bundle, value -> (String, [String: Any])? in
      guard let app = value as? [String: Any] else { return nil }
      return (bundle, app)
    }
    .sorted {
      let lhs = $0.1["count"] as? Int ?? 0
      let rhs = $1.1["count"] as? Int ?? 0
      return lhs != rhs ? lhs > rhs : $0.0 < $1.0
    }
    .prefix(renderedHintApps)
    guard !apps.isEmpty else { return [("hints", "none yet")] }
    return apps.enumerated().map { index, entry in
      let (bundle, app) = entry
      var text =
        "\(bundle): \(app["count"] as? Int ?? 0) activations, "
        + "\(app["empty"] as? Int ?? 0) empty"
      if let p50 = app["p50_ms"] as? Double, let p95 = app["p95_ms"] as? Double {
        text += String(format: ", p50 %.1f ms, p95 %.1f ms", p50, p95)
      }
      return (index == 0 ? "hints" : "", text)
    }
  }
}
