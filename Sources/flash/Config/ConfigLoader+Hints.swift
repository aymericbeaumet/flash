import FlashCore
import Foundation
import TOMLKit

/// `[hints]` and `[overlay]`.
extension ConfigLoader {
  static func applyHints(
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
    applyString(
      table["key_priority"], path: ["hints", "key_priority"],
      message: "hints.key_priority must be a string of hint keys, best first (no repeats)",
      locations: locations, into: &config,
      validate: { value in
        let keys = Alphabet.priorityKeys(value)
        return keys.count == value.filter { !$0.isWhitespace }.count
          && keys.allSatisfy { $0.isASCII && ($0.isLetter || $0 == ";" || $0 == "'") }
      },
      assign: { value, config in
        config.hints.keyPriority = value
      })
    applyString(
      table["label_order"], path: ["hints", "label_order"],
      message: "hints.label_order must be \"reading\", \"center\" or \"zones\"",
      locations: locations, into: &config,
      validate: { Config.LabelOrder(rawValue: $0) != nil },
      assign: { value, config in
        config.hints.labelOrder = Config.LabelOrder(rawValue: value) ?? .reading
      })
    applyString(
      table["adjust_digits"], path: ["hints", "adjust_digits"],
      message: "hints.adjust_digits must be \"width\" or \"grid\"",
      locations: locations, into: &config,
      validate: { Config.AdjustDigits(rawValue: $0) != nil },
      assign: { value, config in
        config.hints.adjustDigits = Config.AdjustDigits(rawValue: value) ?? .width
      })
    applyInt(
      table["position_history_size"], path: ["hints", "position_history_size"],
      message: "hints.position_history_size must be an integer between 1 and 100",
      locations: locations, into: &config, validate: { (1...100).contains($0) },
      assign: { value, config in
        config.hints.positionHistorySize = value
      })
    applyString(
      table["position_history_scope"], path: ["hints", "position_history_scope"],
      message: "hints.position_history_scope must be \"global\" or \"app\"",
      locations: locations, into: &config,
      validate: { Config.PositionScope(rawValue: $0) != nil },
      assign: { value, config in
        config.hints.positionHistoryScope = Config.PositionScope(rawValue: value) ?? .global
      })
    applyBool(
      table["pointer_follows_focus"], path: ["hints", "pointer_follows_focus"],
      message: "hints.pointer_follows_focus must be true or false",
      locations: locations, into: &config,
      assign: { value, config in
        config.hints.pointerFollowsFocus = value
      })
    applyInt(
      table["pointer_step"], path: ["hints", "pointer_step"],
      message: "hints.pointer_step must be an integer between 1 and 500",
      locations: locations, into: &config, validate: { (1...500).contains($0) },
      assign: { value, config in
        config.hints.pointerStep = value
      })
    applyInt(
      table["pointer_acceleration"], path: ["hints", "pointer_acceleration"],
      message: "hints.pointer_acceleration must be an integer between 0 and 100",
      locations: locations, into: &config, validate: { (0...100).contains($0) },
      assign: { value, config in
        config.hints.pointerAcceleration = value
      })
    applyInt(
      table["pointer_max_step"], path: ["hints", "pointer_max_step"],
      message: "hints.pointer_max_step must be an integer between 1 and 1000",
      locations: locations, into: &config, validate: { (1...1000).contains($0) },
      assign: { value, config in
        config.hints.pointerMaxStep = value
      })
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
    applyStringArray(
      table["mouse_grid_keys"], path: ["hints", "mouse_grid_keys"],
      message: "hints.mouse_grid_keys must be an array of strings, one per keyboard row",
      locations: locations, into: &config
    ) { value, config in
      // A malformed matrix keeps the previous layer's value.
      if let problem = MouseGridKeys.problem(in: value) {
        config.addDiagnostic(
          problem.message, location: locations.location(for: ["hints", "mouse_grid_keys"]))
        return
      }
      config.hints.mouseGridKeys = value
    }
    applyBool(
      table["mouse_grid_cursor_follow"], path: ["hints", "mouse_grid_cursor_follow"],
      message: "hints.mouse_grid_cursor_follow must be true or false",
      locations: locations, into: &config,
      assign: { value, config in
        config.hints.mouseGridCursorFollow = value
      })
    applyBool(
      table["mouse_grid_preview"], path: ["hints", "mouse_grid_preview"],
      message: "hints.mouse_grid_preview must be true or false",
      locations: locations, into: &config,
      assign: { value, config in
        config.hints.mouseGridPreview = value
      })
    applyBool(
      table["restore_pointer"], path: ["hints", "restore_pointer"],
      message: "hints.restore_pointer must be true or false",
      locations: locations, into: &config,
      assign: { value, config in
        config.hints.restorePointer = value
      })
  }

  static func applyOverlay(
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
    applyHexColor(
      table, ["overlay", "hint_fg"], locations: locations, into: &config, \.overlay.hintFG)
    applyHexColor(
      table, ["overlay", "hint_bg_top"], locations: locations, into: &config, \.overlay.hintBGTop)
    applyHexColor(
      table, ["overlay", "hint_bg_bottom"], locations: locations, into: &config,
      \.overlay.hintBGBottom)
    applyHexColor(
      table, ["overlay", "hint_border"], locations: locations, into: &config, \.overlay.hintBorder)
    applyHexColor(
      table, ["overlay", "important_hint_fg"], locations: locations, into: &config,
      \.overlay.importantHintFG)
    applyHexColor(
      table, ["overlay", "important_hint_bg_top"], locations: locations, into: &config,
      \.overlay.importantHintBGTop)
    applyHexColor(
      table, ["overlay", "important_hint_bg_bottom"], locations: locations, into: &config,
      \.overlay.importantHintBGBottom)
    applyHexColor(
      table, ["overlay", "important_hint_border"], locations: locations, into: &config,
      \.overlay.importantHintBorder)
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
    applyString(
      table["hint_placement"], path: ["overlay", "hint_placement"],
      message: "overlay.hint_placement must be one of "
        + HintPlacement.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "),
      locations: locations, into: &config, validate: { HintPlacement(rawValue: $0) != nil },
      assign: { value, config in
        if let placement = HintPlacement(rawValue: value) {
          config.overlay.hintPlacement = placement
        }
      })
    applyBool(
      table["click_feedback"], path: ["overlay", "click_feedback"],
      message: "overlay.click_feedback must be true or false", locations: locations,
      into: &config
    ) { value, config in
      config.overlay.clickFeedback = value
    }
    applyDarkOverlay(
      sectionTable(table["dark"], name: "overlay.dark", locations: locations, into: &config),
      locations: locations, into: &config)
  }

  /// `[overlay.dark]`: the colour keys of `[overlay]`, drawn under a dark
  /// appearance. Empty keeps the `[overlay]` colour.
  private static func applyDarkOverlay(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    let keys: [(String, WritableKeyPath<Config.Overlay.DarkHintColors, String>)] = [
      ("hint_fg", \.hintFG), ("hint_bg_top", \.hintBGTop), ("hint_bg_bottom", \.hintBGBottom),
      ("hint_border", \.hintBorder), ("important_hint_fg", \.importantHintFG),
      ("important_hint_bg_top", \.importantHintBGTop),
      ("important_hint_bg_bottom", \.importantHintBGBottom),
      ("important_hint_border", \.importantHintBorder),
    ]
    for (key, field) in keys {
      applyString(
        table[key], path: ["overlay", "dark", key],
        message:
          "overlay.dark.\(key) must be a hex color like #RRGGBB or #RRGGBBAA (empty keeps overlay.\(key))",
        locations: locations, into: &config, validate: { $0.isEmpty || isValidHexColor($0) },
        assign: { value, config in
          config.overlay.dark[keyPath: field] = value
        })
    }
    warnUnknownKeys(
      in: table, known: Set(keys.map(\.0)), path: ["overlay", "dark"], locations: locations,
      into: &config)
  }
}
