import Foundation

struct Config {
  struct Hints {
    var keys: String = Alphabet.defaultKeys
    var minLength: Int = 1
    var magicModifiers: [String] = ["cmd", "ctrl", "alt", "shift"]
  }
  struct Overlay {
    var fontSize: Double = 12
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Vimium's default light
    /// yellow. Set this equal to `hintBGBottom` for a flat fill.
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
    /// When true, the AX walker writes one line per visited element
    /// (role, subrole, frame, parent role, actions, label) to
    /// `~/Library/Logs/Flash/ax-dump.log` on every activation. Used to
    /// diagnose missing or spurious hints in apps that fall through to
    /// the AX provider (Firefox web pages, Electron, etc.). Off by
    /// default — the dump is verbose and rotates per activation.
    var dumpAx: Bool = false
    /// When true, every diagnostic line that goes to stderr is also
    /// appended to `~/Library/Logs/Flash/flash.log`. Useful when
    /// running Flash via launchd (no terminal) but you still want to
    /// see profile traces and one-off warnings.
    var dumpLogs: Bool = false
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `debug` while investigating an
    /// issue, or `warn` / `error` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
  }

  var hints = Hints()
  var overlay = Overlay()
  var debug = Debug()
  /// `[shortcuts]` section. Each entry maps a hotkey string
  /// (e.g. `"cmd+ctrl+a"`) to one of:
  ///
  ///   - a single `flash://...` URL string (fast path — dispatched
  ///     internally through the same URLCommand parser as AppleEvents), or
  ///   - an array of strings, which is exec'd as `argv` (the
  ///     first element is the executable, the rest are args). Standalone
  ///     path arguments from a config file expand `~`, `$VAR`, and
  ///     `${VAR}`; relative paths resolve against that file's real
  ///     directory before exec.
  ///
  /// `ShortcutsCoordinator` resolves each value into a typed
  /// `ShortcutAction` AOT at config-load. The hot path on a
  /// Carbon hotkey fire dispatches the already-resolved action.
  var shortcuts: [Shortcut] = []
  var warnings: [String] = []
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env/CLI
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)

  static let `default` = Config()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func prepareDerivedValues() {
    resolvedAlphabet = Alphabet.resolve(hints.keys)
    removeAmbiguousShiftMagicModifier()
  }

  private mutating func removeAmbiguousShiftMagicModifier() {
    guard resolvedAlphabet.chars.contains(where: { !$0.isLetter }) else {
      warnings.removeAll { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
      return
    }
    let original = hints.magicModifiers
    hints.magicModifiers.removeAll { $0.lowercased() == "shift" }
    guard original.count != hints.magicModifiers.count else { return }
    warnings.removeAll { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
    warnings.append(
      "hints.magic_modifiers includes \"shift\", but resolved hints.keys "
        + "contains non-letter characters (\(String(resolvedAlphabet.chars))); "
        + "removed \"shift\" because shifted-character input is ambiguous"
    )
  }

  var resolvedConfigJSON: String {
    compactJSON([
      "debug": [
        "bounds_bg": debug.boundsBG,
        "bounds_fg": debug.boundsFG,
        "dump_ax": debug.dumpAx,
        "dump_logs": debug.dumpLogs,
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
      "overlay": [
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
      ],
      "shortcuts": shortcuts.map { shortcut in
        [
          "action": shortcut.action.diagnosticJSONValue,
          "hotkey": shortcut.hotkey,
        ] as [String: Any]
      },
      "warnings": warnings,
    ])
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

extension FlashLog.Level {
  var name: String {
    switch self {
    case .debug: return "debug"
    case .info: return "info"
    case .warn: return "warn"
    case .error: return "error"
    }
  }
}

extension ShortcutAction {
  var diagnosticJSONValue: Any {
    switch self {
    case .flashCommand(let command):
      return command.diagnosticDescription
    case .shell(let argv):
      return argv
    }
  }
}

extension URLCommand {
  var diagnosticDescription: String {
    switch self {
    case .showHints(let rightClick):
      return rightClick ? "flash://show_hints?right=1" : "flash://show_hints"
    case .showAlert(let message):
      return "flash://show_alert?message=\(message)"
    case .dismissAlert:
      return "flash://dismiss_alert"
    case .showUsage:
      return "flash://help"
    case .dismissHints:
      return "flash://dismiss_hints"
    case .quit:
      return "flash://quit"
    case .openApp(let name):
      return "flash://open_app?name=\(name)"
    case .moveWindow(let params):
      var parts: [String] = []
      if let position = params.position {
        parts.append("position=\(position.rawValue)")
      }
      parts.append("screen=\(params.screen)")
      return "flash://move_window?\(parts.joined(separator: "&"))"
    }
  }
}
