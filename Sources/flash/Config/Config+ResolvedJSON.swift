import FlashCore
import Foundation

/// The configuration as JSON: what a plugin receives, and what the page and
/// `config show` present.
extension Config {
  /// JSON object string of the `[plugins.<id>]` settings for `pluginID`,
  /// suitable for `FLASH_PLUGIN_CONFIG`. Returns `{}` when the plugin has
  /// no settings.
  func pluginConfigJSON(for pluginID: String) -> String {
    let table = plugins.settings[pluginID]?.mapValues(\.jsonValue) ?? [:]
    guard
      let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  /// A monitor's `usb` filter as the page and `config show` present it.
  static func usbFilterJSON(_ filter: USBDeviceFilter) -> [String: Any] {
    var object: [String: Any] = [:]
    if let vendorID = filter.vendorID { object["vendor_id"] = vendorID }
    if let productID = filter.productID { object["product_id"] = productID }
    if let name = filter.name { object["name"] = name }
    return object
  }

  var resolvedConfigJSON: String {
    let modeJSON: [String: Any] = [
      "all": mode.all.map(Self.mappingJSONValue),
      "apps": mode.appMappings.mapValues { app in
        [
          "all": app.all.map(Self.mappingJSONValue),
          "normal": app.normal.map(Self.mappingJSONValue),
          "insert": app.insert.map(Self.mappingJSONValue),
          "terminal": app.terminal.map(Self.mappingJSONValue),
          "command": app.command.map(Self.mappingJSONValue),
          "hyper": app.hyper.map(Self.mappingJSONValue),
          "hold": app.hold.map(Self.mappingJSONValue),
          "text": app.text.map(Self.mappingJSONValue),
          "visual": app.visual.map(Self.mappingJSONValue),
          "unmapped": app.unmapped.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = entry.value.sorted()
          },
          "text_enabled": app.engagesText.map { $0 as Any } ?? NSNull(),
        ]
      },
      "command": mode.command.map(Self.mappingJSONValue),
      "insert": mode.insert.map(Self.mappingJSONValue),
      "terminal": mode.effectiveTerminalMappings.map(Self.mappingJSONValue),
      "labels": [
        "command": mode.labels.command,
        "hyper": mode.labels.hyper,
        "insert": mode.labels.insert,
        "normal": mode.labels.normal,
        "terminal": mode.labels.terminal,
        "hold": mode.labels.hold,
        "visual": mode.labels.visual,
        "visual_line": mode.labels.visualLine,
      ],
      "hyper": mode.hyper.map(Self.mappingJSONValue),
      "hold": mode.hold.map(Self.mappingJSONValue),
      "text": mode.text.map(Self.mappingJSONValue),
      "visual": mode.visual.map(Self.mappingJSONValue),
      "layers": mode.layers.mapValues { layer in
        [
          "label": layer.label ?? NSNull(),
          "sticky": layer.sticky,
          "mappings": layer.mappings.map(Self.mappingJSONValue),
          "unmapped": layer.unmapped.sorted(),
        ] as [String: Any]
      },
      "hyper_key": mode.hyperKey,
      "hyper_key_atom": mode.resolvedHyperKey ?? NSNull(),
      "normal": mode.normal.map(Self.mappingJSONValue),
      "normal_leader": mode.normalLeader ?? NSNull(),
      "scroll_smooth_ms": mode.scrollSmoothMs,
      "text_enabled": mode.textEnabled,
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
      "keyboard": ["layout": keyboard.layout],
      "hints": [
        "adjust_digits": hints.adjustDigits.rawValue,
        "key_priority": hints.keyPriority,
        "keys": effectiveHintKeys(),
        "label_order": hints.labelOrder.rawValue,
        "magic_modifiers": effectiveMagicModifiers,
        "min_length": hints.minLength,
        "pointer_acceleration": hints.pointerAcceleration,
        "pointer_follows_focus": hints.pointerFollowsFocus,
        "pointer_max_step": hints.pointerMaxStep,
        "pointer_step": hints.pointerStep,
        "position_history_scope": hints.positionHistoryScope.rawValue,
        "position_history_size": hints.positionHistorySize,
        "mouse_grid_cursor_follow": hints.mouseGridCursorFollow,
        "mouse_grid_keys": resolvedMouseGridKeys.map { String($0) },
        "mouse_grid_opacity": hints.mouseGridOpacity,
        "mouse_grid_preview": hints.mouseGridPreview,
        "mouse_grid_steps": hints.mouseGridSteps,
        "restore_pointer": hints.restorePointer,
      ],
      "flashlight": [
        "aliases": flashlight.aliases,
        "bangs": flashlight.bangs.mapValues {
          ["url": $0.url, "description": $0.description] as [String: Any]
        },
        "ignored_apps": flashlight.ignoredApps,
        "precedence": flashlight.precedence,
        "precedence_alive_bonus": flashlight.precedenceAliveBonus,
        "suggestion_count": flashlight.suggestionCount,
      ],
      "mode": modeJSON,
      "overlay": [
        "click_feedback": overlay.clickFeedback,
        "dark": [
          "hint_bg_bottom": overlay.dark.hintBGBottom,
          "hint_bg_top": overlay.dark.hintBGTop,
          "hint_border": overlay.dark.hintBorder,
          "hint_fg": overlay.dark.hintFG,
          "important_hint_bg_bottom": overlay.dark.importantHintBGBottom,
          "important_hint_bg_top": overlay.dark.importantHintBGTop,
          "important_hint_border": overlay.dark.importantHintBorder,
          "important_hint_fg": overlay.dark.importantHintFG,
        ],
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
        "hint_placement": overlay.hintPlacement.rawValue,
      ],
      "plugins": [
        "disabled": plugins.disabled.sorted(),
        "third_party": plugins.thirdParty.map(\.raw),
        "watching_enabled": plugins.watchingEnabled,
        // Diagnostics/inspector JSON is intentionally value-free: per-plugin
        // settings can contain API tokens and are delivered only to that
        // plugin through FLASH_PLUGIN_CONFIG.
        "configured": plugins.settings.keys.sorted(),
      ],
      "clipboard": ["history_size": clipboard.historySize],
      "calendar": [
        "calendars": calendar.calendars, "all_day": calendar.allDay,
        "declined": calendar.declined, "lookahead_hours": calendar.lookaheadHours,
      ],
      "tiling": [
        "enabled": tiling.enabled, "persist": tiling.persist, "layout": tiling.layout.rawValue,
        "orientation": tiling.orientation?.rawValue ?? "auto",
        "accordion_padding": Int(tiling.accordionPadding), "workspaces": tiling.workspaces,
        "rules": tiling.rules.count,
      ] as [String: Any],
      // Kinds, lifecycles and sizes only: commands and environments can
      // carry credentials.
      "popup": [
        "bg": popupStyle.background, "border": popupStyle.borderColor,
        "border_size": popupStyle.borderWidth, "corner_radius": popupStyle.cornerRadius,
        "fg": popupStyle.foreground, "max_width": popupStyle.maxWidth,
        "min_width": popupStyle.minWidth,
        "offset": popupStyle.offset, "padding": popupStyle.padding,
        "popups": popups.mapValues { popup -> [String: Any] in
          switch popup {
          case .text: return ["kind": "text"]
          case .terminal(let terminal):
            return [
              "kind": "terminal", "persistent": terminal.lifecycle == .persistent,
              "pause_hidden": terminal.pauseHidden, "size": terminal.size.description,
            ]
          }
        },
      ] as [String: Any],
      "statusbar": [
        "enabled": statusBar.enabled,
        "template": statusBar.template.template,
        "sources": statusBar.sources.keys.sorted(),
      ],
      "widgets": widgets.mapValues { widget in
        [
          "enabled": widget.enabled, "template": widget.template.template,
          "anchor": widget.anchor.rawValue, "columns": widget.columns,
          "interval": widget.intervalSeconds,
        ] as [String: Any]
      },
      "monitors": monitors.mapValues { monitor in
        [
          "enabled": monitor.enabled, "value": monitor.value, "message": monitor.message,
          "warning": monitor.warning as Any? ?? NSNull(),
          "error": monitor.error as Any? ?? NSNull(),
          "direction": monitor.direction.rawValue, "interval": monitor.intervalSeconds,
          "event": monitor.event, "app": monitor.app, "alert": monitor.alert,
          "usb": monitor.usb.map(Self.usbFilterJSON) ?? NSNull(),
          "run": monitor.run.isEmpty ? NSNull() : monitor.run.map(\.argv) as Any,
          "timeout": monitor.timeout, "cooldown": monitor.cooldown,
        ] as [String: Any]
      },
      // Header names only: their values are credentials.
      "telemetry": [
        "receiver": [
          "enabled": telemetry.receiver.enabled, "port": telemetry.receiver.port,
          "max_series": telemetry.receiver.maxSeries, "max_points": telemetry.receiver.maxPoints,
          "max_logs": telemetry.receiver.maxLogs, "max_spans": telemetry.receiver.maxSpans,
          // Whether one is set, never its value.
          "token": !telemetry.receiver.token.isEmpty,
        ],
        "exporter": [
          "endpoint": telemetry.exporter.endpoint,
          "protocol": telemetry.exporter.encoding.rawValue,
          "compression": telemetry.exporter.gzip ? "gzip" : "none",
          "headers": telemetry.exporter.headers.keys.sorted(),
          "service_name": telemetry.exporter.serviceName,
          "signals": telemetry.exporter.signals.sorted().map(\.rawValue),
          "interval": telemetry.exporter.intervalSeconds,
        ] as [String: Any],
      ],
      "startup": [
        "run": startup.run.map(\.argv), "timeout": startup.timeoutSeconds,
      ] as [String: Any],
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "command": mapping.action.configValue,
      "key": mapping.key,
      "repeat": mapping.repeatsOnFinalKey,
    ]
  }

  /// Sparse tree parallel to `resolvedConfigJSON`. A node's `"$"` is
  /// `{ "layer", "where" }` for the writer that overrode the default. Mapping
  /// arrays are keyed by mapping key; other arrays of names are keyed by the
  /// name. Paths the JSON renames (`mode.normal.leader`, named popups) are
  /// translated onto the JSON shape.
  func resolvedConfigSources() -> [String: Any] {
    var tree: [String: Any] = [:]
    for (path, source) in valueSources {
      Self.insert(source, at: Self.jsonPath(for: path), into: &tree)
    }
    insertMappingSources(into: &tree)
    if var mode = tree["mode"] as? [String: Any],
      let hyper = mode["hyper_key"] as? [String: Any],
      let mark = hyper["$"]
    {
      var atom = mode["hyper_key_atom"] as? [String: Any] ?? [:]
      atom["$"] = mark
      mode["hyper_key_atom"] = atom
      tree["mode"] = mode
    }
    return tree
  }

  private static let popupStyleJSONKeys: Set<String> = [
    "fg", "bg", "border", "border_size", "corner_radius", "padding", "min_width", "max_width",
    "offset",
  ]

  private static func jsonPath(for tomlPath: String) -> [String] {
    switch tomlPath {
    case "mode.normal.leader": return ["mode", "normal_leader"]
    case "mode.normal.hyper": return ["mode", "hyper_key"]
    default: break
    }
    var parts = tomlPath.split(separator: ".").map(String.init)
    if parts.count >= 2, parts[0] == "popup", !popupStyleJSONKeys.contains(parts[1]) {
      parts.insert("popups", at: 1)
    }
    return parts
  }

  private static func insert(
    _ source: ConfigValueSource, at path: [String], into node: inout [String: Any]
  ) {
    guard let head = path.first else { return }
    var child = node[head] as? [String: Any] ?? [:]
    if path.count == 1 {
      child["$"] = ["layer": source.layer, "where": source.detail]
    } else {
      insert(source, at: Array(path.dropFirst()), into: &child)
    }
    node[head] = child
  }

  private static func source(forMappingOrigin origin: String) -> ConfigValueSource? {
    if origin.isEmpty || origin == ModeMapping.defaultOrigin { return nil }
    let parts = origin.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      return ConfigValueSource(layer: origin, detail: origin)
    }
    return ConfigValueSource(layer: parts[0], detail: parts[1])
  }

  private func insertMappingSources(into tree: inout [String: Any]) {
    func add(_ mappings: [ModeMapping], at path: [String]) {
      for mapping in mappings {
        guard let source = Self.source(forMappingOrigin: mapping.origin) else { continue }
        Self.insert(source, at: path + [mapping.key], into: &tree)
      }
    }
    add(mode.all, at: ["mode", "all"])
    add(mode.normal, at: ["mode", "normal"])
    add(mode.insert, at: ["mode", "insert"])
    add(mode.effectiveTerminalMappings, at: ["mode", "terminal"])
    add(mode.command, at: ["mode", "command"])
    add(mode.hyper, at: ["mode", "hyper"])
    add(mode.hold, at: ["mode", "hold"])
    add(mode.text, at: ["mode", "text"])
    add(mode.visual, at: ["mode", "visual"])
    for (name, layer) in mode.layers {
      add(layer.mappings, at: ["mode", "layers", name, "mappings"])
    }
    for (bundle, app) in mode.appMappings {
      for scope in ModeScope.allCases {
        add(app.mappings(for: scope), at: ["mode", "apps", bundle, scope.rawValue])
      }
    }
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
