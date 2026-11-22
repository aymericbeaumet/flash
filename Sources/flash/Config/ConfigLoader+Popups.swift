import FlashCore
import Foundation
import TOMLKit

/// `[popup]`, `[popups.<name>]` and `[widgets.<name>]`.
extension ConfigLoader {
  /// The `[popup]` style keys; every other `[popup]` key is a named popup.
  static let popupStyleKeys: Set<String> = [
    "fg", "bg", "border", "border_size", "corner_radius", "padding", "min_width", "max_width",
    "offset",
  ]
  static let textPopupKeys: Set<String> = ["text"]
  static let terminalPopupKeys: Set<String> = [
    "command", "cwd", "env", "size", "persistent", "pause_hidden",
  ]

  /// `[popup]`: TOML types tell the keys apart. A table is a named popup
  /// (`[popup.<name>]`); a scalar is a style key shared by every popup. A
  /// later layer's `[popup.<name>]` replaces that popup's whole definition;
  /// an invalid one keeps the earlier definition and marks the name invalid.
  static func applyPopups(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    for (key, value) in table {
      if let definition = value.table {
        applyPopup(
          named: key, definition, locations: locations, sourceURL: sourceURL, into: &config)
      } else if value.array != nil {
        config.addDiagnostic(
          "popup.\(key) must be a style value or a [popup.\(key)] table",
          location: locations.location(for: ["popup", key]))
      } else if !popupStyleKeys.contains(key) {
        let suggestion =
          closestKnownKey(to: key, in: popupStyleKeys).map { " — did you mean '\($0)'?" }
          ?? "; a named popup is a table: [popup.\(key)] with text = \"…\" or command = [...]"
        config.addDiagnostic(
          "unknown config key 'popup.\(key)'\(suggestion)",
          location: locations.location(for: ["popup", key]))
      }
    }
    func path(_ key: String) -> [String] { ["popup", key] }
    for (key, keyPath) in [
      ("fg", \Config.PopupStyle.foreground), ("bg", \Config.PopupStyle.background),
      ("border", \Config.PopupStyle.borderColor),
    ] {
      applyString(
        table[key], path: path(key),
        message: "popup.\(key) must be a hex color like #RRGGBB or #RRGGBBAA",
        locations: locations, into: &config,
        validate: { $0.hasPrefix("#") && isValidHexColor($0) },
        assign: { value, config in config.popupStyle[keyPath: keyPath] = value })
    }
    for (key, keyPath, range) in [
      ("border_size", \Config.PopupStyle.borderWidth, 0.0...12.0),
      ("corner_radius", \Config.PopupStyle.cornerRadius, 0.0...64.0),
      ("padding", \Config.PopupStyle.padding, 0.0...64.0),
      ("min_width", \Config.PopupStyle.minWidth, 80.0...2_000.0),
      ("max_width", \Config.PopupStyle.maxWidth, 80.0...2_000.0),
      ("offset", \Config.PopupStyle.offset, 0.0...64.0),
    ] {
      applyDouble(
        table[key], path: path(key),
        message: "popup.\(key) must be a number between \(Int(range.lowerBound)) and "
          + "\(Int(range.upperBound)) (points)",
        locations: locations, into: &config, validate: { range.contains($0) },
        assign: { value, config in config.popupStyle[keyPath: keyPath] = value })
    }
  }

  private static func applyPopup(
    named name: String, _ definition: TOMLTable, locations: ConfigSourceLocationIndex,
    sourceURL: URL?, into config: inout Config
  ) {
    let dotted = "popup.\(name)"
    let location = locations.location(for: ["popup", name])
    guard !name.isEmpty,
      name.unicodeScalars.allSatisfy({
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
      })
    else {
      config.addDiagnostic(
        "popup name '\(name)' must use only letters, digits, '_' and '-'", location: location)
      return
    }
    func invalid(_ message: String, at key: String? = nil) {
      config.addDiagnostic(
        "\(dotted)\(message)",
        location: key.flatMap { locations.location(for: ["popup", name, $0]) } ?? location)
      config.invalidPopupNames.insert(name)
    }
    let isText = definition["text"] != nil
    guard isText != (definition["command"] != nil) else {
      invalid(
        " must set exactly one of text (a status format) or command (an argv array)")
      return
    }
    let allowed = isText ? textPopupKeys : terminalPopupKeys
    if let key = definition.keys.sorted().first(where: { !allowed.contains($0) }) {
      let suggestion =
        isText
        ? terminalPopupKeys.contains(key)
          ? " (\(key) belongs to command popups; a text popup takes only text)" : ""
        : closestKnownKey(to: key, in: allowed).map {
          " — did you mean '\($0)'?"
        } ?? ""
      invalid(": unknown key '\(key)'\(suggestion)", at: key)
      return
    }
    if isText {
      guard let text = definition["text"]?.string else {
        invalid(".text must be a status format string", at: "text")
        return
      }
      config.popups[name] = .text(FlashStatusBarTemplate(template: text, variables: []))
      config.popupSourceURLs[name] = sourceURL
      config.recordLocation(
        path: dotted, location: locations.location(for: ["popup", name, "text"]))
      config.invalidPopupNames.remove(name)
      return
    }
    var size = Config.PopupSize.default
    if let value = definition["size"] {
      guard let raw = value.string, let parsed = Config.PopupSize(raw) else {
        invalid(
          ".size must be \"COLUMNSxROWS\", each side a cell count from 1 to 1000 or a "
            + "percentage of the screen from 1% to 100% (a fraction is allowed), "
            + "like \"100x28\", \"90%x85%\" or \"78.615%x78.615%\"",
          at: "size")
        return
      }
      size = parsed
    }
    guard definition["persistent"] == nil || definition["persistent"]?.bool != nil else {
      invalid(".persistent must be true or false", at: "persistent")
      return
    }
    guard definition["pause_hidden"] == nil || definition["pause_hidden"]?.bool != nil else {
      invalid(".pause_hidden must be true or false", at: "pause_hidden")
      return
    }
    let persistent = definition["persistent"]?.bool == true
    let pauseHidden = definition["pause_hidden"]?.bool == true
    guard persistent || !pauseHidden else {
      invalid(
        ".pause_hidden needs persistent = true: a fresh popup's process stops when it hides",
        at: "pause_hidden")
      return
    }
    guard
      let parsed = parseStatusProcess(
        definition, path: dotted, sourceURL: sourceURL, allowedKeys: terminalPopupKeys,
        directoryKey: "cwd", location: location, into: &config)
    else {
      config.invalidPopupNames.insert(name)
      return
    }
    config.popups[name] = .terminal(
      Config.Terminal(
        command: parsed.command, workingDirectory: parsed.workingDirectory,
        environment: parsed.environment, size: size,
        lifecycle: persistent ? .persistent : .fresh, pauseHidden: pauseHidden))
    config.popupSourceURLs.removeValue(forKey: name)
    config.invalidPopupNames.remove(name)
    config.recordLocation(path: dotted, location: location)
  }

  static let widgetKeys: Set<String> = [
    "enabled", "template", "screen", "anchor", "gap_x", "gap_y", "columns", "max_columns",
    "font", "font_size", "line_spacing", "fg", "bg", "border", "border_size", "corner_radius",
    "padding", "interval", "hide_from_capture",
  ]

  /// `[widgets.<name>]` tables. Like every section, a later layer overrides
  /// only the keys it sets; templates compile once every layer is applied.
  static func applyWidgets(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    guard let table else { return }
    for (name, value) in table {
      let path = ["widgets", name]
      let dotted = "widgets.\(name)"
      guard !name.isEmpty,
        name.unicodeScalars.allSatisfy({
          $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        })
      else {
        config.addDiagnostic(
          "widget name '\(name)' must use only letters, digits, '_' and '-'",
          location: locations.location(for: path))
        continue
      }
      guard let definition = value.table else {
        config.addDiagnostic(
          "\(dotted) must be a table of keys ([\(dotted)] on its own line)",
          location: locations.location(for: path))
        continue
      }
      warnUnknownKeys(
        in: definition, known: widgetKeys, path: path, locations: locations, into: &config)
      if config.widgets[name] == nil { config.widgets[name] = Config.Widget() }
      func key(_ key: String) -> [String] { path + [key] }
      applyBool(
        definition["enabled"], path: key("enabled"),
        message: "\(dotted).enabled must be true or false", locations: locations, into: &config
      ) { value, config in config.widgets[name]?.enabled = value }
      applyString(
        definition["template"], path: key("template"),
        message: "\(dotted).template must be a template string", locations: locations,
        into: &config
      ) { value, config in
        config.widgets[name]?.template.template = value.replacingOccurrences(
          of: "\r\n", with: "\n")
      }
      if let screen = definition["screen"] {
        let parsed: Config.Widget.Screen?
        switch (screen.string?.lowercased(), screen.int) {
        case ("primary", _): parsed = .primary
        case ("all", _): parsed = .all
        case (nil, let index?) where (1...64).contains(index): parsed = .index(index)
        default: parsed = nil
        }
        if let parsed {
          config.widgets[name]?.screen = parsed
          config.recordLocation(
            path: "\(dotted).screen", location: locations.location(for: key("screen")))
        } else {
          config.addDiagnostic(
            "\(dotted).screen must be \"primary\", \"all\" or a display number from 1 "
              + "(displays count left to right)",
            location: locations.location(for: key("screen")))
        }
      }
      applyString(
        definition["anchor"], path: key("anchor"),
        message: "\(dotted).anchor must be one of "
          + Config.Widget.Anchor.allCases.map(\.rawValue).joined(separator: ", "),
        locations: locations, into: &config,
        validate: { Config.Widget.Anchor(rawValue: $0) != nil },
        assign: { value, config in
          config.widgets[name]?.anchor = .init(rawValue: value) ?? .topLeft
        })
      for (field, keyPath) in [
        ("gap_x", \Config.Widget.gapX), ("gap_y", \Config.Widget.gapY),
      ] {
        applyDouble(
          definition[field], path: key(field),
          message: "\(dotted).\(field) must be a number between 0 and 4096 (points)",
          locations: locations, into: &config, validate: { (0...4_096).contains($0) },
          assign: { value, config in config.widgets[name]?[keyPath: keyPath] = value })
      }
      applyInt(
        definition["columns"], path: key("columns"),
        message: "\(dotted).columns must be an integer between 0 and 1000 (0 fits the content)",
        locations: locations, into: &config, validate: { (0...1_000).contains($0) },
        assign: { value, config in config.widgets[name]?.columns = value })
      applyInt(
        definition["max_columns"], path: key("max_columns"),
        message: "\(dotted).max_columns must be an integer between 1 and 1000",
        locations: locations, into: &config, validate: { (1...1_000).contains($0) },
        assign: { value, config in config.widgets[name]?.maxColumns = value })
      applyString(
        definition["font"], path: key("font"),
        message: "\(dotted).font must be a font name string", locations: locations,
        into: &config
      ) { value, config in
        config.widgets[name]?.font = value
        if StatusWidgetFont.resolve(name: value, size: 13) == nil {
          config.addDiagnostic(
            "\(dotted).font '\(value)' is not an installed monospaced font; "
              + "using the system monospaced font",
            location: locations.location(for: key("font")))
        }
      }
      for (field, keyPath, range, unit) in [
        ("font_size", \Config.Widget.fontSize, 6.0...200.0, "points"),
        ("line_spacing", \Config.Widget.lineSpacing, 0.0...200.0, "points"),
        ("border_size", \Config.Widget.borderSize, 0.0...64.0, "points"),
        ("corner_radius", \Config.Widget.cornerRadius, 0.0...200.0, "points"),
        ("padding", \Config.Widget.padding, 0.0...200.0, "points"),
      ] {
        applyDouble(
          definition[field], path: key(field),
          message: "\(dotted).\(field) must be a number between "
            + "\(Int(range.lowerBound)) and \(Int(range.upperBound)) (\(unit))",
          locations: locations, into: &config, validate: { range.contains($0) },
          assign: { value, config in config.widgets[name]?[keyPath: keyPath] = value })
      }
      applyString(
        definition["fg"], path: key("fg"),
        message: "\(dotted).fg must be a hex color like #RRGGBB", locations: locations,
        into: &config, validate: { $0.hasPrefix("#") && $0.count == 7 && isValidHexColor($0) },
        assign: { value, config in config.widgets[name]?.foreground = value })
      for (field, keyPath) in [
        ("bg", \Config.Widget.background), ("border", \Config.Widget.border),
      ] {
        applyString(
          definition[field], path: key(field),
          message: "\(dotted).\(field) must be a hex color like #RRGGBB or #RRGGBBAA",
          locations: locations, into: &config,
          validate: { $0.hasPrefix("#") && isValidHexColor($0) },
          assign: { value, config in config.widgets[name]?[keyPath: keyPath] = value })
      }
      applyInt(
        definition["interval"], path: key("interval"),
        message:
          "\(dotted).interval must be an integer between 0 and 86400 "
          + "(seconds; 0 follows statusbar.interval)",
        locations: locations, into: &config, validate: { (0...86_400).contains($0) },
        assign: { value, config in config.widgets[name]?.intervalSeconds = Double(value) })
      applyBool(
        definition["hide_from_capture"], path: key("hide_from_capture"),
        message: "\(dotted).hide_from_capture must be true or false", locations: locations,
        into: &config
      ) { value, config in config.widgets[name]?.hideFromCapture = value }
    }
  }
}
