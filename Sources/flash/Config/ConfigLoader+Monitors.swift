import FlashCore
import Foundation
import TOMLKit

/// `[monitors.<name>]`.
extension ConfigLoader {
  static let monitorKeys: Set<String> = [
    "enabled", "value", "message", "detail", "warning", "error", "direction", "interval",
    "event", "app", "usb", "idle", "at", "days", "run", "alert", "notify", "timeout", "cooldown",
  ]

  /// `[monitors.<name>]` tables. A later layer overrides only the keys it
  /// sets, so a user file can retune or disable a built-in monitor; a
  /// threshold set to `false` removes it. Whether the result is complete is
  /// judged once every layer is applied (`diagnoseMonitors`).
  static func applyMonitors(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    for (name, value) in table {
      let path = ["monitors", name]
      let dotted = "monitors.\(name)"
      guard !name.isEmpty,
        name.unicodeScalars.allSatisfy({
          $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        })
      else {
        config.addDiagnostic(
          "monitor name '\(name)' must use only letters, digits, '_' and '-'",
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
        in: definition, known: monitorKeys, path: path, locations: locations, into: &config)
      if config.monitors[name] == nil { config.monitors[name] = Config.Monitor() }
      func key(_ key: String) -> [String] { path + [key] }
      applyBool(
        definition["enabled"], path: key("enabled"),
        message: "\(dotted).enabled must be true or false", locations: locations, into: &config
      ) { value, config in config.monitors[name]?.enabled = value }
      applyString(
        definition["value"], path: key("value"),
        message: "\(dotted).value must be a non-empty status format string",
        locations: locations, into: &config, validate: { !$0.isEmpty },
        assign: { value, config in config.monitors[name]?.value = value })
      applyString(
        definition["message"], path: key("message"),
        message: "\(dotted).message must be a status format string", locations: locations,
        into: &config
      ) { value, config in config.monitors[name]?.message = value }
      applyString(
        definition["detail"], path: key("detail"),
        message: "\(dotted).detail must be a status format string", locations: locations,
        into: &config
      ) { value, config in config.monitors[name]?.detail = value }
      for (field, keyPath) in [
        ("warning", \Config.Monitor.warning), ("error", \Config.Monitor.error),
      ] {
        guard let raw = definition[field] else { continue }
        let location = locations.location(for: key(field))
        if raw.bool == false {
          config.monitors[name]?[keyPath: keyPath] = nil
        } else if let number = raw.double ?? raw.int.map(Double.init), number.isFinite {
          config.monitors[name]?[keyPath: keyPath] = number
        } else {
          config.addDiagnostic(
            "\(dotted).\(field) must be a number, or false to remove it", location: location)
          continue
        }
        config.recordLocation(path: "\(dotted).\(field)", location: location)
      }
      applyString(
        definition["direction"], path: key("direction"),
        message: "\(dotted).direction must be \"above\" or \"below\"", locations: locations,
        into: &config, validate: { MonitorDirection(rawValue: $0) != nil },
        assign: { value, config in
          config.monitors[name]?.direction = MonitorDirection(rawValue: value) ?? .above
        })
      applyInt(
        definition["interval"], path: key("interval"),
        message: "\(dotted).interval must be an integer between 1 and 86400 (seconds)",
        locations: locations, into: &config, validate: { (1...86_400).contains($0) },
        assign: { value, config in config.monitors[name]?.intervalSeconds = Double(value) })
      if let raw = definition["event"] {
        let location = locations.location(for: key("event"))
        let patterns = raw.string.map { [$0] } ?? stringArrayValue(raw)
        if let patterns, !patterns.isEmpty, patterns.allSatisfy({ !$0.trimmed.isEmpty }) {
          config.monitors[name]?.event = patterns
          config.recordLocation(path: "\(dotted).event", location: location)
        } else {
          config.addDiagnostic(
            "\(dotted).event must be a host event name or glob (\"core:system.woke\"), or a list",
            location: location)
        }
      }
      applyString(
        definition["app"], path: key("app"),
        message: "\(dotted).app must be a bundle identifier", locations: locations,
        into: &config, validate: { !$0.isEmpty },
        assign: { value, config in config.monitors[name]?.app = value })
      if let raw = definition["usb"] {
        let location = locations.location(for: key("usb"))
        if let filter = parseUSBDeviceFilter(
          raw, path: key("usb"), dotted: "\(dotted).usb", location: location,
          locations: locations, into: &config)
        {
          config.monitors[name]?.usb = filter
          config.recordLocation(path: "\(dotted).usb", location: location)
        }
      }
      applyBool(
        definition["alert"], path: key("alert"),
        message: "\(dotted).alert must be true or false", locations: locations, into: &config
      ) { value, config in config.monitors[name]?.alert = value }
      applyBool(
        definition["notify"], path: key("notify"),
        message: "\(dotted).notify must be true or false", locations: locations, into: &config
      ) { value, config in config.monitors[name]?.notify = value }
      applyInt(
        definition["timeout"], path: key("timeout"),
        message: "\(dotted).timeout must be an integer between 1 and 86400 (seconds)",
        locations: locations, into: &config,
        validate: { MonitorRunDefaults.timeoutRange.contains($0) },
        assign: { value, config in config.monitors[name]?.timeoutSeconds = value })
      applyInt(
        definition["idle"], path: key("idle"),
        message: "\(dotted).idle must be an integer between 1 and 86400 (seconds)",
        locations: locations, into: &config,
        validate: { IdleWatch.secondsRange.contains($0) },
        assign: { value, config in config.monitors[name]?.idleSeconds = value })
      if let raw = definition["at"] {
        let location = locations.location(for: key("at"))
        let times = (raw.string.map { [$0] } ?? stringArrayValue(raw))?.map(ClockTime.init)
        if let times, !times.isEmpty, times.allSatisfy({ $0 != nil }) {
          config.monitors[name]?.at = times.compactMap { $0 }
          config.recordLocation(path: "\(dotted).at", location: location)
        } else {
          config.addDiagnostic(
            "\(dotted).at must be a time of day as \"HH:MM\" (\"09:55\"), or a list of them",
            location: location)
        }
      }
      if let raw = definition["days"] {
        let location = locations.location(for: key("days"))
        let days = (raw.string.map { [$0] } ?? stringArrayValue(raw))?.map(Weekday.init)
        if let days, !days.isEmpty, days.allSatisfy({ $0 != nil }) {
          config.monitors[name]?.days = days.compactMap { $0 }
          config.recordLocation(path: "\(dotted).days", location: location)
        } else {
          config.addDiagnostic(
            "\(dotted).days must be a day of the week (\"mon\" through \"sun\"), or a list of them",
            location: location)
        }
      }
      applyInt(
        definition["cooldown"], path: key("cooldown"),
        message: "\(dotted).cooldown must be an integer between 0 and 604800 (seconds)",
        locations: locations, into: &config,
        validate: { MonitorRunDefaults.cooldownRange.contains($0) },
        assign: { value, config in config.monitors[name]?.cooldownSeconds = value })
      if let raw = definition["run"] {
        let location = locations.location(for: key("run"))
        if raw.bool == false {
          config.monitors[name]?.run = []
        } else if let steps = parseMonitorRun(raw, sourceURL: sourceURL) {
          config.monitors[name]?.run = steps
        } else {
          config.addDiagnostic(
            "\(dotted).run must be a command array, [\"flash\", \"<topic>\", \"<action>\", …] "
              + "or an executable with its arguments, a list of such commands run in order, "
              + "or false to remove it",
            location: location)
          continue
        }
        config.recordLocation(path: "\(dotted).run", location: location)
      }
    }
  }

  /// A monitor's `usb` table, `{ vendor_id = 0x05ac, product_id = 0x024f,
  /// name = "Keyboard" }` or `[monitors.<name>.usb]`: any subset, never
  /// empty. An inline table's keys share its line, so their diagnostics
  /// fall back to the table's location.
  private static func parseUSBDeviceFilter(
    _ raw: any TOMLValueConvertible, path: [String], dotted: String,
    location: ConfigLocation?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) -> USBDeviceFilter? {
    guard let table = raw.table else {
      config.addDiagnostic(
        "\(dotted) must be a table naming the device: "
          + "{ vendor_id = 0x05ac, product_id = 0x024f, name = \"Keyboard\" }, any subset",
        location: location)
      return nil
    }
    let keys = ["vendor_id", "product_id", "name"]
    var valid = true
    for key in table.keys.sorted() where !keys.contains(key) {
      config.addDiagnostic(
        "\(dotted): unknown key '\(key)'; known keys: \(keys.joined(separator: ", "))",
        location: locations.location(for: path + [key]) ?? location)
      valid = false
    }
    var filter = USBDeviceFilter()
    for (key, keyPath) in [
      ("vendor_id", \USBDeviceFilter.vendorID), ("product_id", \USBDeviceFilter.productID),
    ] {
      guard let value = table[key] else { continue }
      if let id = value.int, (0...0xFFFF).contains(id) {
        filter[keyPath: keyPath] = id
      } else {
        config.addDiagnostic(
          "\(dotted).\(key) must be an integer between 0 and 65535 (0x05ac)",
          location: locations.location(for: path + [key]) ?? location)
        valid = false
      }
    }
    if let value = table["name"] {
      if let text = value.string, !text.isEmpty {
        filter.name = text
      } else {
        config.addDiagnostic(
          "\(dotted).name must be a non-empty string, a part of the product name",
          location: locations.location(for: path + ["name"]) ?? location)
        valid = false
      }
    }
    guard valid else { return nil }
    guard !filter.isEmpty else {
      config.addDiagnostic(
        "\(dotted) must name the device: a vendor_id, a product_id or a name", location: location)
      return nil
    }
    return filter
  }

  /// A monitor's `run`: one command, or a non-empty list of commands run in
  /// order. A list mixing commands and words, or holding an empty command,
  /// is malformed.
  static func parseMonitorRun(_ raw: any TOMLValueConvertible, sourceURL: URL?)
    -> [MappingCommand]?
  {
    guard let items = raw.array, !items.isEmpty else { return nil }
    guard items.allSatisfy({ $0.array != nil }) else {
      return parseMappingCommandValue(raw, sourceURL: sourceURL).map { [$0] }
    }
    var steps: [MappingCommand] = []
    for item in items {
      guard let step = parseMappingCommandValue(item, sourceURL: sourceURL) else { return nil }
      steps.append(step)
    }
    return steps
  }

  /// After every layer: an enabled monitor without a value or a threshold,
  /// or with thresholds in the wrong order, is reported and does not run.
  static func diagnoseMonitors(into config: inout Config) {
    for name in config.monitors.keys.sorted() {
      guard let monitor = config.monitors[name], monitor.enabled,
        let problem = monitor.problem
      else { continue }
      let locations = config.valueLocations
      let location = [
        "value", "event", "warning", "error", "run", "app", "usb", "direction", "timeout",
        "cooldown", "notify", "enabled",
      ]
      .compactMap { locations["monitors.\(name).\($0)"] }.first
      config.addDiagnostic("monitors.\(name)\(problem)", location: location)
    }
  }
}
