// Minimal Flash plugin protocol shim for Swift (Foundation only).
//
// Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
// MessagePack over stdio (4-byte big-endian length + one value) and the
// protocol v3 lifecycle, including the warm-catalog side (publish before
// ready, answer `sources.snapshot` from memory). Lifecycle and warm reads
// answer synchronously on the read thread; commands, resolution, and
// events run on a worker queue so a slow AppleScript can never starve the
// host's 5-second heartbeat — the same discipline the Rust SDK enforces.

import Foundation

let protocolVersion = 3

// MARK: - MessagePack (the subset the protocol needs)

enum MsgPack {
  static func encode(_ value: Any?) -> Data {
    var out = Data()
    encodeInto(value, &out)
    return out
  }

  private static func encodeInto(_ value: Any?, _ out: inout Data) {
    switch value {
    case nil, is NSNull:
      out.append(0xC0)
    case let bool as Bool:
      out.append(bool ? 0xC3 : 0xC2)
    case let int as Int:
      if int >= 0 && int <= 127 {
        out.append(UInt8(int))
      } else if int < 0 && int >= -32 {
        out.append(UInt8(bitPattern: Int8(int)))
      } else {
        out.append(0xD3)
        appendBigEndian(UInt64(bitPattern: Int64(int)), &out)
      }
    case let string as String:
      let raw = Data(string.utf8)
      if raw.count < 32 {
        out.append(0xA0 | UInt8(raw.count))
      } else {
        out.append(0xDB)
        appendBigEndian(UInt32(raw.count), &out)
      }
      out.append(raw)
    case let array as [Any?]:
      if array.count < 16 {
        out.append(0x90 | UInt8(array.count))
      } else {
        out.append(0xDC)
        appendBigEndian(UInt16(array.count), &out)
      }
      for element in array { encodeInto(element, &out) }
    case let map as [String: Any?]:
      if map.count < 16 {
        out.append(0x80 | UInt8(map.count))
      } else {
        out.append(0xDE)
        appendBigEndian(UInt16(map.count), &out)
      }
      for (key, element) in map {
        encodeInto(key, &out)
        encodeInto(element, &out)
      }
    default:
      fatalError("unencodable value: \(type(of: value))")
    }
  }

  private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, _ out: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
  }

  static func decode(_ data: Data) -> Any? {
    var position = data.startIndex
    return decodeValue(data, &position)
  }

  private static func decodeValue(_ data: Data, _ position: inout Data.Index) -> Any? {
    let byte = data[position]
    position += 1
    switch byte {
    case 0xC0: return nil
    case 0xC2: return false
    case 0xC3: return true
    case 0x00...0x7F: return Int(byte)
    case 0xE0...0xFF: return Int(Int8(bitPattern: byte))
    case 0xA0...0xBF: return decodeString(data, &position, count: Int(byte & 0x1F))
    case 0xD9: return decodeString(data, &position, count: readInt(data, &position, width: 1))
    case 0xDA: return decodeString(data, &position, count: readInt(data, &position, width: 2))
    case 0xDB: return decodeString(data, &position, count: readInt(data, &position, width: 4))
    case 0x80...0x8F: return decodeMap(data, &position, count: Int(byte & 0x0F))
    case 0xDE: return decodeMap(data, &position, count: readInt(data, &position, width: 2))
    case 0xDF: return decodeMap(data, &position, count: readInt(data, &position, width: 4))
    case 0x90...0x9F: return decodeArray(data, &position, count: Int(byte & 0x0F))
    case 0xDC: return decodeArray(data, &position, count: readInt(data, &position, width: 2))
    case 0xDD: return decodeArray(data, &position, count: readInt(data, &position, width: 4))
    case 0xCC: return readInt(data, &position, width: 1)
    case 0xCD: return readInt(data, &position, width: 2)
    case 0xCE: return readInt(data, &position, width: 4)
    case 0xCF, 0xD3: return readInt(data, &position, width: 8)
    case 0xD0: return Int(Int8(bitPattern: UInt8(readInt(data, &position, width: 1))))
    case 0xD1: return Int(Int16(bitPattern: UInt16(readInt(data, &position, width: 2))))
    case 0xD2: return Int(Int32(bitPattern: UInt32(readInt(data, &position, width: 4))))
    case 0xCA:
      let bits = UInt32(readInt(data, &position, width: 4))
      return Double(Float(bitPattern: bits))
    case 0xCB:
      // readInt yields the raw bit pattern as a (possibly negative) Int;
      // converting through UInt64(_:) traps on any double with the sign bit
      // set — e.g. a window origin left of the primary display.
      let bits = UInt64(bitPattern: Int64(readInt(data, &position, width: 8)))
      return Double(bitPattern: bits)
    default:
      return nil
    }
  }

  private static func readInt(_ data: Data, _ position: inout Data.Index, width: Int) -> Int {
    var value = 0
    for _ in 0..<width {
      value = value << 8 | Int(data[position])
      position += 1
    }
    return value
  }

  private static func decodeString(_ data: Data, _ position: inout Data.Index, count: Int)
    -> String
  {
    let end = position + count
    let string = String(data: data[position..<end], encoding: .utf8) ?? ""
    position = end
    return string
  }

  private static func decodeMap(_ data: Data, _ position: inout Data.Index, count: Int)
    -> [String: Any?]
  {
    var out: [String: Any?] = [:]
    for _ in 0..<count {
      let key = decodeValue(data, &position) as? String ?? ""
      out[key] = decodeValue(data, &position)
    }
    return out
  }

  private static func decodeArray(_ data: Data, _ position: inout Data.Index, count: Int)
    -> [Any?]
  {
    var out: [Any?] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
      out.append(decodeValue(data, &position))
    }
    return out
  }
}

// MARK: - Runtime

final class PluginRuntime {
  private let output = FileHandle.standardOutput
  private let input = FileHandle.standardInput
  private let writeLock = NSLock()
  private let warmLock = NSLock()
  private var warm: [String: [[String: Any?]]] = [:]
  private let workers = DispatchQueue(label: "plugin.workers", attributes: .concurrent)

  /// Runs once when initialize arrives, BEFORE the reply — publish the warm
  /// catalog here so `published_sources` satisfies the readiness gate.
  var onStart: (() -> Void)?
  var onEvent: ((_ name: String, _ payload: [String: Any?]) -> Void)?
  var onCommand: ((_ params: [String: Any?]) -> [String: Any?])?
  var onResolve: ((_ params: [String: Any?]) -> [String: Any?])?

  func setLocations(_ sourceID: String, _ candidates: [[String: Any?]]) {
    warmLock.lock()
    warm[sourceID] = candidates
    warmLock.unlock()
  }

  func hasLocations(_ sourceID: String) -> Bool {
    warmLock.lock()
    defer { warmLock.unlock() }
    return warm[sourceID] != nil
  }

  func log(_ level: String, _ message: String, fields: [String: String] = [:]) {
    send([
      "jsonrpc": "2.0",
      "method": "flash.log",
      "params": ["level": level, "message": message, "fields": fields] as [String: Any?],
    ])
  }

  private func send(_ object: [String: Any?]) {
    let payload = MsgPack.encode(object)
    var frame = Data()
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
    frame.append(payload)
    writeLock.lock()
    output.write(frame)
    writeLock.unlock()
  }

  private func respond(_ id: Any?, _ result: [String: Any?]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func serve() {
    var buffer = Data()
    while true {
      let chunk = input.availableData
      if chunk.isEmpty { return }  // host closed stdin
      buffer.append(chunk)
      while buffer.count >= 4 {
        let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard buffer.count >= 4 + length else { break }
        let payload = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
        buffer.removeFirst(4 + length)
        guard let message = MsgPack.decode(payload) as? [String: Any?] else { continue }
        if !dispatch(message) { return }
      }
    }
  }

  private func dispatch(_ message: [String: Any?]) -> Bool {
    let method = message["method"] as? String
    let id = message["id"] ?? nil
    let params = message["params"] as? [String: Any?] ?? [:]
    switch method {
    case "initialize":
      guard params["protocol_version"] as? Int == protocolVersion else {
        respond(id, ["ok": false, "error": "protocol version mismatch"])
        return false
      }
      onStart?()
      warmLock.lock()
      let published = warm.keys.sorted()
      warmLock.unlock()
      respond(
        id,
        [
          "ok": true, "protocol_version": protocolVersion,
          "published_sources": published as [Any?],
        ])
      return true
    case "heartbeat":
      respond(id, ["ok": true])
      return true
    case "shutdown":
      respond(id, ["ok": true])
      return false
    case "sources.snapshot":
      warmLock.lock()
      let candidates = warm.sorted { $0.key < $1.key }.flatMap(\.value)
      warmLock.unlock()
      respond(id, ["candidates": candidates as [Any?]])
      return true
    case "command.invoke":
      workers.async { [self] in respond(id, onCommand?(params) ?? ["ok": false]) }
      return true
    case "candidate.resolve":
      workers.async { [self] in respond(id, onResolve?(params) ?? ["did_resolve": false]) }
      return true
    case "event":
      let name = params["name"] as? String ?? ""
      let payload = params["payload"] as? [String: Any?] ?? [:]
      workers.async { [self] in onEvent?(name, payload) }
      return true
    default:
      if !(id is NSNull) && id != nil {
        respond(id, ["ok": false, "error": "unsupported method \(method ?? "?")"])
      }
      return true
    }
  }
}

// MARK: - Subprocess helper

struct CommandResult {
  var ok: Bool
  var stdout: String
  var stderr: String
}

/// Bounded subprocess capture: hard timeout terminates the child, mirroring
/// the Rust SDK's run_command discipline (without the process-group kill —
/// osascript/open spawn no descendants worth chasing).
func runCommand(_ argv: [String], timeoutSeconds: Double) -> CommandResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  let out = Pipe()
  let err = Pipe()
  process.standardOutput = out
  process.standardError = err
  process.standardInput = FileHandle.nullDevice
  do {
    try process.run()
  } catch {
    return CommandResult(ok: false, stdout: "", stderr: "\(error)")
  }
  let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
  DispatchQueue.global(qos: .utility).asyncAfter(
    deadline: .now() + timeoutSeconds, execute: killer)
  let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
  let stderrData = err.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  killer.cancel()
  return CommandResult(
    ok: process.terminationStatus == 0,
    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
    stderr: String(data: stderrData, encoding: .utf8) ?? "")
}

func runOsascript(_ script: String, timeoutSeconds: Double) -> CommandResult {
  runCommand(["/usr/bin/osascript", "-e", script], timeoutSeconds: timeoutSeconds)
}

func applescriptQuote(_ value: String) -> String {
  "\""
    + value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    + "\""
}
