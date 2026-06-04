import Foundation
import Network

/// Minimal client for Firefox's Marionette automation protocol.
///
/// Why this exists: `CGEvent.postToPid` only delivers keyboard events
/// to the focused-app's focused widget — it requires Firefox to be
/// the frontmost OS app. That blocks parallel fixture runs (only one
/// app can be frontmost) and steals focus from the user every cycle.
/// Marionette delivers synthesized keyboard events directly into the
/// target Firefox's event dispatch via a TCP socket, regardless of
/// which app the OS thinks is frontmost. Multiple Firefox instances
/// each get their own port → trivially parallelizable.
///
/// Wire protocol: `<byteCount>:<jsonArray>` over TCP. The JSON array
/// is `[type, msgID, command, params]` (type=0 is request, type=1 is
/// response). On connect, the server sends a handshake JSON object
/// that we read + discard. Each subsequent message is length-prefixed.
public final class MarionetteClient {

  public enum MarionetteError: Error, CustomStringConvertible {
    case connectTimeout
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case malformedFrame(String)
    case commandError(String)

    public var description: String {
      switch self {
      case .connectTimeout: return "Marionette connect timed out"
      case .connectionFailed(let m): return "Marionette connect failed: \(m)"
      case .sendFailed(let m): return "Marionette send failed: \(m)"
      case .receiveFailed(let m): return "Marionette receive failed: \(m)"
      case .malformedFrame(let m): return "Marionette malformed frame: \(m)"
      case .commandError(let m): return "Marionette command error: \(m)"
      }
    }
  }

  private let conn: NWConnection
  private var msgID: Int = 0
  private var inboundBuffer = Data()
  private let queue = DispatchQueue(label: "flash.marionette", qos: .userInitiated)

  public init(port: UInt16, connectTimeout: TimeInterval = 15) throws {
    let endpointPort = NWEndpoint.Port(rawValue: port)!
    self.conn = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
    let sem = DispatchSemaphore(value: 0)
    var readyError: Error?
    conn.stateUpdateHandler = { state in
      switch state {
      case .ready:
        sem.signal()
      case .failed(let err):
        readyError = err
        sem.signal()
      case .cancelled:
        readyError = MarionetteError.connectionFailed("cancelled")
        sem.signal()
      default:
        break
      }
    }
    conn.start(queue: queue)
    if sem.wait(timeout: .now() + connectTimeout) == .timedOut {
      conn.cancel()
      throw MarionetteError.connectTimeout
    }
    if let readyError {
      throw MarionetteError.connectionFailed(String(describing: readyError))
    }
    // Drain handshake (a single length-prefixed JSON object).
    _ = try readFrame(timeout: 5)
  }

  /// Open a Marionette session. Required before issuing most commands.
  @discardableResult
  public func newSession() throws -> [String: Any] {
    try send(name: "WebDriver:NewSession", params: ["capabilities": [String: Any]()])
  }

  /// Navigate the current top-level browsing context to `url`. Blocks
  /// until the load completes (or page load timeout).
  @discardableResult
  public func navigate(url: URL, timeout: TimeInterval = 30) throws -> [String: Any] {
    try send(
      name: "WebDriver:Navigate",
      params: ["url": url.absoluteString], timeout: timeout)
  }

  /// Open a new browsing context. `type` is `"tab"` (default) or
  /// `"window"`. Returns the new context's handle as a string.
  /// Marionette wraps the WebDriver result in `value`, so we
  /// unwrap one level before reading `handle`.
  public func newWindow(type: String = "tab") throws -> String {
    let r = try send(
      name: "WebDriver:NewWindow",
      params: ["type": type, "focus": false])
    return (r["handle"] as? String) ?? ""
  }

  /// Switch the current target to `handle`. Subsequent commands run
  /// against that tab/window. Modern Marionette expects the param
  /// key as `handle`; older versions used `name`.
  public func switchToWindow(handle: String) throws {
    _ = try send(
      name: "WebDriver:SwitchToWindow", params: ["handle": handle])
  }

  /// Current window handle.
  public func currentWindowHandle() throws -> String {
    let r = try send(
      name: "WebDriver:GetWindowHandle", params: [String: Any]())
    return (r["value"] as? String) ?? ""
  }

  /// Press + release a single key. `key` is a W3C Webdriver key value
  /// — single character for printable keys, or one of the named keys
  /// from the spec (`\u{e00C}` for Escape, etc.). Uses transient ID
  /// "kb-flash-N" per send so successive presses don't share state.
  @discardableResult
  public func tapKey(_ key: String) throws -> [String: Any] {
    msgID += 1  // also drives the input source id
    let actions: [String: Any] = [
      "actions": [
        [
          "id": "kb-flash-\(msgID)",
          "type": "key",
          "actions": [
            ["type": "keyDown", "value": key],
            ["type": "keyUp", "value": key],
          ],
        ] as [String: Any]
      ]
    ]
    return try send(name: "WebDriver:PerformActions", params: actions)
  }

  /// Execute JavaScript in the current top-level browsing context.
  /// `script` is a WebDriver function body; values in `args` are exposed
  /// through the generated function's `arguments` list.
  public func executeScript(
    _ script: String,
    args: [Any] = [],
    timeout: TimeInterval = 10
  ) throws -> Any? {
    let r = try send(
      name: "WebDriver:ExecuteScript",
      params: ["script": script, "args": args],
      timeout: timeout)
    return r["value"]
  }

  /// Execute async JavaScript. WebDriver appends a callback as the last
  /// function argument; invoking it resolves the command result.
  public func executeAsyncScript(
    _ script: String,
    args: [Any] = [],
    timeout: TimeInterval = 10
  ) throws -> Any? {
    let r = try send(
      name: "WebDriver:ExecuteAsyncScript",
      params: ["script": script, "args": args],
      timeout: timeout)
    return r["value"]
  }

  /// Ask Firefox to exit cleanly. Falls back to letting the caller
  /// .terminate() the NSRunningApplication.
  public func quit() throws {
    _ = try? send(name: "Marionette:Quit", params: [String: Any]())
    conn.cancel()
  }

  public func close() {
    conn.cancel()
  }

  // MARK: - Frame I/O

  /// Send a command and wait for the matching response. Marionette
  /// guarantees in-order replies for a given client, so we trust the
  /// next frame is ours.
  private func send(
    name: String,
    params: [String: Any],
    timeout: TimeInterval = 10
  ) throws -> [String: Any] {
    msgID += 1
    let frame: [Any] = [0, msgID, name, params]
    let body: Data
    do {
      body = try JSONSerialization.data(withJSONObject: frame, options: [])
    } catch {
      throw MarionetteError.sendFailed("encode: \(error)")
    }
    let prefix = "\(body.count):"
    var packet = Data(prefix.utf8)
    packet.append(body)

    let sendSem = DispatchSemaphore(value: 0)
    var sendError: Error?
    conn.send(
      content: packet,
      completion: .contentProcessed { err in
        sendError = err
        sendSem.signal()
      })
    if sendSem.wait(timeout: .now() + timeout) == .timedOut {
      throw MarionetteError.sendFailed("send timed out")
    }
    if let sendError {
      throw MarionetteError.sendFailed(String(describing: sendError))
    }
    return try readResponse(timeout: timeout)
  }

  private func readResponse(timeout: TimeInterval) throws -> [String: Any] {
    let raw = try readFrame(timeout: timeout)
    // Response shape: [1, msgID, error, result]. error is null on success.
    guard let arr = raw as? [Any], arr.count >= 4 else {
      throw MarionetteError.malformedFrame("expected 4-array, got \(raw)")
    }
    if let err = arr[2] as? [String: Any] {
      throw MarionetteError.commandError(
        (err["message"] as? String) ?? String(describing: err))
    }
    return (arr[3] as? [String: Any]) ?? [:]
  }

  private func readFrame(timeout: TimeInterval) throws -> Any {
    // Pump receive into inboundBuffer until we have a complete frame.
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let parsed = try takeFrame() {
        return parsed
      }
      let chunk = try readChunk(timeout: max(0.1, deadline.timeIntervalSinceNow))
      inboundBuffer.append(chunk)
    }
    throw MarionetteError.receiveFailed("frame read timed out")
  }

  /// Try to peel one complete frame off `inboundBuffer`. Returns nil
  /// if the buffer doesn't yet contain a full length-prefixed frame.
  private func takeFrame() throws -> Any? {
    // 0x3a is ':'.
    guard let colonIdx = inboundBuffer.firstIndex(of: 0x3a) else {
      return nil
    }
    let lengthString =
      String(data: inboundBuffer[..<colonIdx], encoding: .ascii) ?? ""
    guard let length = Int(lengthString) else {
      throw MarionetteError.malformedFrame("bad length prefix '\(lengthString)'")
    }
    let bodyStart = inboundBuffer.index(after: colonIdx)
    let bodyEnd = inboundBuffer.index(bodyStart, offsetBy: length)
    guard bodyEnd <= inboundBuffer.endIndex else { return nil }
    let body = inboundBuffer[bodyStart..<bodyEnd]
    inboundBuffer.removeSubrange(..<bodyEnd)
    do {
      return try JSONSerialization.jsonObject(with: body, options: [])
    } catch {
      throw MarionetteError.malformedFrame("json decode: \(error)")
    }
  }

  private func readChunk(timeout: TimeInterval) throws -> Data {
    let sem = DispatchSemaphore(value: 0)
    var got = Data()
    var recvError: Error?
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      data, _, _, err in
      if let data { got.append(data) }
      recvError = err
      sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
      throw MarionetteError.receiveFailed("recv timed out")
    }
    if let recvError {
      throw MarionetteError.receiveFailed(String(describing: recvError))
    }
    return got
  }
}
