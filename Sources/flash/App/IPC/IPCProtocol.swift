import Foundation

/// The resident's socket protocol, version 1 (`docs/ipc-protocol.md`).
///
/// One Unix domain socket in a private per-user directory (`IPCEndpoint`)
/// carries newline-delimited JSON. A client says `hello` first; then each
/// `request` carries the words of a command line, run exactly as
/// `:<words>` through the command line's one runner, and its `result` is
/// the same `CommandInvocationResult` object the CLI prints; `subscribe`
/// streams host events (`HostEvent`) as `event` messages. The `flash` CLI
/// is the client scripts use; the JSON Schemas under `docs/schema/ipc/`
/// pin every message, and `IPCSchemaTests` validates real encoded ones
/// against them.
enum IPCProtocol {
  /// The ONLY version the resident speaks. A breaking change bumps it; the
  /// resident never answers an older one (no compatibility shims).
  static let version = 1

  // MARK: - Limits (announced in `welcome.limits`)

  /// Largest line a client may send, newline excluded.
  static let maxInboundFrameBytes = 1 << 20
  /// Largest line the resident sends; a `result` above it is replaced by a
  /// `reply_too_large` error.
  static let maxOutboundFrameBytes = 8 << 20
  /// Connections held at once; more are refused on arrival.
  static let maxConnections = 32
  /// Requests one connection may have running at once.
  static let maxInFlightRequests = 16
  /// Events waiting unsent for one subscriber before it is disconnected.
  static let maxQueuedEvents = 256
  static let maxQueuedEventBytes = 4 << 20
  /// Patterns one `subscribe` may name.
  static let maxSubscriptionPatterns = 64
  static let maxWords = 1_024
  static let maxIDBytes = 128
  static let maxClientNameBytes = 128
  static let maxPathBytes = 4_096
  /// A connection that has not said `hello` by then is closed.
  static let handshakeTimeoutMs = 5_000
  /// How long a connection the resident is closing may take to read what it
  /// is still owed (its last error) before it is cut off.
  static let closeGraceMs = 1_000

  /// The limits one server applies, as `welcome` announces them. Tests
  /// shrink them; the resident runs `.standard`.
  struct Limits: Equatable, Sendable {
    var maxInboundFrameBytes = IPCProtocol.maxInboundFrameBytes
    var maxOutboundFrameBytes = IPCProtocol.maxOutboundFrameBytes
    var maxConnections = IPCProtocol.maxConnections
    var maxInFlightRequests = IPCProtocol.maxInFlightRequests
    var maxQueuedEvents = IPCProtocol.maxQueuedEvents
    var maxQueuedEventBytes = IPCProtocol.maxQueuedEventBytes
    var handshakeTimeoutMs = IPCProtocol.handshakeTimeoutMs
    var closeGraceMs = IPCProtocol.closeGraceMs

    static let standard = Limits()

    var announced: [String: Int] {
      [
        "max_frame_bytes": maxInboundFrameBytes,
        "max_reply_bytes": maxOutboundFrameBytes,
        "max_connections": maxConnections,
        "max_in_flight": maxInFlightRequests,
        "max_queued_events": maxQueuedEvents,
        "max_queued_event_bytes": maxQueuedEventBytes,
        "max_patterns": IPCProtocol.maxSubscriptionPatterns,
        "handshake_timeout_ms": handshakeTimeoutMs,
      ]
    }
  }

  // MARK: - Messages

  /// Every `type` a client sends, in documentation order.
  static let clientMessageTypes = ["hello", "request", "subscribe"]
  /// Every `type` the resident sends, in documentation order.
  static let serverMessageTypes = ["welcome", "result", "subscribed", "event", "error"]

  /// Why the resident answered with an `error`.
  enum ErrorCode: String, CaseIterable, Sendable {
    /// The line is not a JSON object with a known `type`, or lacks a
    /// trustworthy `id`.
    case malformed
    /// The line is longer than `max_frame_bytes`.
    case frameTooLarge = "frame_too_large"
    /// Something other than `hello` came first, or `hello` came twice.
    case handshakeRequired = "handshake_required"
    /// `hello` asked for a version the resident does not speak.
    case protocolMismatch = "protocol_mismatch"
    /// No `hello` within `handshake_timeout_ms`.
    case handshakeTimeout = "handshake_timeout"
    /// `max_connections` are already open.
    case tooManyConnections = "too_many_connections"
    /// A `request` or `subscribe` with an `id` whose other fields are wrong.
    case invalidRequest = "invalid_request"
    /// `max_in_flight` requests are already running on this connection.
    case tooManyRequests = "too_many_requests"
    /// A `subscribe` pattern matches no event the resident streams.
    case unknownEvent = "unknown_event"
    /// The result was larger than `max_reply_bytes`.
    case replyTooLarge = "reply_too_large"
    /// The subscriber fell `max_queued_events` behind.
    case overflow
    /// The resident is quitting.
    case shuttingDown = "shutting_down"

    /// Whether the resident closes the connection once it is sent. The
    /// others answer one `id` and leave the connection open.
    var closesConnection: Bool {
      switch self {
      case .invalidRequest, .tooManyRequests, .unknownEvent, .replyTooLarge: return false
      case .malformed, .frameTooLarge, .handshakeRequired, .protocolMismatch,
        .handshakeTimeout, .tooManyConnections, .overflow, .shuttingDown:
        return true
      }
    }
  }

  /// What a client sent, validated.
  enum ClientMessage: Equatable {
    case hello(protocolVersion: Int, client: String?)
    case request(id: String, words: [String], cwd: String?)
    case subscribe(id: String, events: [String])
  }

  /// Why a line was refused: the error the resident answers it with.
  struct Rejection: Error, Equatable {
    var code: ErrorCode
    var message: String
    var id: String?
  }

  /// Decode one line a client sent. Unknown fields are refused, as the
  /// schemas' `additionalProperties: false` says.
  static func decodeClientMessage(_ frame: Data) -> Result<ClientMessage, Rejection> {
    guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
      return .failure(Rejection(code: .malformed, message: "a message is one JSON object"))
    }
    guard let type = object["type"] as? String else {
      return .failure(Rejection(code: .malformed, message: "a message needs a string type"))
    }
    switch type {
    case "hello":
      if let extra = unknownKey(in: object, allowed: ["type", "protocol", "client"]) {
        return .failure(Rejection(code: .malformed, message: "hello has no field \(extra)"))
      }
      guard let version = PluginJSON.integer(object["protocol"]) else {
        return .failure(
          Rejection(code: .malformed, message: "hello needs an integer protocol"))
      }
      var client: String?
      if let value = object["client"] {
        guard let name = value as? String, name.utf8.count <= maxClientNameBytes else {
          return .failure(
            Rejection(
              code: .malformed,
              message: "hello's client is a string of at most \(maxClientNameBytes) bytes"))
        }
        client = name
      }
      return .success(.hello(protocolVersion: version, client: client))
    case "request", "subscribe":
      guard let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= maxIDBytes else {
        return .failure(
          Rejection(
            code: .malformed,
            message: "\(type) needs an id, a string of 1 to \(maxIDBytes) bytes"))
      }
      return type == "request" ? decodeRequest(object, id: id) : decodeSubscribe(object, id: id)
    default:
      return .failure(Rejection(code: .malformed, message: "unknown message type \(type)"))
    }
  }

  private static func decodeRequest(_ object: [String: Any], id: String) -> Result<
    ClientMessage, Rejection
  > {
    func invalid(_ message: String) -> Result<ClientMessage, Rejection> {
      .failure(Rejection(code: .invalidRequest, message: message, id: id))
    }
    if let extra = unknownKey(in: object, allowed: ["type", "id", "words", "cwd"]) {
      return invalid("request has no field \(extra)")
    }
    guard let words = object["words"] as? [Any], !words.isEmpty, words.count <= maxWords,
      let strings = words as? [String]
    else { return invalid("words is an array of 1 to \(maxWords) strings") }
    var cwd: String?
    if let value = object["cwd"] {
      guard let path = value as? String, path.hasPrefix("/"), path.utf8.count <= maxPathBytes
      else { return invalid("cwd is an absolute path of at most \(maxPathBytes) bytes") }
      cwd = path
    }
    return .success(.request(id: id, words: strings, cwd: cwd))
  }

  private static func decodeSubscribe(_ object: [String: Any], id: String) -> Result<
    ClientMessage, Rejection
  > {
    func invalid(_ message: String) -> Result<ClientMessage, Rejection> {
      .failure(Rejection(code: .invalidRequest, message: message, id: id))
    }
    if let extra = unknownKey(in: object, allowed: ["type", "id", "events"]) {
      return invalid("subscribe has no field \(extra)")
    }
    guard let events = object["events"] as? [Any], events.count <= maxSubscriptionPatterns,
      let patterns = events as? [String]
    else { return invalid("events is an array of at most \(maxSubscriptionPatterns) patterns") }
    return .success(.subscribe(id: id, events: patterns))
  }

  private static func unknownKey(in object: [String: Any], allowed: Set<String>) -> String? {
    object.keys.sorted().first { !allowed.contains($0) }
  }

  // MARK: - Events

  /// The host events a client may subscribe to, in catalog order: every
  /// event `AppDelegate.emitHostEvent` sends, never the plugin plumbing.
  static let streamedEvents: [String] = HostEvent.allCases.filter(\.isStreamed).map(\.rawValue)

  /// The events `patterns` name, sorted, or the first pattern that names
  /// none. Patterns are the globs a plugin's `listen` takes.
  static func resolveSubscription(_ patterns: [String]) -> Result<[String], Rejection> {
    var names = Set<String>()
    for raw in patterns {
      let pattern = PluginPattern(raw)
      let matched = streamedEvents.filter(pattern.matches)
      guard !matched.isEmpty else {
        return .failure(
          Rejection(
            code: .unknownEvent, message: "\(raw) matches no event the resident streams"))
      }
      names.formUnion(matched)
    }
    return .success(names.sorted())
  }

  // MARK: - Encoding (resident → client)

  static func welcomeFrame(server: String, pid: Int32, limits: Limits = .standard) -> Data {
    frame([
      "type": "welcome", "protocol": version, "server": server, "pid": Int(pid),
      "limits": limits.announced,
    ])
  }

  /// The `result` of a request: `result` is exactly the JSON the CLI reads,
  /// `CommandInvocationResult.json`.
  static func resultFrame(id: String, result: CommandInvocationResult) -> Data {
    let object = (try? JSONSerialization.jsonObject(with: result.json)) ?? ["status": "failed"]
    return frame(["type": "result", "id": id, "result": object])
  }

  static func subscribedFrame(id: String, events: [String]) -> Data {
    frame(["type": "subscribed", "id": id, "events": events])
  }

  static func errorFrame(_ code: ErrorCode, _ message: String, id: String? = nil) -> Data {
    var object: [String: Any] = ["type": "error", "code": code.rawValue, "message": message]
    if let id { object["id"] = id }
    if code == .protocolMismatch { object["protocol"] = version }
    return frame(object)
  }

  static func errorFrame(_ rejection: Rejection) -> Data {
    errorFrame(rejection.code, rejection.message, id: rejection.id)
  }

  /// One `event` line, or nil when the payload is not JSON.
  static func eventFrame(seq: UInt64, name: String, timeMs: Int64, payload: [String: Any])
    -> Data?
  {
    let object: [String: Any] = [
      "type": "event", "seq": seq, "name": name, "time_ms": timeMs, "payload": payload,
    ]
    guard JSONSerialization.isValidJSONObject(object) else { return nil }
    return frame(object)
  }

  /// A JSON object on one line. JSONSerialization never writes a raw
  /// newline without `.prettyPrinted`, so the delimiter is unambiguous.
  static func frame(_ object: [String: Any]) -> Data {
    var data =
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
      ?? Data(#"{"code":"malformed","message":"unencodable","type":"error"}"#.utf8)
    data.append(0x0A)
    return data
  }

  // MARK: - Encoding (client → resident)

  static func helloMessage(client: String?) -> [String: Any] {
    var message: [String: Any] = ["type": "hello", "protocol": version]
    if let client { message["client"] = client }
    return message
  }

  /// `cwd` is sent only when it is absolute, as the resident requires.
  static func requestMessage(id: String, words: [String], cwd: String?) -> [String: Any] {
    var message: [String: Any] = ["type": "request", "id": id, "words": words]
    if let cwd, cwd.hasPrefix("/") { message["cwd"] = cwd }
    return message
  }

  static func subscribeMessage(id: String, events: [String]) -> [String: Any] {
    ["type": "subscribe", "id": id, "events": events]
  }

  // MARK: - Decoding (client side)

  /// What the resident sent, as the CLI reads it.
  enum ServerMessage: Equatable {
    case welcome(protocolVersion: Int, server: String)
    case result(id: String, CommandInvocationResult)
    case subscribed(id: String, events: [String])
    case event(name: String)
    case error(code: String, message: String, id: String?)
  }

  static func decodeServerMessage(_ frame: Data) -> ServerMessage? {
    guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
      let type = object["type"] as? String
    else { return nil }
    switch type {
    case "welcome":
      guard let version = PluginJSON.integer(object["protocol"]) else { return nil }
      return .welcome(protocolVersion: version, server: object["server"] as? String ?? "")
    case "result":
      guard let id = object["id"] as? String, let body = object["result"] as? [String: Any],
        let data = try? JSONSerialization.data(withJSONObject: body),
        let result = CommandInvocationResult(json: data)
      else { return nil }
      return .result(id: id, result)
    case "subscribed":
      guard let id = object["id"] as? String, let events = object["events"] as? [String] else {
        return nil
      }
      return .subscribed(id: id, events: events)
    case "event":
      guard let name = object["name"] as? String else { return nil }
      return .event(name: name)
    case "error":
      guard let code = object["code"] as? String else { return nil }
      return .error(
        code: code, message: object["message"] as? String ?? "", id: object["id"] as? String)
    default:
      return nil
    }
  }
}
