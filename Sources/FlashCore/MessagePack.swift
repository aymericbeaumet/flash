import CoreGraphics
import Foundation
import MessagePack

/// MessagePack codec for the plugin IPC wire.
///
/// Flash speaks length-prefixed MessagePack to its Rust plugins: a 4-byte
/// big-endian payload length followed by a MessagePack value. The Rust side
/// uses `rmp-serde` over `serde_json::Value`; this is the matching Swift end,
/// shimmed over `a2/MessagePack.swift`'s `MessagePackValue` enum. The shim
/// converts to and from a Foundation value tree (`nil`/`NSNull`, `String`,
/// `Data`, `[String: Any]`, `[Any]`, `CGFloat`, any `NSNumber`-bridgeable
/// number, `Bool`) so call sites can keep working with plain Swift values
/// rather than the library's enum.
public enum MessagePackError: Error, CustomStringConvertible {
  /// A Swift value the encoder has no MessagePack mapping for.
  case unsupportedType(String)
  /// A map key that decoded to a non-string (the protocol only uses strings).
  case nonStringKey
  /// The library failed to decode the supplied bytes.
  case decodingFailed(String)

  public var description: String {
    switch self {
    case .unsupportedType(let name): return "messagepack: unsupported type \(name)"
    case .nonStringKey: return "messagepack: non-string map key"
    case .decodingFailed(let message): return "messagepack: \(message)"
    }
  }
}

public enum MessagePack {
  /// Encode a Foundation value tree to a MessagePack payload.
  public static func encode(_ value: Any?) throws -> Data {
    let mpv = try toMessagePackValue(value)
    return pack(mpv)
  }

  /// Decode a single MessagePack value to a Foundation value tree. Maps become
  /// `[String: Any]`, arrays become `[Any]`, and integers narrow to `Int` when
  /// they fit so call sites that pattern-match on `Int` keep working.
  public static func decode(_ data: Data) throws -> Any {
    do {
      let (value, _) = try unpack(data)
      return fromMessagePackValue(value)
    } catch let error as MessagePackError {
      throw error
    } catch {
      throw MessagePackError.decodingFailed(String(describing: error))
    }
  }

  private static func toMessagePackValue(_ value: Any?) throws -> MessagePackValue {
    guard let value, !(value is NSNull) else { return .nil }
    switch value {
    case let string as String:
      return .string(string)
    case let data as Data:
      return .binary(data)
    case let map as [String: Any]:
      var dict: [MessagePackValue: MessagePackValue] = [:]
      dict.reserveCapacity(map.count)
      for (key, child) in map {
        dict[.string(key)] = try toMessagePackValue(child)
      }
      return .map(dict)
    case let array as [Any]:
      return .array(try array.map { try toMessagePackValue($0) })
    case let cgFloat as CGFloat:
      return .double(Double(cgFloat))
    case let number as NSNumber:
      // CFBoolean is a singleton type distinct from NSNumber's integers.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      let marker = UInt8(bitPattern: number.objCType.pointee)
      if marker == UInt8(ascii: "f") || marker == UInt8(ascii: "d") {
        return .double(number.doubleValue)
      }
      let signed = number.int64Value
      if signed >= 0 {
        return .uint(number.uint64Value)
      }
      return .int(signed)
    default:
      throw MessagePackError.unsupportedType(String(describing: type(of: value)))
    }
  }

  private static func fromMessagePackValue(_ value: MessagePackValue) -> Any {
    switch value {
    case .nil:
      return NSNull()
    case .bool(let b):
      return b
    case .int(let i):
      // Narrow to Int when it fits so existing `as? Int` checks keep working.
      if let small = Int(exactly: i) { return small }
      return i
    case .uint(let u):
      if let small = Int(exactly: u) { return small }
      return u
    case .float(let f):
      return Double(f)
    case .double(let d):
      return d
    case .string(let s):
      return s
    case .binary(let data):
      return data
    case .array(let array):
      return array.map { fromMessagePackValue($0) }
    case .map(let dict):
      var out: [String: Any] = [:]
      out.reserveCapacity(dict.count)
      for (key, child) in dict {
        guard case .string(let stringKey) = key else { continue }
        out[stringKey] = fromMessagePackValue(child)
      }
      return out
    case .extended(_, let data):
      return data
    }
  }
}
