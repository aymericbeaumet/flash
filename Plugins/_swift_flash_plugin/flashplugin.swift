// Shared Flash plugin SDK for Swift (Foundation only) — no Flash business
// concepts, mirroring the Rust `flash_plugin` crate's role for Swift
// plugins. Scripts/build-plugins.sh compiles this file alongside each Swift
// plugin's main.swift.
//
// Speaks the wire contract from docs/plugin-protocol.md: protocol v1, one
// JSON object per newline-terminated line over stdio. Three frame shapes
// and nothing else: id+method = request, id only = response, method only =
// notification. Host and plugin id counters are independent and may
// overlap — replies to our own `callHost` requests are correlated through
// our pending map, so any id+method frame from stdin is a host request.
// Lifecycle and warm reads answer synchronously on the read thread;
// commands, resolution, and events run on a worker queue so a slow
// AppleScript can never starve the host's 5-second heartbeat — the same
// discipline the Rust SDK enforces.

import Foundation

let protocolVersion = 1

// MARK: - JSON plumbing

/// JSONSerialization rejects Swift optionals; unwrap recursively
/// (nil → NSNull) so `[String: Any?]` payloads serialize.
private func jsonSafe(_ value: Any?) -> Any {
  guard let value else { return NSNull() }
  if let map = value as? [String: Any?] { return map.mapValues(jsonSafe) }
  if let array = value as? [Any?] { return array.map(jsonSafe) }
  return value
}

/// Plugin configuration from the FLASH_PLUGIN_CONFIG env var, parsed once
/// (JSON object; empty when unset or invalid).
private let parsedConfig: [String: Any] = {
  guard let raw = ProcessInfo.processInfo.environment["FLASH_PLUGIN_CONFIG"],
    let data = raw.data(using: .utf8),
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else { return [:] }
  return object
}()

func config() -> [String: Any] { parsedConfig }

// MARK: - Runtime

final class PluginRuntime {
  private let output = FileHandle.standardOutput
  private let input = FileHandle.standardInput
  private let writeLock = NSLock()
  private let warmLock = NSLock()
  private var warm: [String: [[String: Any?]]] = [:]
  private let workers = DispatchQueue(label: "plugin.workers", attributes: .concurrent)
  private let pendingLock = NSLock()
  private var pending: [Int: ([String: Any?]) -> Void] = [:]
  private var nextRequestID = 1

  /// Runs once when initialize arrives, BEFORE the reply — load the warm
  /// store here so the host never sees a ready plugin with a cold catalog.
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
      "method": "flash.log",
      "params": ["level": level, "message": message, "fields": fields] as [String: Any?],
    ])
  }

  /// Plugin→host request on our own id counter; the completion runs on the
  /// worker queue when the matching response frame arrives.
  func callHost(
    method: String, params: [String: Any?] = [:],
    completion: @escaping ([String: Any?]) -> Void
  ) {
    pendingLock.lock()
    let id = nextRequestID
    nextRequestID += 1
    pending[id] = completion
    pendingLock.unlock()
    send(["id": id, "method": method, "params": params])
  }

  private func send(_ object: [String: Any?]) {
    guard var frame = try? JSONSerialization.data(withJSONObject: jsonSafe(object)) else { return }
    frame.append(0x0A)
    writeLock.lock()
    output.write(frame)
    writeLock.unlock()
  }

  private func respond(_ id: Int, _ result: [String: Any?]) {
    send(["id": id, "result": result])
  }

  func serve() {
    var buffer = Data()
    while true {
      let chunk = input.availableData
      if chunk.isEmpty { return }  // host closed stdin
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        guard !line.isEmpty,
          let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { continue }
        if !dispatch(message) { return }
      }
    }
  }

  private func dispatch(_ message: [String: Any]) -> Bool {
    let id = message["id"] as? Int
    let params = message["params"] as? [String: Any?] ?? [:]
    guard let method = message["method"] as? String else {
      // id without method: a host response — ours iff the id is pending.
      if let id {
        pendingLock.lock()
        let completion = pending.removeValue(forKey: id)
        pendingLock.unlock()
        if let completion {
          let result = message["result"] as? [String: Any?] ?? [:]
          workers.async { completion(result) }
        }
      }
      return true
    }
    switch method {
    case "initialize":
      guard params["protocol_version"] as? Int == protocolVersion else {
        if let id { respond(id, ["ok": false, "error": "protocol version mismatch"]) }
        return false
      }
      onStart?()  // blocks the reply until the warm store is loaded
      if let id { respond(id, ["ok": true, "protocol_version": protocolVersion]) }
      return true
    case "heartbeat":
      if let id { respond(id, ["ok": true]) }
      return true
    case "shutdown":
      if let id { respond(id, ["ok": true]) }
      return false
    case "sources.snapshot":
      warmLock.lock()
      let candidates = warm.sorted { $0.key < $1.key }.flatMap(\.value)
      warmLock.unlock()
      if let id { respond(id, ["candidates": candidates as [Any?]]) }
      return true
    case "command.invoke":
      if let id { workers.async { [self] in respond(id, onCommand?(params) ?? ["ok": false]) } }
      return true
    case "candidate.resolve":
      if let id { workers.async { [self] in respond(id, onResolve?(params) ?? ["ok": false]) } }
      return true
    case "event":
      let name = params["name"] as? String ?? ""
      let payload = params["payload"] as? [String: Any?] ?? [:]
      workers.async { [self] in onEvent?(name, payload) }
      return true
    default:
      if let id { respond(id, ["ok": false, "error": "unsupported method \(method)"]) }
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
