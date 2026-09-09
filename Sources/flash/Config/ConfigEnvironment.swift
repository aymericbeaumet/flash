import Foundation
import TOMLKit

extension ConfigLoader {
  /// Environment values become the final TOML layers, so all entry points use
  /// the same field validation before deriving the runtime configuration.
  static func environmentLayers(_ environment: [String: String]) -> [Layer] {
    environmentFields.compactMap { field in
      let name = "FLASH_" + field.path.replacingOccurrences(of: ".", with: "_").uppercased()
      guard let value = environment[name] else { return nil }
      return Layer(text: "\(field.path) = \(field.literal(value))", diagnosticLabel: name)
    }
  }

  private struct EnvironmentField {
    enum Kind { case string, integer, number, boolean, strings }
    let path: String
    let kind: Kind

    init(_ path: String, _ kind: Kind) {
      self.path = path
      self.kind = kind
    }

    func literal(_ raw: String) -> String {
      let value: Any
      switch kind {
      case .string: value = raw
      case .integer: value = Int(raw).map { $0 as Any } ?? raw
      case .number:
        value = Double(raw).flatMap { $0.isFinite ? $0 as Any : nil } ?? raw
      case .boolean:
        value = raw == "true" ? true : raw == "false" ? false : raw as Any
      case .strings:
        if let table = try? TOMLTable(string: "value = \(raw)"), table.keys.count == 1,
          let array = table["value"]?.array, array.allSatisfy({ $0.string != nil })
        {
          value = array.compactMap(\.string)
        } else {
          value = raw
        }
      }
      // JSON strings and arrays use the TOML basic-string escape vocabulary.
      // Slash escaping must stay off because TOML deliberately rejects \/.
      let data = try! JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
      return String(decoding: data, as: UTF8.self)
    }
  }

  private static let environmentFields: [EnvironmentField] = [
    .init("hints.keys", .string),
    .init("hints.min_length", .integer),
    .init("hints.magic_modifiers", .strings),
    .init("open.ignored_apps", .strings),
    .init("overlay.font_size", .number),
    .init("overlay.hint_fg", .string),
    .init("overlay.hint_bg_top", .string),
    .init("overlay.hint_bg_bottom", .string),
    .init("overlay.hint_border", .string),
    .init("overlay.important_hint_fg", .string),
    .init("overlay.important_hint_bg_top", .string),
    .init("overlay.important_hint_bg_bottom", .string),
    .init("overlay.important_hint_border", .string),
    .init("flashlight.suggestion_count", .integer),
    .init("debug.show_hints_bounds", .boolean),
    .init("debug.hints_bounds_bg", .string),
    .init("debug.hints_bounds_fg", .string),
    .init("debug.log_level", .string),
  ]
}
