import FlashCore
import Foundation
import TOMLKit

/// Typed readers shared by every section: one TOML value, validated, into a field.
extension ConfigLoader {
  /// A hint / bounds color is `#`-optional 6- or 8-digit hex (`RRGGBB` or
  /// `RRGGBBAA`), matching `OverlayPanel.nsColor(fromHex:)`. Empty is allowed
  /// (renders as no color). Anything else is a typo and is rejected loudly
  /// rather than silently falling back to a default at draw time.
  static func isValidHexColor(_ raw: String) -> Bool {
    var s = raw.trimmingCharacters(in: .whitespaces)
    // Empty is NOT a color. Keys where empty means "use the default"
    // (window_border_color) opt in explicitly at their call site.
    if s.isEmpty { return false }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8 else { return false }
    return s.allSatisfy(\.isHexDigit)
  }

  static func applyString(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (String) -> Bool = { _ in true },
    assign: (String, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = value.string, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  /// A `#RRGGBB` or `#RRGGBBAA` color key, rejected with the one message
  /// every color key shares.
  static func applyHexColor(
    _ table: TOMLTable, _ path: [String], locations: ConfigSourceLocationIndex,
    into config: inout Config, _ keyPath: WritableKeyPath<Config, String>
  ) {
    applyString(
      table[path[path.count - 1]], path: path,
      message: "\(path.joined(separator: ".")) must be a hex color like #RRGGBB or #RRGGBBAA",
      locations: locations, into: &config, validate: { isValidHexColor($0) },
      assign: { value, config in config[keyPath: keyPath] = value })
  }

  static func applyStringArray(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: ([String]) -> Bool = { _ in true },
    assign: ([String], inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = stringArrayValue(value), validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  static func applyBool(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    assign: (Bool, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    guard let parsed = value.bool else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  static func applyInt(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (Int) -> Bool = { _ in true },
    assign: (Int, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    // Accept exactly-integral doubles (`interval = 5.0`) — rejecting them
    // while `applyDouble` accepts ints would be a gratuitous asymmetry.
    let parsed = value.int ?? value.double.flatMap { Int(exactly: $0) }
    guard let parsed, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  static func applyDouble(
    _ value: (any TOMLValueConvertible)?,
    path: [String],
    message: String,
    locations: ConfigSourceLocationIndex,
    into config: inout Config,
    validate: (Double) -> Bool = { _ in true },
    assign: (Double, inout Config) -> Void
  ) {
    guard let value else { return }
    let location = locations.location(for: path)
    let parsed = value.double ?? value.int.map(Double.init)
    guard let parsed, validate(parsed) else {
      config.addDiagnostic(message, location: location)
      return
    }
    assign(parsed, &config)
    config.recordLocation(path: path.joined(separator: "."), location: location)
  }

  static func stringArrayValue(_ value: any TOMLValueConvertible) -> [String]? {
    guard let array = value.array else { return nil }
    var result: [String] = []
    for item in array {
      guard let string = item.string else { return nil }
      result.append(string)
    }
    return result
  }

  static func stringTableValue(_ value: any TOMLValueConvertible) -> [String: String]? {
    guard let table = value.table else { return nil }
    var result: [String: String] = [:]
    for (key, value) in table {
      guard let string = value.string else { return nil }
      result[key] = string
    }
    return result
  }

  static func pluginConfigValue(_ value: any TOMLValueConvertible) -> PluginConfigValue? {
    if let bool = value.bool { return .bool(bool) }
    if let int = value.int { return .int(int) }
    if let double = value.double { return .double(double) }
    if let array = stringArrayValue(value) { return .stringArray(array) }
    if let string = value.string { return .string(string) }
    return nil
  }
}
