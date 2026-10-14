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

  /// Objective-C type codes of the integer `NSNumber` encodings.
  private static let integerTypeCodes: Set<CChar> = Set("csilqCSILQ".utf8.map { CChar($0) })
  private static let unsignedLongLongTypeCode = CChar(UInt8(ascii: "Q"))

  static func integer(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID()
    else { return nil }
    let type = value.objCType.pointee
    guard integerTypeCodes.contains(type) else { return nil }
    if type == unsignedLongLongTypeCode {
      let unsigned = value.uint64Value
      return unsigned <= UInt64(Int.max) ? Int(unsigned) : nil
    }
    return Int(exactly: value.int64Value)
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
