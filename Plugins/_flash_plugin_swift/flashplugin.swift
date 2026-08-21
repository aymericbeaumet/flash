// Shared Flash plugin SDK for Swift (Foundation only) — no Flash business
// concepts, mirroring the Rust `flash_plugin` crate's role for Swift
// plugins. Scripts/build-plugins.sh compiles this file alongside each Swift
// plugin's main.swift.
//
// Speaks the wire contract from docs/plugin-protocol.md, whose constants
// are pinned by Plugins/_flash_plugin_specs/protocol.json: protocol v1, one
// JSON object per newline-terminated line over stdio, 10 MiB line cap both
// directions. Frame triage: id+method is a host request, id alone resolves
// a callHost waiter, method alone is a notification. The catalog is
// push-based (publish replaces it whole), perform is the single effect
// method with its four kinds routed to onResolve/onCommand/onAction/
// onNavigate, and stdin EOF is the shutdown signal. Lifecycle and ping
// answer synchronously on the read thread; handlers run on a worker queue
// so a slow AppleScript can never starve liveness.

import Foundation

// MARK: - Constants

/// The one wire protocol version this SDK speaks, echoed verbatim in every
/// initialize reply.
let protocolVersion = 1

/// One NDJSON line cap, both directions (protocol.json quotas.frame_bytes).
let maxFrameBytes = 10 << 20

/// Default callHost round-trip deadline.
let defaultCallTimeoutMs = 5000

// MARK: - Config / environment

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

/// The host-provided writable data directory. Never defaults to "." — the
/// host always provides the dir, and failing loudly beats scattering plugin
/// state into an arbitrary working directory.
func dataDir() -> String {
  guard let dir = ProcessInfo.processInfo.environment["FLASH_PLUGIN_DATA_DIR"], !dir.isEmpty
  else {
    FileHandle.standardError.write(
      Data("flashplugin: FLASH_PLUGIN_DATA_DIR is unset — refusing to fall back to \".\"\n".utf8))
    exit(1)
  }
  return dir
}

/// JSONSerialization rejects Swift optionals; unwrap recursively
/// (nil → NSNull) so `[String: Any?]` payloads serialize.
private func jsonSafe(_ value: Any?) -> Any {
  guard let value else { return NSNull() }
  if let map = value as? [String: Any?] { return map.mapValues(jsonSafe) }
  if let array = value as? [Any?] { return array.map(jsonSafe) }
  return value
}

// MARK: - Runtime

final class PluginRuntime {
  // MARK: Framing

  private let output = FileHandle.standardOutput
  private let input = FileHandle.standardInput
  private let writeQueue = DispatchQueue(label: "flashplugin.write")  // the one serialized writer
  private let workers = DispatchQueue(label: "flashplugin.workers", attributes: .concurrent)

  /// Encode one frame onto stdout; false when encoding fails or the line
  /// would exceed the outbound cap (the frame is then not written at all —
  /// atomic rejection, never truncation).
  @discardableResult
  private func send(_ object: [String: Any?]) -> Bool {
    guard var frame = try? JSONSerialization.data(withJSONObject: jsonSafe(object)),
      frame.count <= maxFrameBytes
    else { return false }
    frame.append(0x0A)
    writeQueue.sync { output.write(frame) }
    return true
  }

  /// Method-only frame; an oversized notification is dropped.
  private func notify(_ method: String, _ params: [String: Any?]) {
    send(["method": method, "params": params])
  }

  /// The one reply an id'd request gets; a response over the outbound cap
  /// is replaced by the canonical frame-overflow error.
  private func respond(_ id: Int, _ result: [String: Any?]) {
    if !send(["id": id, "result": result]) {
      send(["id": id, "result": fail("response exceeded outbound frame limit")])
    }
  }

  // MARK: Pending / callHost

  private let pendingLock = NSLock()
  private var pending: [Int: ([String: Any?]) -> Void] = [:]
  private var nextRequestID = 1
  private var hostClosed = false

  /// Plugin→host RPC on our own id counter. Blocks the calling (worker)
  /// thread and never fails out-of-band: capability NAKs, host death
  /// ("host closed stdin"), and the deadline ("host call timed out") all
  /// arrive as ordinary {"ok": false, "error": …} results.
  func callHost(
    method: String, params: [String: Any?] = [:], timeoutMs: Int = defaultCallTimeoutMs
  ) -> [String: Any?] {
    pendingLock.lock()
    if hostClosed {
      pendingLock.unlock()
      return fail("host closed stdin")
    }
    let id = nextRequestID
    nextRequestID += 1
    let done = DispatchSemaphore(value: 0)
    var reply: [String: Any?] = [:]
    pending[id] = { result in
      reply = result
      done.signal()
    }
    pendingLock.unlock()
    send(["id": id, "method": method, "params": params])
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
      [self] in settle(id, fail("host call timed out"))  // removes pending: a late reply drops
    }
    done.wait()
    return reply
  }

  /// Resolve one pending call; responses to unknown ids drop silently.
  private func settle(_ id: Int, _ result: [String: Any?]) {
    pendingLock.lock()
    let completion = pending.removeValue(forKey: id)
    pendingLock.unlock()
    completion?(result)
  }

  // MARK: Dispatch

  private var initialized = false

  /// Frame triage: id+method → host request, id alone → callHost response,
  /// method alone → notification (unknown names are ignored). Lifecycle and
  /// ping answer right here on the read thread; handlers go to the workers.
  private func dispatch(_ message: [String: Any]) {
    let id = message["id"] as? Int
    let params = message["params"] as? [String: Any?] ?? [:]
    guard let method = message["method"] as? String else {
      if let id { settle(id, message["result"] as? [String: Any?] ?? fail("malformed host reply")) }
      return
    }
    guard let id else {
      if method == "event" {
        let name = params["name"] as? String ?? ""
        let payload = params["payload"] as? [String: Any?] ?? [:]
        workers.async { [self] in onEvent?(name, payload) }
      }
      return
    }
    switch method {
    case "initialize":
      guard !initialized else {
        respond(id, fail("initialize may only be called once"))
        return  // the one non-terminal protocol NAK: keep serving
      }
      let hostVersion = params["protocol_version"] as? Int ?? 0
      guard hostVersion == protocolVersion else {
        respond(
          id,
          [
            "ok": false, "protocol_version": protocolVersion,
            "error": "protocol version mismatch: host v\(hostVersion), plugin v\(protocolVersion)",
          ])
        exit(0)  // already flushed: writes are synchronous
      }
      initialized = true
      respond(id, ["ok": true, "protocol_version": protocolVersion])
      if let onStart { workers.async(execute: onStart) }  // AFTER the reply
    case "ping":
      respond(id, ["ok": true])
    case "evaluate":
      workers.async { [self] in
        respond(id, ["ok": true, "answers": (onEvaluate?(params) ?? []) as [Any?]])
      }
    case "search":
      workers.async { [self] in
        respond(id, ["ok": true, "rows": (onSearch?(params) ?? []) as [Any?]])
      }
    case "hints":
      workers.async { [self] in
        let (targets, contextPID) = onHints?(params) ?? ([], nil)
        var result: [String: Any?] = ["ok": true, "targets": targets as [Any?]]
        if let contextPID { result["context_pid"] = contextPID }
        respond(id, result)
      }
    case "perform":
      workers.async { [self] in respond(id, perform(params)) }
    default:
      respond(id, fail("unknown method: \(method)"))
    }
  }

  /// The single effect method's kind routing. An unregistered kind is "not
  /// mine" (the host may fall back); an unknown kind is an error (the host
  /// must not fall back on garbage).
  private func perform(_ params: [String: Any?]) -> [String: Any?] {
    let kind = params["kind"] as? String ?? ""
    let registered: ((_ params: [String: Any?]) -> [String: Any?])?
    switch kind {
    case "resolve": registered = onResolve
    case "command": registered = onCommand
    case "action": registered = onAction
    case "navigate": registered = onNavigate
    default: return fail("unknown perform kind: \(kind)")
    }
    guard let handler = registered else { return unhandled() }
    return handler(params)
  }

  // MARK: Handlers

  /// Runs on the worker queue AFTER the initialize reply (the reply is
  /// immediate by contract); typically ends with publish(rows).
  var onStart: (() -> Void)?
  /// Runs after stdin EOF, before the process exits 0.
  var onShutdown: (() -> Void)?
  var onEvent: ((_ name: String, _ payload: [String: Any?]) -> Void)?
  /// Synchronous, CPU-only answers for evaluate.
  var onEvaluate: ((_ params: [String: Any?]) -> [[String: Any?]])?
  /// Live rows in catalog row shape for search.
  var onSearch: ((_ params: [String: Any?]) -> [[String: Any?]])?
  /// Targets plus an optional context pid for hints.
  var onHints: ((_ params: [String: Any?]) -> ([[String: Any?]], Int?))?
  /// The four perform kinds; an unregistered kind answers the canonical
  /// {"ok": false, "unhandled": true}.
  var onResolve: ((_ params: [String: Any?]) -> [String: Any?])?
  var onCommand: ((_ params: [String: Any?]) -> [String: Any?])?
  var onAction: ((_ params: [String: Any?]) -> [String: Any?])?
  var onNavigate: ((_ params: [String: Any?]) -> [String: Any?])?

  // MARK: Emitters

  /// Replace the plugin's entire catalog (push-based; the host owns the
  /// store). Every row carries the first-class "source" field naming a
  /// manifest sources[].name; empty rows is an authoritative empty. On a
  /// transient refresh failure, simply don't publish — the host keeps the
  /// last-good catalog.
  func publish(_ rows: [[String: Any?]]) {
    notify("publish", ["rows": rows as [Any?]])
  }

  /// Feed manifest-declared status segments; "" clears one.
  func status(_ segments: [String: String]) {
    notify("status", ["segments": segments])
  }

  /// Structured, content-free logging: counts, stages, elapsed ms — never
  /// query text or candidate data.
  func log(_ level: String, _ message: String, fields: [String: String] = [:]) {
    notify("log", ["level": level, "message": message, "fields": fields])
  }

  // MARK: Serve loop

  /// Blocking read loop until stdin EOF — the shutdown signal: in-flight
  /// callHost waiters resolve to the canonical host-closed error, the
  /// onShutdown hook runs, and serve returns so main exits 0. An
  /// undecodable line is dropped; a line over the inbound cap is discarded
  /// through its next newline — the stream self-heals, never fatal.
  func serve() {
    var buffer = Data()
    var discarding = false
    while true {
      let chunk = input.availableData
      if chunk.isEmpty { break }  // stdin EOF
      buffer.append(chunk)
      while true {
        if discarding {
          guard let newline = buffer.firstIndex(of: 0x0A) else {
            buffer.removeAll(keepingCapacity: true)
            break
          }
          buffer.removeSubrange(buffer.startIndex...newline)
          discarding = false
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else {
          if buffer.count > maxFrameBytes {  // oversized: discard to the next newline
            buffer.removeAll(keepingCapacity: true)
            discarding = true
          }
          break
        }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        guard !line.isEmpty, line.count <= maxFrameBytes,
          let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { continue }
        dispatch(message)
      }
    }
    pendingLock.lock()
    hostClosed = true
    let inflight = pending
    pending = [:]
    pendingLock.unlock()
    for completion in inflight.values { completion(fail("host closed stdin")) }
    onShutdown?()
  }
}

// MARK: - Reply helpers

/// {"ok": true} carrying any extra reply fields.
func ok(_ fields: [String: Any?] = [:]) -> [String: Any?] {
  var result = fields
  result["ok"] = true
  return result
}

/// perform's "not my context" reply — the host MAY fall back.
func unhandled() -> [String: Any?] { ["ok": false, "unhandled": true] }

/// The ok:false error reply; keep messages content-free.
func fail(_ message: String) -> [String: Any?] { ["ok": false, "error": message] }

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
