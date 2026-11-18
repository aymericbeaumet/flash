import FlashCore
import Foundation
import TOMLKit

/// `[app]`, `[keyboard]`, `[clipboard]`, `[calendar]`, `[startup]` and `[debug]`.
extension ConfigLoader {
  static func applyClipboard(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    guard let table else { return }
    applyInt(
      table["history_size"], path: ["clipboard", "history_size"],
      message: "clipboard.history_size must be an integer between 1 and 10000",
      locations: locations, into: &config, validate: { (1...10_000).contains($0) },
      assign: { value, config in config.clipboard.historySize = value })
  }

  static func applyCalendar(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    guard let table else { return }
    applyStringArray(
      table["calendars"], path: ["calendar", "calendars"],
      message: "calendar.calendars must be an array of calendar titles", locations: locations,
      into: &config
    ) { value, config in
      config.calendar.calendars = value
    }
    applyBool(
      table["all_day"], path: ["calendar", "all_day"],
      message: "calendar.all_day must be true or false", locations: locations, into: &config
    ) { value, config in
      config.calendar.allDay = value
    }
    applyBool(
      table["declined"], path: ["calendar", "declined"],
      message: "calendar.declined must be true or false", locations: locations, into: &config
    ) { value, config in
      config.calendar.declined = value
    }
    let hours = CalendarSettings.lookaheadHoursRange
    applyInt(
      table["lookahead_hours"], path: ["calendar", "lookahead_hours"],
      message:
        "calendar.lookahead_hours must be an integer between \(hours.lowerBound) and \(hours.upperBound)",
      locations: locations, into: &config, validate: { hours.contains($0) },
      assign: { value, config in config.calendar.lookaheadHours = value })
  }

  static func applyApp(
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
    applyString(
      table["keyboard_layout"], path: ["app", "keyboard_layout"],
      message:
        "app.keyboard_layout must be \"auto\" or an input-source ID such as "
        + "\"com.apple.keylayout.US\"",
      locations: locations, into: &config,
      validate: { KeyboardLayout.Setting($0) != nil },
      assign: { value, config in config.app.keyboardLayout = value })
    applyString(
      table["updates"], path: ["app", "updates"],
      message: "app.updates must be \"install\", \"check\" or \"off\"",
      locations: locations, into: &config,
      validate: { UpdateMode(rawValue: $0) != nil },
      assign: { value, config in config.app.updates = UpdateMode(rawValue: value) ?? .install })
    applyBool(
      table["hide_from_capture"], path: ["app", "hide_from_capture"],
      message: "app.hide_from_capture must be true or false", locations: locations,
      into: &config
    ) { value, config in
      config.app.hideFromCapture = value
    }
  }

  static func applyKeyboard(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let table else { return }
    let names = Alphabet.layoutNames.joined(separator: ", ")
    applyString(
      table["layout"], path: ["keyboard", "layout"],
      message: "keyboard.layout must be one of \(names)",
      locations: locations, into: &config,
      validate: { Alphabet.layouts[$0.lowercased()] != nil },
      assign: { value, config in config.keyboard.layout = value.lowercased() })
  }

  /// `[startup]`: `run` is a monitor's `run` (one command, or a list run in
  /// order), or `[]` for none; a later layer replaces the whole list. A list
  /// with any malformed command is rejected whole, so a layer never runs part
  /// of what it declared.
  static func applyStartup(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    if let raw = table["run"] {
      let location = locations.location(for: ["startup", "run"])
      if raw.array?.isEmpty == true {
        config.startup.run = []
        config.recordLocation(path: "startup.run", location: location)
      } else if let steps = parseMonitorRun(raw, sourceURL: sourceURL) {
        if steps.contains(.flashCommand(.startup(.run))) {
          config.addDiagnostic(
            "startup.run cannot run startup run: it would start itself again", location: location)
        } else {
          config.startup.run = steps
          config.recordLocation(path: "startup.run", location: location)
        }
      } else {
        config.addDiagnostic(
          "startup.run must be a list of commands run in order, each [\"flash\", \"<topic>\", "
            + "\"<action>\", …] or an executable with its arguments ([\"killall\", \"Dock\"])",
          location: location)
      }
    }
    applyInt(
      table["timeout"], path: ["startup", "timeout"],
      message: "startup.timeout must be an integer between 1 and 86400 (seconds per command)",
      locations: locations, into: &config,
      validate: { MonitorRunDefaults.timeoutRange.contains($0) },
      assign: { value, config in config.startup.timeoutSeconds = value })
  }

  static func applyDebug(
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
    applyHexColor(
      table, ["debug", "hints_bounds_bg"], locations: locations, into: &config,
      \.debug.hintsBoundsBG)
    applyHexColor(
      table, ["debug", "hints_bounds_fg"], locations: locations, into: &config,
      \.debug.hintsBoundsFG)

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
}
