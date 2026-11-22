import FlashCore
import Foundation
import TOMLKit

/// `[statusbar]`: its format, sources and templates.
extension ConfigLoader {
  static func applyStatusBar(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["enabled"], path: ["statusbar", "enabled"],
      message: "statusbar.enabled must be true or false", locations: locations, into: &config
    ) { value, config in
      config.statusBar.enabled = value
    }
    return applyStatusBarTail(table, locations: locations, sourceURL: sourceURL, into: &config)
  }

  private static func applyStatusBarTail(
    _ table: TOMLTable,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    into config: inout Config
  ) {
    applyString(
      table["template"], path: ["statusbar", "template"],
      message: "statusbar.template must be a quoted template string", locations: locations,
      into: &config
    ) { value, config in
      config.statusBar.template.template = value
    }
    applyString(
      table["monitor"], path: ["statusbar", "monitor"],
      message: "statusbar.monitor must be \"all\" or \"primary\"", locations: locations,
      into: &config, validate: { Config.StatusBar.Monitor(rawValue: $0.lowercased()) != nil },
      assign: { value, config in
        config.statusBar.monitor = Config.StatusBar.Monitor(rawValue: value.lowercased()) ?? .all
      })
    applyInt(
      table["interval"], path: ["statusbar", "interval"],
      message:
        "statusbar.interval must be an integer between 0 and 86400 (seconds; 0 disables polling)",
      locations: locations, into: &config, validate: { (0...86_400).contains($0) },
      assign: { value, config in
        config.statusBar.refreshIntervalSeconds = Double(value)
      })
    applyDouble(
      table["font_size"], path: ["statusbar", "font_size"],
      message: "statusbar.font_size must be a number between 8 and 32 (points)",
      locations: locations, into: &config, validate: { (8.0...32.0).contains($0) },
      assign: { value, config in
        config.statusBar.fontSize = value
      })
    applyDouble(
      table["command_timeout"], path: ["statusbar", "command_timeout"],
      message: "statusbar.command_timeout must be a number between 1 and 60 (seconds)",
      locations: locations, into: &config, validate: { (1.0...60.0).contains($0) },
      assign: { value, config in
        config.statusBar.commandTimeoutSeconds = value
      })
    applyDouble(
      table["notch_margin"], path: ["statusbar", "notch_margin"],
      message: "statusbar.notch_margin must be a number between 0 and 64 (points)",
      locations: locations, into: &config, validate: { (0.0...64.0).contains($0) },
      assign: { value, config in
        config.statusBar.notchMargin = value
      })
    // An allowlist: a misspelt entry must not slip in as a different scheme,
    // so the whole array is rejected when one entry is not an exact name.
    applyStringArray(
      table["link_schemes"], path: ["statusbar", "link_schemes"],
      message:
        "statusbar.link_schemes must be an array of lowercase URL scheme names "
        + "(\"slack\", \"x-apple.systempreferences\"), each once; http, https and mailto "
        + "are always allowed",
      locations: locations, into: &config,
      validate: { schemes in
        schemes.allSatisfy(StatusLinkPolicy.isSchemeName) && Set(schemes).count == schemes.count
      },
      assign: { value, config in
        config.statusBar.linkSchemes = value
      })
    applyStatusBarSources(table, locations: locations, sourceURL: sourceURL, into: &config)
    if let click = sectionTable(
      table["click"], name: "statusbar.click", locations: locations, into: &config)
    {
      for (name, value) in click {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let location = locations.location(for: ["statusbar", "click", name])
        guard !trimmedName.isEmpty else { continue }
        if let url = value.string {
          if URLParsing.url(url) != nil, !url.isEmpty {
            config.statusBar.clickActions[trimmedName] = .url(url)
            config.recordLocation(path: "statusbar.click.\(trimmedName)", location: location)
          } else {
            config.addDiagnostic(
              "statusbar.click.\(name) must be a valid URL or a [\"flash\", \"<topic>\", \"<action>\", …] action array",
              location: location)
          }
        } else if let action = parseMappingCommandValue(value, sourceURL: sourceURL) {
          config.statusBar.clickActions[trimmedName] = .command(action)
          config.recordLocation(path: "statusbar.click.\(trimmedName)", location: location)
        } else {
          config.addDiagnostic(
            "statusbar.click.\(name) must be a URL string or a [\"flash\", \"<topic>\", \"<action>\", …] action array",
            location: location)
        }
      }
    }
  }

  private static func statusProcessInteger(
    _ table: TOMLTable, key: String, fallback: Int, range: ClosedRange<Int>,
    path: String, location: ConfigLocation?, into config: inout Config
  ) -> Int? {
    guard let value = table[key] else { return fallback }
    guard let integer = value.int ?? value.double.flatMap({ Int(exactly: $0) }),
      range.contains(integer)
    else {
      config.addDiagnostic(
        "\(path).\(key) must be an integer between \(range.lowerBound) and \(range.upperBound)",
        location: location)
      return nil
    }
    return integer
  }

  /// `directoryKey` names the working-directory key: `working_directory` for
  /// sources, `cwd` for popups.
  static func parseStatusProcess(
    _ table: TOMLTable, path: String, sourceURL: URL?, allowedKeys: Set<String>,
    directoryKey: String = "working_directory",
    location: ConfigLocation?, into config: inout Config
  ) -> (command: [String], workingDirectory: String?, environment: [String: String])? {
    func invalid(_ message: String) {
      config.addDiagnostic("\(path) \(message)", location: location)
    }
    if let key = table.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
      invalid("contains unknown key \"\(key)\"")
      return nil
    }
    guard let values = table["command"]?.array, !values.isEmpty,
      values.allSatisfy({ $0.string != nil }),
      let head = values.first?.string, !head.isEmpty
    else {
      invalid("command must be a nonempty array of strings")
      return nil
    }
    let command =
      [head.hasPrefix("$") ? head : resolveCommandArgument(head, sourceURL: sourceURL)]
      + values.dropFirst().compactMap(\.string)
    guard command.allSatisfy({ !$0.utf8.contains(0) }) else {
      invalid("command must not contain NUL bytes")
      return nil
    }
    var directory: String?
    if let value = table[directoryKey] {
      guard let raw = value.string, !raw.isEmpty, !raw.utf8.contains(0) else {
        invalid("\(directoryKey) must be a nonempty path string")
        return nil
      }
      directory =
        raw.hasPrefix("$")
        ? raw
        : resolveCommandArgument(
          raw.hasPrefix("/") || raw.hasPrefix("~") ? raw : "./" + raw,
          sourceURL: sourceURL)
    }
    var environment: [String: String] = [:]
    if let value = table["env"] {
      guard let entries = value.table else {
        invalid("env must be a table of strings")
        return nil
      }
      for (key, entry) in entries {
        guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0),
          let string = entry.string, !string.utf8.contains(0)
        else {
          invalid("env must have valid environment names and string values")
          return nil
        }
        environment[key] = string
      }
    }
    return (command, directory, environment)
  }

  private static func applyStatusBarSources(
    _ table: TOMLTable, locations: ConfigSourceLocationIndex, sourceURL: URL?,
    into config: inout Config
  ) {
    guard
      let sources = sectionTable(
        table["sources"], name: "statusbar.sources", locations: locations, into: &config)
    else { return }
    for (name, value) in sources {
      let path = "statusbar.sources.\(name)"
      let location = locations.location(for: ["statusbar", "sources", name])
      guard let definition = value.table else {
        config.addDiagnostic("\(path) must be a table with command argv", location: location)
        continue
      }
      // Without a command the source is pushed (`status set`): it runs
      // nothing, so only what shapes its value applies.
      if definition["command"] == nil {
        if let key = definition.keys.sorted().first(where: { !pushedStatusSourceKeys.contains($0) })
        {
          config.addDiagnostic(
            "\(path).\(key) needs a command; a source without one is set by `status set`",
            location: location)
          continue
        }
      }
      guard
        let parsed = definition["command"] == nil
          ? (command: [String](), workingDirectory: String?.none, environment: [String: String]())
          : parseStatusProcess(
            definition, path: path, sourceURL: sourceURL,
            allowedKeys: statusSourceKeys,
            location: location, into: &config),
        let interval = statusProcessInteger(
          definition, key: "interval",
          fallback: Int(config.statusBar.refreshIntervalSeconds), range: 0...86400,
          path: path, location: location, into: &config),
        let history = statusProcessInteger(
          definition, key: "history", fallback: 0, range: 2...512,
          path: path, location: location, into: &config)
      else { continue }
      if definition["history"] != nil, definition["cycle_interval"] != nil {
        config.addDiagnostic(
          "\(path) history keeps numeric samples and cannot combine with cycle_interval",
          location: location)
        continue
      }
      var output = FlashStatusBarSourceOutput.text
      if let raw = definition["output"] {
        let names = FlashStatusBarSourceOutput.allCases.map { "\"\($0.rawValue)\"" }
        guard let name = raw.string, let parsed = FlashStatusBarSourceOutput(rawValue: name) else {
          config.addDiagnostic(
            "\(path).output must be one of \(names.joined(separator: ", "))", location: location)
          continue
        }
        output = parsed
      }
      var cycle: Double?
      if definition["cycle_interval"] != nil {
        guard
          let seconds = statusProcessInteger(
            definition, key: "cycle_interval", fallback: 60,
            range: 1...86400, path: path, location: location, into: &config)
        else { continue }
        cycle = Double(seconds)
      }
      config.statusBar.sources[name] = FlashStatusBarSourceDefinition(
        command: parsed.command, workingDirectory: parsed.workingDirectory,
        environment: parsed.environment, intervalSeconds: Double(interval),
        cycleIntervalSeconds: cycle, timeoutSeconds: config.statusBar.commandTimeoutSeconds,
        historyLength: history > 0 ? history : nil, output: output)
      config.recordLocation(path: path, location: location)
      if definition["interval"] == nil {
        config.statusBar.sourcesUsingDefaultInterval.insert(name)
      } else {
        config.statusBar.sourcesUsingDefaultInterval.remove(name)
      }
    }
  }

  static func applyStatusBarTemplates(into config: inout Config) {
    for name in config.statusBar.sources.keys {
      if config.statusBar.sourcesUsingDefaultInterval.contains(name) {
        config.statusBar.sources[name]?.intervalSeconds = config.statusBar.refreshIntervalSeconds
      }
      config.statusBar.sources[name]?.timeoutSeconds = config.statusBar.commandTimeoutSeconds
    }
    /// `path` is the dotted config path, also the program's origin. Widget
    /// templates may read `flash.widget.*`; elsewhere those values exist only
    /// inside widgets.
    func compiled(
      _ text: String, path: String, widget: Bool = false, into config: inout Config
    ) -> FlashStatusBarTemplate {
      let program = StatusFormatProgram.compile(source: text, origin: StatusFormatOrigin(path))
      recordStatusFormatDiagnostics(program, path: path, into: &config)
      let dependencies = program.dependencies
      var variables: [FlashStatusBarTemplateVariable] = []
      func diagnose(_ message: String) {
        config.addDiagnostic("\(path) \(message)", location: config.valueLocations[path])
      }
      for token in dependencies.values.sorted() {
        let source: FlashStatusBarSource?
        if let sdk = FlashStatusBarTemplateEngine.sdkValue(for: token) {
          source = .sdk(sdk)
        } else if token.hasPrefix("flash.plugin.") {
          let field = String(token.dropFirst("flash.plugin.".count))
          switch field {
          case "loaded_count": source = .plugin(.loadedCount)
          case "ready_count": source = .plugin(.readyCount)
          case "error_count": source = .plugin(.errorCount)
          case "errors": source = .plugin(.errors)
          case "spawn_ms": source = .plugin(.spawnMs)
          case "spawn_id": source = .plugin(.spawnID)
          default:
            if let dot = field.lastIndex(of: "."), dot != field.startIndex,
              field.index(after: dot) < field.endIndex
            {
              source = .plugin(
                .statusSegment(
                  pluginID: String(field[..<dot]),
                  name: String(field[field.index(after: dot)...])))
            } else {
              source = nil
              diagnose("has invalid plugin value \(token)")
            }
          }
        } else if token.hasPrefix("flash.source.") || token.hasPrefix("flash.history.") {
          source = nil
          let history = token.hasPrefix("flash.history.")
          let name = String(token.dropFirst((history ? "flash.history." : "flash.source.").count))
          if config.statusBar.sources[name] == nil {
            diagnose("references undefined source \(name)")
          } else if history, config.statusBar.sources[name]?.historyLength == nil {
            diagnose("reads \(token), but statusbar.sources.\(name) sets no history")
          }
        } else if TelemetryQuery.isTelemetryKey(token) {
          source = nil
          if TelemetryQuery(key: token) == nil {
            diagnose(
              "has invalid telemetry value \(token); write #{flash.otel[.<field>]:<metric>"
                + "[<attribute>=<value>]…}")
          } else if !config.telemetry.receiver.enabled {
            diagnose("reads \(token), but [telemetry.receiver] is not enabled")
          }
        } else if token.hasPrefix("flash.widget.") {
          source = nil
          if !(widget && ["flash.widget.name", "flash.widget.columns"].contains(token)) {
            diagnose("has unknown Flash value \(token)")
          }
        } else {
          source = nil
          if token.hasPrefix("flash.") { diagnose("has unknown Flash value \(token)") }
        }
        if let source {
          variables.append(.init(id: "\(path).\(token)", token: token, source: source))
        }
      }
      return FlashStatusBarTemplate(
        template: text, variables: variables, sourceNames: Set(config.statusBar.sources.keys),
        origin: StatusFormatOrigin(path))
    }
    // The bar is one line. Its template keeps its newlines, as any expanded
    // value does: a newline separates style tokens inside a marker, and the
    // evaluated runs drop it from the drawn text (`normalizedTemplate`).
    config.statusBar.template = compiled(
      config.statusBar.template.template, path: "statusbar.template", into: &config)
    for (name, popup) in config.textPopups.sorted(by: { $0.key < $1.key }) {
      let text = popup.template.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      config.popups[name] = .text(compiled(text, path: "popup.\(name)", into: &config))
    }
    for name in config.widgets.keys.sorted() {
      guard let widget = config.widgets[name] else { continue }
      let path = "widgets.\(name)"
      guard !widget.template.template.isEmpty else {
        if widget.enabled {
          config.addDiagnostic(
            "\(path).template is required", location: config.valueLocations[path])
        }
        continue
      }
      let template = compiled(
        widget.template.template, path: "\(path).template", widget: true, into: &config)
      config.widgets[name]?.template = template
      let interactive = StatusFormatDocument.styleTokens(in: widget.template.template)
        .compactMap { token in
          ["link=", "popup=", "range="].first { token.lowercased().hasPrefix($0) }
        }
      if widget.enabled, !interactive.isEmpty {
        config.addDiagnostic(
          "\(path) uses \(Set(interactive).sorted().joined(separator: ", ")) but widgets are "
            + "click-through; links, popups and click ranges do nothing there",
          location: config.valueLocations["\(path).template"])
      }
    }
    // Monitors compile in the controller; here their formats are only
    // checked for unknown values and undefined sources.
    for name in config.monitors.keys.sorted() {
      guard let monitor = config.monitors[name] else { continue }
      for (field, text) in [
        ("value", monitor.value), ("message", monitor.message), ("detail", monitor.detail),
      ] where !text.isEmpty {
        _ = compiled(text, path: "monitors.\(name).\(field)", into: &config)
      }
    }
  }

  private static func recordStatusFormatDiagnostics(
    _ program: StatusFormatProgram, path: String, into config: inout Config
  ) {
    for diagnostic in program.diagnostics {
      config.addDiagnostic(
        "\(path): \(diagnostic.message) (format byte \(diagnostic.span.bytes.lowerBound))",
        location: config.valueLocations[path])
    }
  }
}
