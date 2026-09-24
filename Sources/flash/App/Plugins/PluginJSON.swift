import Darwin
import Foundation

/// JSONSerialization bridges booleans and numbers through NSNumber. Keep
/// their wire types distinct before any narrowing or native API dispatch.
enum PluginJSON {
  static func boolean(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID()
    else { return nil }
    return value.boolValue
  }

  static func integer(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType))
    else { return nil }
    return Int(value.stringValue)
  }

  static func pid(_ value: Any?) -> pid_t? {
    guard let value = integer(value), value > 0 else { return nil }
    return pid_t(exactly: value)
  }

  static func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
    else { return nil }
    return value.doubleValue
  }

  static func present(_ value: Any?) -> Any? {
    value is NSNull ? nil : value
  }

  static func encodedBytes(_ value: Any) -> Int? {
    (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]))?.count
  }
}
