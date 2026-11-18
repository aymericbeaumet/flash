import FlashCore
import Foundation
import TOMLKit

/// `[tiling]` and `[[window_rules]]`.
extension ConfigLoader {
  /// `[tiling]`, `[tiling.gaps]`, `[tiling.monitors]` and `[[tiling.rules]]`.
  static func applyTiling(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    guard let table else { return }
    applyBool(
      table["enabled"], path: ["tiling", "enabled"],
      message: "tiling.enabled must be true or false", locations: locations, into: &config
    ) { value, config in config.tiling.enabled = value }
    applyBool(
      table["persist"], path: ["tiling", "persist"],
      message: "tiling.persist must be true or false", locations: locations, into: &config
    ) { value, config in config.tiling.persist = value }
    applyString(
      table["layout"], path: ["tiling", "layout"],
      message: "tiling.layout must be \"tiles\" or \"accordion\"", locations: locations,
      into: &config, validate: { TilingLayoutKind(rawValue: $0) != nil },
      assign: { value, config in config.tiling.layout = TilingLayoutKind(rawValue: value)! })
    applyString(
      table["orientation"], path: ["tiling", "orientation"],
      message: "tiling.orientation must be \"auto\", \"horizontal\" or \"vertical\"",
      locations: locations, into: &config,
      validate: { $0 == "auto" || TilingOrientation(rawValue: $0) != nil },
      assign: { value, config in config.tiling.orientation = TilingOrientation(rawValue: value) })
    let padding = TilingSettings.accordionPaddingRange
    applyInt(
      table["accordion_padding"], path: ["tiling", "accordion_padding"],
      message:
        "tiling.accordion_padding must be an integer between \(padding.lowerBound) and \(padding.upperBound) (points)",
      locations: locations, into: &config, validate: { padding.contains($0) },
      assign: { value, config in config.tiling.accordionPadding = CGFloat(value) })
    applyStringArray(
      table["workspaces"], path: ["tiling", "workspaces"],
      message: "tiling.workspaces must be an array of workspace names", locations: locations,
      into: &config
    ) { value, config in
      let invalid = value.filter { !TilingSettings.isValidWorkspaceName($0) }
      guard invalid.isEmpty, Set(value).count == value.count else {
        config.addDiagnostic(
          "tiling.workspaces names must be unique words without spaces, at most 32 characters",
          location: locations.location(for: ["tiling", "workspaces"]))
        return
      }
      config.tiling.workspaces = value
    }
    if let value = table["gaps"] {
      if let gaps = value.table {
        let keys = [
          "inner", "inner_horizontal", "inner_vertical", "outer", "outer_left", "outer_right",
          "outer_top", "outer_bottom",
        ]
        for key in gaps.keys where !keys.contains(key) {
          config.addDiagnostic(
            "tiling.gaps: unknown key '\(key)'; known keys: \(keys.joined(separator: ", "))",
            location: locations.location(for: ["tiling", "gaps", key]))
        }
        var values: [String: CGFloat] = [:]
        let range = TilingSettings.gapRange
        for key in keys {
          applyInt(
            gaps[key], path: ["tiling", "gaps", key],
            message:
              "tiling.gaps.\(key) must be an integer between \(range.lowerBound) and \(range.upperBound) (points)",
            locations: locations, into: &config, validate: { range.contains($0) },
            assign: { value, _ in values[key] = CGFloat(value) })
        }
        // A side's own value wins over its group's.
        func side(_ key: String, _ group: String) -> CGFloat { values[key] ?? values[group] ?? 0 }
        config.tiling.gaps = TilingGaps(
          innerHorizontal: side("inner_horizontal", "inner"),
          innerVertical: side("inner_vertical", "inner"),
          outerLeft: side("outer_left", "outer"), outerRight: side("outer_right", "outer"),
          outerTop: side("outer_top", "outer"), outerBottom: side("outer_bottom", "outer"))
      } else {
        config.addDiagnostic(
          "tiling.gaps must be a table ([tiling.gaps])",
          location: locations.location(for: ["tiling", "gaps"]))
      }
    }
    if let value = table["monitors"] {
      if let monitors = value.table {
        var pinned: [String: TilingMonitorPattern] = [:]
        for (name, raw) in monitors {
          guard TilingSettings.isValidWorkspaceName(name),
            let text = raw.string ?? raw.int.map(String.init),
            let pattern = TilingMonitorPattern(text)
          else {
            config.addDiagnostic(
              "tiling.monitors.\(name) must be \"main\", \"secondary\" or a display number "
                + "from 1, counted left to right",
              location: locations.location(for: ["tiling", "monitors", name]))
            continue
          }
          pinned[name] = pattern
        }
        config.tiling.pinned = pinned
      } else {
        config.addDiagnostic(
          "tiling.monitors must be a table of workspace = display ([tiling.monitors])",
          location: locations.location(for: ["tiling", "monitors"]))
      }
    }
    if let value = table["rules"] {
      guard let rules = value.array else {
        config.addDiagnostic(
          "tiling.rules must be an array of tables ([[tiling.rules]])",
          location: locations.location(for: ["tiling", "rules"]))
        return
      }
      let known: Set<String> = ["bundle_id", "title_contains", "float", "workspace"]
      var parsed: [TilingRule] = []
      for (index, value) in rules.enumerated() {
        let path = ["tiling", "rules", String(index)]
        guard let rule = value.table else {
          config.addDiagnostic(
            "tiling.rules[\(index)] must be a table", location: locations.location(for: path))
          continue
        }
        for key in rule.keys where !known.contains(key) {
          config.addDiagnostic(
            "tiling.rules[\(index)]: unknown key '\(key)'; known keys: bundle_id, "
              + "title_contains, float, workspace",
            location: locations.location(for: path + [key]))
        }
        guard let bundleID = rule["bundle_id"]?.string, isValidBundleID(bundleID) else {
          config.addDiagnostic(
            "tiling.rules[\(index)].bundle_id must be an exact bundle ID",
            location: locations.location(for: path + ["bundle_id"])
              ?? locations.location(for: path))
          continue
        }
        var entry = TilingRule(bundleID: bundleID)
        if let title = rule["title_contains"] {
          guard let text = title.string, !text.isEmpty else {
            config.addDiagnostic(
              "tiling.rules[\(index)].title_contains must be a non-empty string",
              location: locations.location(for: path + ["title_contains"]))
            continue
          }
          entry.titleContains = text
        }
        if let floats = rule["float"] {
          guard let flag = floats.bool else {
            config.addDiagnostic(
              "tiling.rules[\(index)].float must be true or false",
              location: locations.location(for: path + ["float"]))
            continue
          }
          entry.floats = flag
        }
        if let workspace = rule["workspace"] {
          guard let name = workspace.string ?? workspace.int.map(String.init),
            TilingSettings.isValidWorkspaceName(name)
          else {
            config.addDiagnostic(
              "tiling.rules[\(index)].workspace must be a workspace name without spaces",
              location: locations.location(for: path + ["workspace"]))
            continue
          }
          entry.workspace = name
        }
        guard entry.floats != nil || entry.workspace != nil else {
          config.addDiagnostic(
            "tiling.rules[\(index)] needs float or workspace",
            location: locations.location(for: path))
          continue
        }
        parsed.append(entry)
      }
      config.tiling.rules = parsed
    }
  }

  /// A bundle identifier as LaunchServices spells one: at least two
  /// dot-separated, non-empty runs of ASCII letters, digits and hyphens.
  static func isValidBundleID(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
    return value.unicodeScalars.allSatisfy { $0 == "." || allowed.contains($0) }
  }

  static func applyWindowRules(
    _ value: (any TOMLValueConvertible)?,
    locations: ConfigSourceLocationIndex,
    into config: inout Config
  ) {
    guard let value else { return }
    guard let rules = value.array else {
      config.addDiagnostic(
        "window_rules must be an array of tables ([[window_rules]])",
        location: locations.location(for: ["window_rules"]))
      return
    }
    let known = windowRuleKeys
    for (index, value) in rules.enumerated() {
      let path = ["window_rules", String(index)]
      guard let rule = value.table else {
        config.addDiagnostic(
          "window_rules[\(index)] must be a table",
          location: locations.location(for: path))
        continue
      }
      for (key, _) in rule where !known.contains(key) {
        config.addDiagnostic(
          "window_rules[\(index)]: unknown key '\(key)'",
          location: locations.location(for: path + [key]))
      }
      guard let bundleID = rule["bundle_id"]?.string, isValidBundleID(bundleID) else {
        config.addDiagnostic(
          "window_rules[\(index)].bundle_id must be an exact bundle ID",
          location: locations.location(for: path + ["bundle_id"])
            ?? locations.location(for: path))
        continue
      }
      let titleContains: String?
      if let value = rule["title_contains"] {
        guard let title = value.string, !title.isEmpty else {
          config.addDiagnostic(
            "window_rules[\(index)].title_contains must be a non-empty string",
            location: locations.location(for: path + ["title_contains"]))
          continue
        }
        titleContains = title
      } else {
        titleContains = nil
      }
      let screen: Int
      if let value = rule["screen"] {
        guard let parsed = value.int else {
          config.addDiagnostic(
            "window_rules[\(index)].screen must be a relative integer",
            location: locations.location(for: path + ["screen"]))
          continue
        }
        screen = parsed
      } else {
        screen = 0
      }
      let frameNames = ["x", "y", "width", "height"]
      let hasFrame = frameNames.contains { rule[$0] != nil }
      let layout: WindowLayout
      if let position = rule["position"] {
        guard !hasFrame, let raw = position.string,
          let parsed = WindowPosition(rawValue: raw.lowercased())
        else {
          config.addDiagnostic(
            "window_rules[\(index)].position must be a named window position and cannot be combined with percentages",
            location: locations.location(for: path + ["position"]))
          continue
        }
        layout = .position(parsed)
      } else {
        guard hasFrame else {
          config.addDiagnostic(
            "window_rules[\(index)] requires position or x, y, width, and height",
            location: locations.location(for: path))
          continue
        }
        let percentages = frameNames.map { name -> Double? in
          guard let value = rule[name] else { return nil }
          return value.double ?? value.int.map(Double.init)
        }
        guard percentages.allSatisfy({ $0 != nil }),
          let x = percentages[0], let y = percentages[1],
          let width = percentages[2], let height = percentages[3],
          [x, y, width, height].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
          width > 0, height > 0, x + width <= 100, y + height <= 100
        else {
          config.addDiagnostic(
            "window_rules[\(index)] requires valid x, y, width, and height percentages within the screen",
            location: locations.location(for: path))
          continue
        }
        layout = .proportional(
          ProportionalWindowFrame(
            xPercent: x, yPercent: y, widthPercent: width, heightPercent: height))
      }
      config.windowRules.append(
        WindowPlacementRule(
          bundleID: bundleID, titleContains: titleContains,
          move: MoveWindowParams(layout: layout, screen: screen)))
    }
  }
}
