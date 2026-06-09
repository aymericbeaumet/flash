import CoreGraphics
import Foundation

/// Minimal MessagePack codec for the plugin IPC wire.
///
/// Flash speaks Length-Prefixed MessagePack to its Rust plugins: a 4-byte
/// big-endian payload length followed by a MessagePack value. The Rust side
/// uses `rmp-serde` over `serde_json::Value`; this is the matching Swift end.
/// It is deliberately scoped to the value shapes that cross the wire —
/// JSON-equivalent trees of `nil`, bool, integer, double, string, array, and
/// string-keyed map — so it stays small and dependency-free (the package ships
/// no third-party code).
///
/// `serde_json::Value` has no bytes variant, so the Rust side never emits a
/// MessagePack `bin`; the encoder's `Data` path and the decoder's `bin` path
/// exist for completeness and round-trip tests, not for traffic.
public enum MessagePackError: Error, CustomStringConvertible {
  /// Ran off the end of the buffer mid-value (a truncated/!framed payload).
  case truncated
  /// A Swift value the encoder has no MessagePack mapping for.
  case unsupportedType(String)
  /// A leading byte that isn't a valid MessagePack format marker.
  case unexpectedByte(UInt8)
  /// A `str`/map-key whose bytes aren't valid UTF-8.
  case invalidUTF8
  /// A map key that decoded to a non-string (the protocol only uses strings).
  case nonStringKey
  /// Nesting deeper than `maxDepth` — a guard against a hostile/corrupt frame.
  case depthLimitExceeded

  public var description: String {
    switch self {
    case .truncated: return "messagepack: truncated payload"
    case .unsupportedType(let name): return "messagepack: unsupported type \(name)"
    case .unexpectedByte(let byte):
      return "messagepack: unexpected format byte 0x\(String(byte, radix: 16))"
    case .invalidUTF8: return "messagepack: invalid UTF-8 in string"
    case .nonStringKey: return "messagepack: non-string map key"
    case .depthLimitExceeded: return "messagepack: nesting too deep"
    }
  }
}

public enum MessagePack {
  /// Hard ceiling on nested container depth, matched on encode and decode.
  private static let maxDepth = 64

  // MARK: Encoding

  /// Encode a Foundation value tree to a MessagePack payload. Accepts the
  /// types the host puts on the wire: `nil`/`NSNull`, `String`, `Data`,
  /// `[String: Any]`, `[Any]`, `CGFloat`, and any `NSNumber`-bridgeable
  /// number or `Bool`.
  public static func encode(_ value: Any?) throws -> Data {
    var out = Data()
    out.reserveCapacity(256)
    try encode(value, into: &out, depth: 0)
    return out
  }

  private static func encode(_ value: Any?, into out: inout Data, depth: Int) throws {
    guard depth <= maxDepth else { throw MessagePackError.depthLimitExceeded }
    guard let value = value, !(value is NSNull) else {
      out.append(0xc0)
      return
    }
    switch value {
    case let string as String:
      encode(string: string, into: &out)
    case let data as Data:
      encode(data: data, into: &out)
    case let map as [String: Any]:
      try encode(map: map, into: &out, depth: depth)
    case let array as [Any]:
      try encode(array: array, into: &out, depth: depth)
    case let cgFloat as CGFloat:
      encode(double: Double(cgFloat), into: &out)
    case let number as NSNumber:
      encode(number: number, into: &out)
    default:
      throw MessagePackError.unsupportedType(String(describing: type(of: value)))
    }
  }

  private static func encode(number: NSNumber, into out: inout Data) {
    // CFBoolean is a distinct singleton type; check it before treating the
    // NSNumber as a coordinate/integer (a bridged Swift `Bool` lands here).
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      out.append(number.boolValue ? 0xc3 : 0xc2)
      return
    }
    let marker = UInt8(bitPattern: number.objCType.pointee)
    if marker == UInt8(ascii: "f") || marker == UInt8(ascii: "d") {
      encode(double: number.doubleValue, into: &out)
      return
    }
    let signed = number.int64Value
    if signed >= 0 {
      encode(uint: number.uint64Value, into: &out)
    } else {
      encode(negativeInt: signed, into: &out)
    }
  }

  private static func encode(uint value: UInt64, into out: inout Data) {
    switch value {
    case 0...0x7f:
      out.append(UInt8(value))
    case 0...0xff:
      out.append(0xcc)
      out.append(UInt8(value))
    case 0...0xffff:
      out.append(0xcd)
      appendBigEndian(UInt16(value), to: &out)
    case 0...0xffff_ffff:
      out.append(0xce)
      appendBigEndian(UInt32(value), to: &out)
    default:
      out.append(0xcf)
      appendBigEndian(value, to: &out)
    }
  }

  private static func encode(negativeInt value: Int64, into out: inout Data) {
    switch value {
    case -32...(-1):
      out.append(UInt8(bitPattern: Int8(value)))
    case -128...(-33):
      out.append(0xd0)
      out.append(UInt8(bitPattern: Int8(value)))
    case -32768...(-129):
      out.append(0xd1)
      appendBigEndian(UInt16(bitPattern: Int16(value)), to: &out)
    case -2_147_483_648...(-32769):
      out.append(0xd2)
      appendBigEndian(UInt32(bitPattern: Int32(value)), to: &out)
    default:
      out.append(0xd3)
      appendBigEndian(UInt64(bitPattern: value), to: &out)
    }
  }

  private static func encode(double value: Double, into out: inout Data) {
    out.append(0xcb)
    appendBigEndian(value.bitPattern, to: &out)
  }

  private static func encode(string: String, into out: inout Data) {
    let bytes = Array(string.utf8)
    let count = bytes.count
    switch count {
    case 0...31:
      out.append(0xa0 | UInt8(count))
    case 0...0xff:
      out.append(0xd9)
      out.append(UInt8(count))
    case 0...0xffff:
      out.append(0xda)
      appendBigEndian(UInt16(count), to: &out)
    default:
      out.append(0xdb)
      appendBigEndian(UInt32(count), to: &out)
    }
    out.append(contentsOf: bytes)
  }

  private static func encode(data: Data, into out: inout Data) {
    let count = data.count
    switch count {
    case 0...0xff:
      out.append(0xc4)
      out.append(UInt8(count))
    case 0...0xffff:
      out.append(0xc5)
      appendBigEndian(UInt16(count), to: &out)
    default:
      out.append(0xc6)
      appendBigEndian(UInt32(count), to: &out)
    }
    out.append(data)
  }

  private static func encode(array: [Any], into out: inout Data, depth: Int) throws {
    let count = array.count
    switch count {
    case 0...15:
      out.append(0x90 | UInt8(count))
    case 0...0xffff:
      out.append(0xdc)
      appendBigEndian(UInt16(count), to: &out)
    default:
      out.append(0xdd)
      appendBigEndian(UInt32(count), to: &out)
    }
    for element in array {
      try encode(element, into: &out, depth: depth + 1)
    }
  }

  private static func encode(map: [String: Any], into out: inout Data, depth: Int) throws {
    let count = map.count
    switch count {
    case 0...15:
      out.append(0x80 | UInt8(count))
    case 0...0xffff:
      out.append(0xde)
      appendBigEndian(UInt16(count), to: &out)
    default:
      out.append(0xdf)
      appendBigEndian(UInt32(count), to: &out)
    }
    for (key, value) in map {
      encode(string: key, into: &out)
      try encode(value, into: &out, depth: depth + 1)
    }
  }

  private static func appendBigEndian(_ value: UInt16, to out: inout Data) {
    out.append(UInt8(truncatingIfNeeded: value >> 8))
    out.append(UInt8(truncatingIfNeeded: value))
  }

  private static func appendBigEndian(_ value: UInt32, to out: inout Data) {
    out.append(UInt8(truncatingIfNeeded: value >> 24))
    out.append(UInt8(truncatingIfNeeded: value >> 16))
    out.append(UInt8(truncatingIfNeeded: value >> 8))
    out.append(UInt8(truncatingIfNeeded: value))
  }

  private static func appendBigEndian(_ value: UInt64, to out: inout Data) {
    var shift: UInt64 = 56
    while true {
      out.append(UInt8(truncatingIfNeeded: value >> shift))
      if shift == 0 { break }
      shift -= 8
    }
  }

  // MARK: Decoding

  /// Decode a single MessagePack value from `data`. Maps become
  /// `[String: Any]`, arrays `[Any]`, integers `Int` (or `UInt64` when they
  /// overflow `Int`), floats `Double`, nil `NSNull` — shapes the host routes
  /// with the same `as?` casts it used for `JSONSerialization` output.
  public static func decode(_ data: Data) throws -> Any {
    var reader = Reader(bytes: [UInt8](data))
    return try reader.readValue(depth: 0)
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0

    mutating func readByte() throws -> UInt8 {
      guard index < bytes.count else { throw MessagePackError.truncated }
      defer { index += 1 }
      return bytes[index]
    }

    mutating func readUInt(_ width: Int) throws -> UInt64 {
      guard index + width <= bytes.count else { throw MessagePackError.truncated }
      var value: UInt64 = 0
      for _ in 0..<width {
        value = (value << 8) | UInt64(bytes[index])
        index += 1
      }
      return value
    }

    mutating func readSlice(_ count: Int) throws -> ArraySlice<UInt8> {
      guard count >= 0, index + count <= bytes.count else { throw MessagePackError.truncated }
      defer { index += count }
      return bytes[index..<(index + count)]
    }

    mutating func readString(count: Int) throws -> String {
      let slice = try readSlice(count)
      guard let string = String(bytes: slice, encoding: .utf8) else {
        throw MessagePackError.invalidUTF8
      }
      return string
    }

    mutating func readData(count: Int) throws -> Data {
      Data(try readSlice(count))
    }

    mutating func readArray(count: Int, depth: Int) throws -> [Any] {
      var array = [Any]()
      array.reserveCapacity(min(count, 1024))
      for _ in 0..<count {
        array.append(try readValue(depth: depth + 1))
      }
      return array
    }

    mutating func readMap(count: Int, depth: Int) throws -> [String: Any] {
      var map = [String: Any](minimumCapacity: count)
      for _ in 0..<count {
        guard let key = try readValue(depth: depth + 1) as? String else {
          throw MessagePackError.nonStringKey
        }
        map[key] = try readValue(depth: depth + 1)
      }
      return map
    }

    mutating func readValue(depth: Int) throws -> Any {
      guard depth <= maxDepth else { throw MessagePackError.depthLimitExceeded }
      let byte = try readByte()
      switch byte {
      case 0x00...0x7f:
        return Int(byte)
      case 0xe0...0xff:
        return Int(Int8(bitPattern: byte))
      case 0x80...0x8f:
        return try readMap(count: Int(byte & 0x0f), depth: depth)
      case 0x90...0x9f:
        return try readArray(count: Int(byte & 0x0f), depth: depth)
      case 0xa0...0xbf:
        return try readString(count: Int(byte & 0x1f))
      case 0xc0:
        return NSNull()
      case 0xc2:
        return false
      case 0xc3:
        return true
      case 0xc4:
        return try readData(count: Int(try readByte()))
      case 0xc5:
        return try readData(count: Int(try readUInt(2)))
      case 0xc6:
        return try readData(count: Int(try readUInt(4)))
      case 0xca:
        return Double(Float(bitPattern: UInt32(try readUInt(4))))
      case 0xcb:
        return Double(bitPattern: try readUInt(8))
      case 0xcc:
        return Int(try readByte())
      case 0xcd:
        return Int(try readUInt(2))
      case 0xce:
        return Int(try readUInt(4))
      case 0xcf:
        let value = try readUInt(8)
        return value <= UInt64(Int.max) ? Int(value) : value
      case 0xd0:
        return Int(Int8(bitPattern: try readByte()))
      case 0xd1:
        return Int(Int16(bitPattern: UInt16(try readUInt(2))))
      case 0xd2:
        return Int(Int32(bitPattern: UInt32(try readUInt(4))))
      case 0xd3:
        return Int(Int64(bitPattern: try readUInt(8)))
      case 0xd9:
        return try readString(count: Int(try readByte()))
      case 0xda:
        return try readString(count: Int(try readUInt(2)))
      case 0xdb:
        return try readString(count: Int(try readUInt(4)))
      case 0xdc:
        return try readArray(count: Int(try readUInt(2)), depth: depth)
      case 0xdd:
        return try readArray(count: Int(try readUInt(4)), depth: depth)
      case 0xde:
        return try readMap(count: Int(try readUInt(2)), depth: depth)
      case 0xdf:
        return try readMap(count: Int(try readUInt(4)), depth: depth)
      default:
        throw MessagePackError.unexpectedByte(byte)
      }
    }
  }
}
