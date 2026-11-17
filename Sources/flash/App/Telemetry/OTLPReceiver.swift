import FlashCore
import Foundation
import Network

/// The opt-in OTLP/HTTP receiver (`[telemetry.receiver]`): the one listener
/// besides the help server. It binds the loopback address itself, as
/// `DebugServer` does, answers only requests whose `Host` names it, refuses
/// any request a web page could make (a cross-origin `Origin`, a form-encoded
/// body, a preflight) and sends no CORS headers, so a page in the user's
/// browser can neither write metrics nor read an answer.
///
/// `POST /v1/metrics`, `/v1/logs` and `/v1/traces` take protobuf or JSON,
/// optionally gzip-compressed, decoded on the receiver's queue and handed to
/// the `TelemetryStore`. Responses follow OTLP/HTTP: 200 with an empty body
/// or a partial success, 400 for a body that does not decode, 413 over the
/// size cap, 415 for another media type or encoding, 503 while too many
/// requests are in flight — each error carrying a `google.rpc.Status`.
final class OTLPReceiver {
  /// Largest body as sent, compressed or not.
  static let maxBodyBytes = 4 * 1024 * 1024
  /// Largest body once inflated.
  static let maxDecodedBytes = 16 * 1024 * 1024
  static let maxHeaderBytes = 16 * 1024
  /// Requests decoded at once; more answer 503 so the sender retries.
  static let maxInFlight = 8
  /// Connections held at once; more are closed on arrival.
  static let maxConnections = 32
  /// A connection that has not sent a whole request by then is closed.
  static let requestTimeoutSeconds: TimeInterval = 30
  /// The `User-Agent` Flash's own exporter sends: the receiver never takes
  /// Flash's own telemetry back.
  static let exporterUserAgentPrefix = "flash-telemetry/"

  let port: Int
  /// `[telemetry.receiver] token`; empty asks for none.
  let token: String
  private let store: TelemetryStore
  private let queue = DispatchQueue(label: "flash.telemetry.receiver", qos: .utility)
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var inFlight = 0
  private var stopped = false
  private let lock = NSLock()
  private var status = Status()
  private var readinessWaiters: [(UInt16?) -> Void] = []
  /// The listener's latest outcome, queue-confined: nil while it binds.
  private var settled: UInt16??
  /// Called on the receiver's queue whenever `status` changes.
  var onStatusChange: (() -> Void)?

  /// What the help page shows about the listener itself; the store keeps
  /// the counts of what was accepted.
  struct Status: Equatable {
    var listeningPort: UInt16?
    var error: String?
    /// Requests answered with an error, by HTTP status.
    var refused: [Int: Int] = [:]
    var lastRefusal: String?
  }

  init(port: Int, store: TelemetryStore, token: String = "") {
    self.port = port
    self.store = store
    self.token = token
  }

  var currentStatus: Status {
    lock.lock()
    defer { lock.unlock() }
    return status
  }

  private func updateStatus(_ change: (inout Status) -> Void) {
    lock.lock()
    change(&status)
    lock.unlock()
    onStatusChange?()
  }

  func start() {
    guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
      (0...65535).contains(port)
    else {
      updateStatus { $0.error = "invalid port \(port)" }
      return
    }
    do {
      // Bind the loopback address itself: an interface restriction alone
      // still listens on every address and only refuses what arrives
      // elsewhere. The per-connection and Host checks stay as defense in
      // depth.
      let parameters: NWParameters = .tcp
      parameters.requiredInterfaceType = .loopback
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          let bound = listener.port?.rawValue
          FlashLog.info("[telemetry] receiver listening http://127.0.0.1:\(bound ?? 0)")
          self.updateStatus {
            $0.listeningPort = bound
            $0.error = nil
          }
          self.settle(bound)
        case .failed(let error):
          FlashLog.warn("[telemetry] receiver failed \(error)")
          self.updateStatus {
            $0.listeningPort = nil
            $0.error = "\(error)"
          }
          self.settle(nil)
        case .cancelled:
          self.updateStatus { $0.listeningPort = nil }
          self.settle(nil)
        default:
          break
        }
      }
      listener.start(queue: queue)
      self.listener = listener
    } catch {
      FlashLog.error("[telemetry] receiver could not start on port \(port): \(error)")
      updateStatus { $0.error = "\(error)" }
      queue.async { [weak self] in self?.settle(nil) }
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    queue.async { [self] in
      stopped = true
      for connection in connections.values { connection.cancel() }
      connections.removeAll()
      settle(nil)
    }
  }

  /// `completion` on the receiver's queue with the bound port once the
  /// listener is ready, or nil when it failed or stopped. The listener's
  /// own state change answers; nothing polls for the port.
  func whenListening(_ completion: @escaping (UInt16?) -> Void) {
    queue.async { [self] in
      if let settled { return completion(settled) }
      readinessWaiters.append(completion)
    }
  }

  private func settle(_ port: UInt16?) {
    settled = .some(port)
    let waiters = readinessWaiters
    readinessWaiters.removeAll()
    for waiter in waiters { waiter(port) }
  }

  // MARK: Connections

  private func accept(_ connection: NWConnection) {
    guard !stopped, DebugServer.isLoopback(endpoint: connection.endpoint),
      connections.count < Self.maxConnections
    else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      switch state {
      case .cancelled, .failed:
        // The registry holds the connection, so while it is registered
        // this reference is alive.
        if let connection, self?.connections[id] === connection {
          self?.connections.removeValue(forKey: id)
        }
        if case .failed = state { connection?.cancel() }
      default:
        break
      }
    }
    connection.start(queue: queue)
    // Bounds one request's arrival, not a recurring job. Identity, not the
    // key alone: a later connection can reuse a finished one's address.
    queue.asyncAfter(deadline: .now() + Self.requestTimeoutSeconds) {
      [weak self, weak connection] in
      guard let self, let connection, self.connections[id] === connection else { return }
      self.connections.removeValue(forKey: id)
      connection.cancel()
    }
    read(connection, buffer: Data(), continued: false)
  }

  private func read(_ connection: NWConnection, buffer: Data, continued: Bool) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return connection.cancel() }
      var buffer = buffer
      if let data, !data.isEmpty { buffer.append(data) }
      // Chunk framing and headers on top of the largest body.
      guard buffer.count <= Self.maxBodyBytes + Self.maxHeaderBytes + 64 * 1024 else {
        return self.send(.error(413, "request body too large", encoding: .protobuf), connection)
      }
      switch OTLPHTTP.assemble(buffer, maxBody: Self.maxBodyBytes) {
      case .ready(let request):
        self.handle(request, connection)
      case .tooLarge:
        self.send(.error(413, "request body too large", encoding: .protobuf), connection)
      case .malformed(let reason):
        self.send(.error(400, reason, encoding: .protobuf), connection)
      case .incomplete(let expectsContinue):
        guard !isComplete, error == nil else { return connection.cancel() }
        if expectsContinue, !continued {
          connection.send(
            content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
            completion: .contentProcessed { _ in })
        }
        self.read(connection, buffer: buffer, continued: continued || expectsContinue)
      }
    }
  }

  /// Decoding runs off the receiver's queue, a bounded number at a time,
  /// so a large body never holds up the next connection's headers.
  private func handle(_ request: OTLPHTTPRequest, _ connection: NWConnection) {
    guard inFlight < Self.maxInFlight else {
      var response = OTLPHTTPResponse.error(
        503, "too many requests in flight", encoding: request.encoding)
      response.headers.append(("Retry-After", "1"))
      return send(response, connection)
    }
    inFlight += 1
    let port = currentStatus.listeningPort
    let store = store
    let token = token
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let response = Self.respond(to: request, port: port, store: store, token: token)
      self?.queue.async {
        guard let self else { return }
        self.inFlight -= 1
        self.send(response, connection)
      }
    }
  }

  private func send(_ response: OTLPHTTPResponse, _ connection: NWConnection) {
    if response.status >= 400 {
      let message = String(decoding: response.statusMessage, as: UTF8.self)
      FlashLog.debug("[telemetry] receiver refused status=\(response.status) reason=\(message)")
      updateStatus {
        $0.refused[response.status, default: 0] += 1
        $0.lastRefusal = "\(response.status) \(message)"
      }
    }
    connection.send(
      content: response.serialized,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  // MARK: Requests

  /// The whole answer to one request, decided without the socket: the
  /// checks in order, then decode and ingest.
  static func respond(
    to request: OTLPHTTPRequest, port: UInt16?, store: TelemetryStore, token: String = ""
  ) -> OTLPHTTPResponse {
    let encoding = request.encoding
    guard hostIsLoopback(request.header("host"), port: port) else {
      return .error(403, "the Host header must name this loopback receiver", encoding: encoding)
    }
    if let origin = request.header("origin"), !isSameOrigin(origin, port: port) {
      return .error(403, "cross-origin requests are refused", encoding: encoding)
    }
    if let site = request.header("sec-fetch-site")?.lowercased(),
      !["same-origin", "none"].contains(site)
    {
      return .error(403, "cross-site requests are refused", encoding: encoding)
    }
    // Any account or process can reach loopback: a configured token is
    // required before anything is decoded or counted.
    if !token.isEmpty {
      let presented = request.header("authorization").flatMap { value -> String? in
        guard value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
      }
      guard let presented, HelpAccess.matches(presented, token) else {
        var response = OTLPHTTPResponse.error(
          401, "this receiver requires Authorization: Bearer <token>", encoding: encoding)
        response.headers.append(("WWW-Authenticate", "Bearer"))
        return response
      }
    }
    guard let signal = TelemetrySignal.allCases.first(where: { $0.path == request.path }) else {
      return .error(
        404, "no such endpoint; use /v1/metrics, /v1/logs or /v1/traces", encoding: encoding)
    }
    guard request.method == "POST" else {
      var response = OTLPHTTPResponse.error(405, "use POST", encoding: encoding)
      response.headers.append(("Allow", "POST"))
      return response
    }
    if request.header("user-agent")?.hasPrefix(exporterUserAgentPrefix) == true {
      return .error(403, "Flash does not receive its own telemetry", encoding: encoding)
    }
    guard let declared = request.header("content-type"),
      let bodyEncoding = OTLPEncoding(contentType: declared)
    else {
      return .error(
        415, "Content-Type must be application/x-protobuf or application/json",
        encoding: encoding)
    }
    var body = request.body
    switch request.header("content-encoding")?.lowercased() {
    case nil, "", "identity":
      break
    case "gzip":
      do {
        body = try OTLPCodec.gunzip(body, limit: maxDecodedBytes)
      } catch OTLPCodecError.tooLarge {
        return .error(413, "decompressed body too large", encoding: bodyEncoding)
      } catch {
        return .error(400, "invalid gzip body", encoding: bodyEncoding)
      }
    default:
      return .error(415, "Content-Encoding must be gzip or identity", encoding: bodyEncoding)
    }
    let export: OTLPExport
    do {
      export = try OTLPCodec.decode(body, signal: signal, encoding: bodyEncoding)
    } catch OTLPCodecError.malformed(let reason) {
      return .error(400, reason, encoding: bodyEncoding)
    } catch {
      return .error(400, "invalid request body", encoding: bodyEncoding)
    }
    let result = store.ingest(export)
    return OTLPHTTPResponse(
      status: 200, contentType: bodyEncoding.contentType,
      body: OTLPCodec.successBody(
        signal: signal, rejected: result.rejected, message: result.message,
        encoding: bodyEncoding))
  }

  /// The `Host` names this receiver: 127.0.0.1 or localhost, on its port.
  static func hostIsLoopback(_ host: String?, port: UInt16?) -> Bool {
    guard let value = host?.trimmingCharacters(in: .whitespaces).lowercased(), let port else {
      return false
    }
    return ["127.0.0.1", "localhost"].contains { name in
      value == "\(name):\(port)" || (port == 80 && value == name)
    }
  }

  /// An `Origin` a request from this receiver's own origin would carry; a
  /// browser sends one on every cross-origin request, simple POSTs included.
  static func isSameOrigin(_ origin: String, port: UInt16?) -> Bool {
    guard let port else { return false }
    let value = origin.trimmingCharacters(in: .whitespaces).lowercased()
    return ["127.0.0.1", "localhost"].contains { value == "http://\($0):\(port)" }
  }
}

/// One HTTP/1.1 request as the receiver reads it.
struct OTLPHTTPRequest: Equatable {
  var method: String
  /// Without its query.
  var path: String
  /// Lowercased names; repeated headers joined with `,`.
  var headers: [String: String]
  var body: Data

  func header(_ name: String) -> String? { headers[name] }

  /// The encoding an error answer uses: the request's own when it named one,
  /// protobuf otherwise, as OTLP/HTTP specifies.
  var encoding: OTLPEncoding {
    header("content-type").flatMap(OTLPEncoding.init(contentType:)) ?? .protobuf
  }
}

struct OTLPHTTPResponse: Equatable {
  var status: Int
  var contentType: String
  var body: Data
  var headers: [(String, String)] = []
  /// An error's message, for the log and the help page.
  var statusMessage = Data()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.status == rhs.status && lhs.contentType == rhs.contentType && lhs.body == rhs.body
      && lhs.headers.map { "\($0.0): \($0.1)" } == rhs.headers.map { "\($0.0): \($0.1)" }
  }

  /// An OTLP error: the status code with a `google.rpc.Status` body.
  static func error(_ status: Int, _ message: String, encoding: OTLPEncoding) -> Self {
    let code: Int32
    switch status {
    case 400: code = 3  // INVALID_ARGUMENT
    case 401: code = 16  // UNAUTHENTICATED
    case 403: code = 7  // PERMISSION_DENIED
    case 404: code = 5  // NOT_FOUND
    case 413: code = 8  // RESOURCE_EXHAUSTED
    case 503: code = 14  // UNAVAILABLE
    default: code = 2  // UNKNOWN
    }
    return OTLPHTTPResponse(
      status: status, contentType: encoding.contentType,
      body: OTLPCodec.statusBody(code: code, message: message, encoding: encoding),
      statusMessage: Data(message.utf8))
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    case 415: return "Unsupported Media Type"
    case 503: return "Service Unavailable"
    default: return "Error"
    }
  }

  /// Every answer closes the connection, and says so before a pooled client
  /// can reuse the socket.
  var serialized: Data {
    var lines = [
      "HTTP/1.1 \(status) \(Self.reason(status))",
      "Content-Type: \(contentType)",
      "Content-Length: \(body.count)",
      "Cache-Control: no-store",
      "X-Content-Type-Options: nosniff",
      "Connection: close",
    ]
    lines += headers.map { "\($0.0): \($0.1)" }
    var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    data.append(body)
    return data
  }
}

/// HTTP/1.1 request framing: headers, then a `Content-Length` body or a
/// chunked one. Pure over the bytes received so far.
enum OTLPHTTP {
  enum Assembly: Equatable {
    /// More bytes are needed. `expectsContinue`: the client sent
    /// `Expect: 100-continue` and waits for the interim answer.
    case incomplete(expectsContinue: Bool)
    case tooLarge
    case malformed(String)
    case ready(OTLPHTTPRequest)
  }

  private static let headerEnd = Data([13, 10, 13, 10])

  static func assemble(_ data: Data, maxBody: Int) -> Assembly {
    guard let end = data.range(of: headerEnd) else {
      return data.count > OTLPReceiver.maxHeaderBytes
        ? .tooLarge : .incomplete(expectsContinue: false)
    }
    guard end.lowerBound <= OTLPReceiver.maxHeaderBytes else { return .tooLarge }
    guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
      return .malformed("headers are not UTF-8")
    }
    let lines = text.components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), !requestLine[0].isEmpty
    else { return .malformed("malformed request line") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":"), line.first.map({ !$0.isWhitespace }) == true
      else { return .malformed("malformed header line") }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = headers[name].map { "\($0),\(value)" } ?? value
    }
    let target = String(requestLine[1])
    let path = String(
      target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    let request = OTLPHTTPRequest(
      method: String(requestLine[0]), path: path, headers: headers, body: Data())
    let expectsContinue = headers["expect"]?.lowercased() == "100-continue"
    let body = data[end.upperBound...]
    if let encoding = headers["transfer-encoding"] {
      guard headers["content-length"] == nil else {
        return .malformed("Content-Length and Transfer-Encoding together")
      }
      guard encoding.lowercased() == "chunked" else {
        return .malformed("unsupported Transfer-Encoding")
      }
      switch dechunk(body, maxBody: maxBody) {
      case .complete(let decoded):
        var ready = request
        ready.body = decoded
        return .ready(ready)
      case .incomplete:
        return .incomplete(expectsContinue: expectsContinue && body.isEmpty)
      case .tooLarge:
        return .tooLarge
      case .malformed:
        return .malformed("malformed chunked body")
      }
    }
    guard let raw = headers["content-length"] else { return .ready(request) }
    guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), raw.utf8.count <= 12,
      let length = Int(raw)
    else { return .malformed("malformed Content-Length") }
    guard length <= maxBody else { return .tooLarge }
    guard body.count >= length else {
      return .incomplete(expectsContinue: expectsContinue && body.isEmpty)
    }
    var ready = request
    ready.body = Data(body.prefix(length))
    return .ready(ready)
  }

  enum Dechunked: Equatable {
    case complete(Data)
    case incomplete
    case tooLarge
    case malformed
  }

  /// Decode a chunked body: hex sizes (extensions ignored), each chunk and
  /// its CRLF, a zero chunk and optional trailers.
  static func dechunk(_ data: Data, maxBody: Int) -> Dechunked {
    let crlf = Data([13, 10])
    var output = Data()
    var index = data.startIndex
    while true {
      guard let lineEnd = data[index...].range(of: crlf) else { return .incomplete }
      guard let line = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else {
        return .malformed
      }
      let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespaces)
      guard !sizeText.isEmpty, sizeText.count <= 8, let size = Int(sizeText, radix: 16) else {
        return .malformed
      }
      index = lineEnd.upperBound
      if size == 0 {
        // Trailers, if any, end with an empty line.
        var cursor = index
        while true {
          guard let end = data[cursor...].range(of: crlf) else { return .incomplete }
          if end.lowerBound == cursor { return .complete(output) }
          cursor = end.upperBound
        }
      }
      guard output.count + size <= maxBody else { return .tooLarge }
      guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return .incomplete }
      let chunkEnd = data.index(index, offsetBy: size)
      output.append(data[index..<chunkEnd])
      guard data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)] == crlf else { return .malformed }
      index = data.index(chunkEnd, offsetBy: 2)
    }
  }
}
