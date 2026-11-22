import FlashCore
import Foundation
import TOMLKit

/// `[mode]`, its per-mode tables and `[mode.layers.<name>]`.
extension ConfigLoader {
  /// Precedence values are user-tunable ranking weights, not magnitudes —
  /// ±10k spans every sensible tier while keeping additions overflow-proof.
  static let precedenceBound = 10_000

  static func applyMode(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    guard let table else { return }

    let labelsPath = ["mode", "labels"]
    if let value = table["labels"] {
      let location = locations.location(for: labelsPath)
      // Labels drive status-bar width math (`longestCount`), so bound their
      // length; unknown sub-keys are typos worth naming.
      if let parsed = stringTableValue(value),
        let normal = parsed["normal"],
        let insert = parsed["insert"],
        let command = parsed["command"],
        (1...32).contains(normal.count),
        (1...32).contains(insert.count),
        (1...32).contains(command.count),
        (1...32).contains((parsed["terminal"] ?? config.mode.labels.terminal).count),
        (1...32).contains((parsed["hyper"] ?? config.mode.labels.hyper).count),
        (1...32).contains((parsed["hold"] ?? config.mode.labels.hold).count),
        (1...32).contains((parsed["visual"] ?? config.mode.labels.visual).count),
        (1...32).contains((parsed["visual_line"] ?? config.mode.labels.visualLine).count)
      {
        for key in parsed.keys where !modeLabelKeys.contains(key) {
          config.addDiagnostic(
            "mode.labels: unknown key '\(key)' (valid keys are normal, insert, command, terminal, hyper, hold, visual, visual_line)",
            location: location)
        }
        config.mode.labels = Config.Mode.Labels(
          normal: normal,
          insert: insert,
          command: command,
          terminal: parsed["terminal"] ?? config.mode.labels.terminal,
          hyper: parsed["hyper"] ?? config.mode.labels.hyper,
          hold: parsed["hold"] ?? config.mode.labels.hold,
          visual: parsed["visual"] ?? config.mode.labels.visual,
          visualLine: parsed["visual_line"] ?? config.mode.labels.visualLine)
        config.recordLocation(path: "mode.labels", location: location)
      } else {
        config.addDiagnostic(
          "mode.labels must be { normal = \"...\", insert = \"...\", command = \"...\", terminal = \"...\", hyper = \"...\" } "
            + "with each label 1-32 characters",
          location: location)
      }
    }

    applyInt(
      table["sequence_timeout_ms"], path: ["mode", "sequence_timeout_ms"],
      message: "mode.sequence_timeout_ms must be an integer between 0 and 10000 (ms)",
      locations: locations,
      into: &config, validate: { (0...10_000).contains($0) },
      assign: { value, config in
        config.mode.sequenceTimeoutMs = value
      })
    applyInt(
      table["which_key_ms"], path: ["mode", "which_key_ms"],
      message: "mode.which_key_ms must be an integer between 0 and 10000 (ms; 0 turns it off)",
      locations: locations,
      into: &config, validate: { (0...10_000).contains($0) },
      assign: { value, config in config.mode.whichKeyMs = value })
    applyInt(
      table["scroll_step"], path: ["mode", "scroll_step"],
      message: "mode.scroll_step must be an integer between 10 and 500 (pixels)",
      locations: locations, into: &config, validate: { (10...500).contains($0) },
      assign: { value, config in
        config.mode.scrollStep = value
      })
    applyInt(
      table["scroll_step_lines"], path: ["mode", "scroll_step_lines"],
      message: "mode.scroll_step_lines must be an integer between 1 and 1000 (lines)",
      locations: locations, into: &config, validate: { (1...1000).contains($0) },
      assign: { value, config in
        config.mode.scrollStepLines = value
      })
    applyInt(
      table["scroll_page_lines"], path: ["mode", "scroll_page_lines"],
      message: "mode.scroll_page_lines must be an integer between 1 and 1000 (lines)",
      locations: locations, into: &config, validate: { (1...1000).contains($0) },
      assign: { value, config in
        config.mode.scrollPageLines = value
      })
    applyInt(
      table["move_page_lines"], path: ["mode", "move_page_lines"],
      message: "mode.move_page_lines must be an integer between 1 and 200 (arrows)",
      locations: locations, into: &config, validate: { (1...200).contains($0) },
      assign: { value, config in
        config.mode.movePageLines = value
      })
    applyInt(
      table["scroll_smooth_ms"], path: ["mode", "scroll_smooth_ms"],
      message:
        "mode.scroll_smooth_ms must be an integer between 0 and \(SmoothScroll.maxDurationMs) (ms; 0 scrolls at once)",
      locations: locations, into: &config,
      validate: { (0...SmoothScroll.maxDurationMs).contains($0) },
      assign: { value, config in
        config.mode.scrollSmoothMs = value
      })
    applyInt(
      table["click_hold_ms"], path: ["mode", "click_hold_ms"],
      message: "mode.click_hold_ms must be an integer between 0 and 200 (ms)",
      locations: locations, into: &config, validate: { (0...200).contains($0) },
      assign: { value, config in
        config.mode.clickHoldMs = value
      })
    applyInt(
      table["send_key_interval_ms"], path: ["mode", "send_key_interval_ms"],
      message: "mode.send_key_interval_ms must be an integer between 0 and 500 (ms)",
      locations: locations, into: &config, validate: { (0...500).contains($0) },
      assign: { value, config in
        config.mode.sendKeyIntervalMs = value
      })

    if let normal = sectionTable(
      table["normal"], name: "mode.normal", locations: locations, into: &config)
    {
      if normal["leader"]?.bool == false {
        config.mode.normalLeader = nil
        config.recordLocation(
          path: "mode.normal.leader",
          location: locations.location(for: ["mode", "normal", "leader"]))
      } else {
        applyString(
          normal["leader"], path: ["mode", "normal", "leader"],
          message:
            "mode.normal.leader must be a single key (e.g. \"\\\\\" or \",\"), or false to clear it",
          locations: locations,
          into: &config,
          validate: {
            // Reject multi-atom strings here — otherwise every <leader>
            // mapping later fails with a misleading "leader is not set".
            NormalModeInterpreter.translateLeader(canonicalNormalModeKeyToken($0)) != nil
          },
          assign: { value, config in
            config.mode.normalLeader = canonicalNormalModeKeyToken(value)
          })
      }
      applyString(
        normal["hyper"], path: ["mode", "normal", "hyper"],
        message:
          "mode.normal.hyper must be one key (\"<leader>\", \"a\", \"<space>\", \"cmd+space\")",
        locations: locations,
        into: &config,
        validate: { Config.Mode.resolveHyperKey($0, leader: "\\") != nil },
        assign: { value, config in
          config.mode.hyperKey = value
        })
      applyModeMappingTable(
        sectionTable(
          normal["mappings"], name: "mode.normal.mappings", locations: locations, into: &config),
        scope: .normal,
        path: ["mode", "normal", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in normal where !modeNormalKeys.contains(key) {
        config.addDiagnostic(
          "mode.normal: unknown key '\(key)' — mappings belong under "
            + "[mode.normal.mappings]; valid keys are leader, hyper, mappings",
          location: locations.location(for: ["mode", "normal", key]))
      }
    }

    if let all = sectionTable(table["all"], name: "mode.all", locations: locations, into: &config) {
      applyModeMappingTable(
        sectionTable(
          all["mappings"], name: "mode.all.mappings", locations: locations, into: &config),
        scope: .all,
        path: ["mode", "all", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in all where key != "mappings" {
        config.addDiagnostic(
          "mode.all: unknown key '\(key)' — mappings belong under [mode.all.mappings]",
          location: locations.location(for: ["mode", "all", key]))
      }
    }

    // `[mode.text]` carries the engagement switch beside its table.
    if let text = sectionTable(
      table["text"], name: "mode.text", locations: locations, into: &config)
    {
      applyBool(
        text["enabled"], path: ["mode", "text", "enabled"],
        message: "mode.text.enabled must be true or false",
        locations: locations, into: &config,
        assign: { value, config in
          config.mode.textEnabled = value
        })
      applyModeMappingTable(
        sectionTable(
          text["mappings"], name: "mode.text.mappings", locations: locations, into: &config),
        scope: .text,
        path: ["mode", "text", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)
      for (key, _) in text where !modeTextKeys.contains(key) {
        config.addDiagnostic(
          "mode.text: unknown key '\(key)' — mappings belong under [mode.text.mappings]; "
            + "valid keys are enabled, mappings",
          location: locations.location(for: ["mode", "text", key]))
      }
    }

    for scope in [ModeScope.insert, .terminal, .hyper, .hold, .visual] {
      let name = scope.rawValue
      guard
        let scoped = sectionTable(
          table[name], name: "mode.\(name)", locations: locations, into: &config)
      else { continue }
      applyModeMappingTable(
        sectionTable(
          scoped["mappings"], name: "mode.\(name).mappings", locations: locations, into: &config),
        scope: scope,
        path: ["mode", name, "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)
      for (key, _) in scoped where key != "mappings" {
        config.addDiagnostic(
          "mode.\(name): unknown key '\(key)' — mappings belong under [mode.\(name).mappings]",
          location: locations.location(for: ["mode", name, key]))
      }
    }

    if let command = sectionTable(
      table["command"], name: "mode.command", locations: locations, into: &config)
    {
      applyModeMappingTable(
        sectionTable(
          command["mappings"], name: "mode.command.mappings", locations: locations, into: &config),
        scope: .command,
        path: ["mode", "command", "mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)

      for (key, _) in command where key != "mappings" {
        config.addDiagnostic(
          "mode.command: unknown key '\(key)' — mappings belong under [mode.command.mappings]",
          location: locations.location(for: ["mode", "command", key]))
      }
    }

    applyLayers(
      sectionTable(table["layers"], name: "mode.layers", locations: locations, into: &config),
      locations: locations,
      sourceURL: sourceURL,
      pendingModeMappings: &pendingModeMappings,
      into: &config)

    if let apps = sectionTable(
      table["apps"], name: "mode.apps", locations: locations, into: &config)
    {
      for (bundleID, value) in apps {
        let appPath = ["mode", "apps", bundleID]
        guard isValidBundleID(bundleID) else {
          config.addDiagnostic(
            "mode.apps bundle ID '\(bundleID)' must contain a dot and only letters, digits, dots, or hyphens",
            location: locations.location(for: appPath))
          continue
        }
        guard
          let app = sectionTable(
            value, name: "mode.apps.\(bundleID)", locations: locations, into: &config)
        else { continue }
        for (scopeName, scopeValue) in app {
          let scopePath = appPath + [scopeName]
          guard let scope = ModeScope(rawValue: scopeName) else {
            config.addDiagnostic(
              "mode.apps.\(bundleID): unknown scope '\(scopeName)' — valid scopes are all, normal, insert, command, terminal, hyper, hold, text, visual",
              location: locations.location(for: scopePath))
            continue
          }
          guard
            let scoped = sectionTable(
              scopeValue, name: "mode.apps.\(bundleID).\(scopeName)",
              locations: locations, into: &config)
          else { continue }
          if scope == .text {
            applyBool(
              scoped["enabled"], path: scopePath + ["enabled"],
              message: "mode.apps.\(bundleID).text.enabled must be true or false",
              locations: locations, into: &config,
              assign: { value, config in
                config.mode.appMappings[bundleID, default: .init()].engagesText = value
              })
          }
          let mappingsPath = scopePath + ["mappings"]
          applyModeMappingTable(
            sectionTable(
              scoped["mappings"], name: "mode.apps.\(bundleID).\(scopeName).mappings",
              locations: locations, into: &config),
            scope: scope,
            bundleID: bundleID,
            path: mappingsPath,
            locations: locations,
            sourceURL: sourceURL,
            pendingModeMappings: &pendingModeMappings,
            into: &config)
          let knownKeys: Set<String> = scope == .text ? modeTextKeys : ["mappings"]
          for (key, _) in scoped where !knownKeys.contains(key) {
            config.addDiagnostic(
              "mode.apps.\(bundleID).\(scopeName): unknown key '\(key)' — mappings belong under [mode.apps.\"\(bundleID)\".\(scopeName).mappings]",
              location: locations.location(for: scopePath + [key]))
          }
        }
      }
    }
  }

  /// `[mode.layers.<name>]`: each table declares a layer, with an optional
  /// `label`, `sticky` and its `mappings`. Declaring it is what lets
  /// `mode layer --name=<name>` enter it, so a table with no mappings is
  /// still a layer (one that only Escape and `[mode.all]` act in).
  private static func applyLayers(
    _ table: TOMLTable?,
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    guard let table else { return }
    for (name, value) in table {
      let path = ["mode", "layers", name]
      let dotted = path.joined(separator: ".")
      guard Config.Mode.isValidLayerName(name) else {
        config.addDiagnostic(
          "\(dotted): a layer name is 1–32 characters of a-z, 0-9, _ and -",
          location: locations.location(for: path))
        continue
      }
      guard !Config.Mode.reservedLayerNames.contains(name) else {
        config.addDiagnostic(
          "\(dotted): \(name) is a built-in mode or mapping scope; name the layer otherwise",
          location: locations.location(for: path))
        continue
      }
      guard let layer = sectionTable(value, name: dotted, locations: locations, into: &config)
      else { continue }
      if config.mode.layers[name] == nil { config.mode.layers[name] = .init() }
      applyString(
        layer["label"], path: path + ["label"],
        message: "\(dotted).label must be a string of 1-32 characters", locations: locations,
        into: &config, validate: { (1...32).contains($0.count) },
        assign: { value, config in config.mode.layers[name]?.label = value })
      applyBool(
        layer["sticky"], path: path + ["sticky"],
        message:
          "\(dotted).sticky must be true (stay after a mapping) or false (leave after one)",
        locations: locations, into: &config,
        assign: { value, config in config.mode.layers[name]?.sticky = value })
      applyModeMappingTable(
        sectionTable(
          layer["mappings"], name: "\(dotted).mappings", locations: locations, into: &config),
        scope: .normal,
        layer: name,
        path: path + ["mappings"],
        locations: locations,
        sourceURL: sourceURL,
        pendingModeMappings: &pendingModeMappings,
        into: &config)
      for (key, _) in layer where !layerKeys.contains(key) {
        config.addDiagnostic(
          "\(dotted): unknown key '\(key)' — valid keys are label, sticky and mappings",
          location: locations.location(for: path + [key]))
      }
    }
  }

  private static func applyModeMappingTable(
    _ table: TOMLTable?,
    scope: ModeScope,
    bundleID: String? = nil,
    layer: String? = nil,
    path: [String],
    locations: ConfigSourceLocationIndex,
    sourceURL: URL?,
    pendingModeMappings: inout [PendingModeMapping],
    into config: inout Config
  ) {
    guard let table else { return }
    for (key, value) in table where !key.isEmpty {
      let location = locations.location(for: path + [key])
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        config.addDiagnostic(
          "mapping \"\(key)\" uses invalid syntax — non-letter/number keys must be wrapped in <name>",
          location: location)
        continue
      }
      // `f12` is valid grammar, the keys f, 1, 2, but almost always meant
      // the function key; the spaced-out spelling keeps the sequence.
      if let name = NormalModeInterpreter.bareFunctionKeyName(key) {
        let keys = key.map(String.init)
        config.addDiagnostic(
          "mapping \"\(key)\" is the keys \(keys.joined(separator: ", ")); write \"<\(name)>\" "
            + "for the \(name.uppercased()) key, or \"\(keys.joined(separator: " "))\" for "
            + "those keys in turn",
          location: location)
        continue
      }
      switch parseMappingValue(value, sourceURL: sourceURL) {
      case .success(let parsed):
        pendingModeMappings.append(
          PendingModeMapping(
            scope: scope,
            bundleID: bundleID,
            layer: layer,
            rawKey: key,
            key: canonical,
            value: parsed,
            location: location ?? ConfigLocation(line: 1, column: 1),
            file: sourceURL?.path))
      case .failure(let error):
        config.addDiagnostic(
          error.message(mappingKey: key),
          location: location)
      }
    }
  }
}
