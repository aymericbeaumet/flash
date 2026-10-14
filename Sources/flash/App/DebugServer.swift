import Foundation
import Network

final class DebugServer {
  let host: String
  let port: Int
  private(set) var listeningPort: UInt16?
  /// `GET` and `DELETE /api/clipboard/<id>`. Nil answers those routes with
  /// 503. Invoked on the server queue; the completion may run on any queue.
  typealias ClipboardHTTPHandler = (
    _ method: String, _ id: String,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void
  /// `GET`/`PUT /api/config` and `POST /api/config/purge`. Nil answers 503.
  /// Invoked on the server queue; the completion may run on any queue.
  typealias ConfigHTTPHandler = (
    _ method: String, _ purge: Bool, _ body: Data,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void

  private let stateProvider: () -> [String: Any]
  private let clipboardHTTP: ClipboardHTTPHandler?
  private let configHTTP: ConfigHTTPHandler?
  /// How long the first change of a burst waits for the rest: every change
  /// inside the window joins one snapshot.
  private let coalescingWindowMs: Int
  /// The pending coalesced publish, on the shared clock. `.normal`: a
  /// diagnostic page refreshing a tenth of a second later is invisible, and
  /// it coalesces with the app's other wake-ups. Main-thread confined.
  private lazy var publishDeadline = PollDeadline(
    "core:inspector_publish:\(UInt(bitPattern: ObjectIdentifier(self).hashValue))",
    priority: .normal, on: .main)
  private let queue = DispatchQueue(label: "flash.debug_server", qos: .utility)
  private var listener: NWListener?
  private var logSinkID: UUID?
  private var logs: [[String: Any]] = []
  private var eventConnections: [UUID: NWConnection] = [:]
  /// Queue-confined. The listener's outcome: nil while it is still binding.
  private var readiness: ListenerReadiness?
  /// Queue-confined callers of `whenListening` waiting for that outcome.
  private var readinessWaiters: [UUID: (UInt16?) -> Void] = [:]
  private var stopped = false

  private enum ListenerReadiness {
    case listening(UInt16)
    case failed
  }
  /// Last app-state snapshot — taken on the main thread, then confined to
  /// `queue`. The server serves this on `/api/state` and `/api/events` rather than
  /// calling `stateProvider` on its own queue (which raced the main thread, the
  /// data race this fixes — and a synchronous main hop would instead deadlock if
  /// a caller blocks main, as the test harness does). Seeded in `start()` and
  /// replaced by each publish.
  private var cachedState: [String: Any] = [:]
  /// Queue-confined mirror of `publication.stale`, in main's order: whether
  /// `cachedState` still reflects every change main has reported.
  private var cachedStateIsCurrent = true
  /// Main-confined: what the pushed state owes its readers.
  private(set) var publication = Publication()
  private let maxLogs = 2_000

  /// Main-confined publication state. The inspector has no clock: app
  /// changes call `stateDidChange`, and a snapshot is taken only when someone
  /// can read it — once per coalescing window while a browser holds an event
  /// stream, or when a request finds the cache stale.
  struct Publication: Equatable {
    /// Event streams open, mirrored from `queue`.
    var streams = 0
    /// A change arrived since the last snapshot.
    var stale = false
    /// A coalesced publish is waiting out its window.
    var armed = false
    var stopped = false
  }

  init(
    host: String, port: Int, coalescingWindowMs: Int = 100,
    clipboardHTTP: ClipboardHTTPHandler? = nil,
    configHTTP: ConfigHTTPHandler? = nil,
    stateProvider: @escaping () -> [String: Any]
  ) {
    self.host = host
    self.port = port
    self.coalescingWindowMs = coalescingWindowMs
    self.clipboardHTTP = clipboardHTTP
    self.configHTTP = configHTTP
    self.stateProvider = stateProvider
  }

  func start() {
    guard let endpoint = Self.parse(host: host, port: port) else {
      FlashLog.warn("[debug] invalid http_inspector_host/port \(host):\(port)")
      return
    }
    do {
      // Bind the listener to the loopback interface explicitly. Without
      // `requiredInterfaceType = .loopback`, `NWListener` accepts on every
      // local interface — the per-connection `isLoopback` check would still
      // reject non-loopback peers, but the port would show up in any LAN
      // portscan. Restricting the listener at bind time is defense in depth.
      let parameters: NWParameters = .tcp
      parameters.requiredInterfaceType = .loopback
      let listener = try NWListener(using: parameters, on: endpoint.port)
      listener.newConnectionHandler = { [weak self] connection in
        self?.handle(connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          let port = listener.port?.rawValue
          self?.listeningPort = port
          FlashLog.info("[debug] http inspector listening http://\(endpoint.host):\(port ?? 0)")
          self?.settleReadiness(port.map(ListenerReadiness.listening) ?? .failed)
        case .failed(let error):
          FlashLog.warn("[debug] http inspector failed \(error)")
          self?.settleReadiness(.failed)
        case .cancelled:
          self?.settleReadiness(.failed)
        default:
          break
        }
      }
      // Seed the cache on the main thread (start() runs on main) so the first
      // /api/state request is answered without a main hop.
      publishState()
      listener.start(queue: queue)
      self.listener = listener
      // Follows `[debug] log_level`: the inspector shows what the log file
      // gets, and never forces lower-level messages on hot paths to be built.
      logSinkID = FlashLog.addSink(minLevel: nil) { [weak self] record in
        self?.append(record)
      }
    } catch {
      FlashLog.warn("[debug] could not start http inspector \(host):\(port): \(error)")
      queue.async { [weak self] in self?.settleReadiness(.failed) }
    }
  }

  func stop() {
    publication.stopped = true
    publishDeadline.cancel()
    if let logSinkID {
      FlashLog.removeSink(logSinkID)
    }
    logSinkID = nil
    listener?.cancel()
    listener = nil
    queue.async { [self] in
      stopped = true
      for connection in eventConnections.values {
        connection.cancel()
      }
      eventConnections.removeAll()
      settleReadiness(.failed)
    }
  }

  /// Call `completion` on the main thread with the bound port once the
  /// listener is ready, or with nil when it fails, is stopped, or is not
  /// ready within `timeoutSeconds`. The listener's own state change answers;
  /// nothing polls for the port.
  func whenListening(timeoutSeconds: TimeInterval, _ completion: @escaping (UInt16?) -> Void) {
    let deliver: (UInt16?) -> Void = { port in DispatchQueue.main.async { completion(port) } }
    queue.async { [self] in
      switch readiness {
      case .listening(let port): return deliver(port)
      case .failed: return deliver(nil)
      case nil: break
      }
      // Each waiter owns its deadline, so an earlier caller's expiry never
      // cuts a later one short.
      let id = UUID()
      readinessWaiters[id] = deliver
      queue.asyncAfter(deadline: .now() + timeoutSeconds) { [self] in
        guard let waiter = readinessWaiters.removeValue(forKey: id) else { return }
        FlashLog.warn("[debug] inspector did not start in time")
        waiter(nil)
      }
    }
  }

  /// Runs on `queue`. The latest outcome stands (a listener that fails or is
  /// stopped after binding no longer serves); every waiter hears it once.
  private func settleReadiness(_ outcome: ListenerReadiness) {
    readiness = outcome
    let port: UInt16?
    if case .listening(let bound) = outcome { port = bound } else { port = nil }
    let waiters = readinessWaiters.values
    readinessWaiters.removeAll()
    for waiter in waiters { waiter(port) }
  }

  /// The one entry for every app change the state reflects (main thread).
  /// With a browser on the event stream, the first change of a burst arms
  /// one publish `coalescingWindowMs` later and the rest join it; with none,
  /// nothing is taken — the cache is only marked stale, and the next request
  /// or stream takes a fresh snapshot.
  func stateDidChange() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !publication.stopped else { return }
    if !publication.stale {
      publication.stale = true
      queue.async { [weak self] in self?.cachedStateIsCurrent = false }
    }
    armPublishIfObserved()
  }

  /// Main thread: an event stream opened (+1) or closed (-1). A stream that
  /// opens on a stale cache gets a fresh snapshot through the same window.
  func streamsDidChange(by delta: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    publication.streams = max(0, publication.streams + delta)
    armPublishIfObserved()
  }

  private func armPublishIfObserved() {
    guard publication.stale, publication.streams > 0, !publication.armed, !publication.stopped
    else { return }
    publication.armed = true
    publishDeadline.arm(afterMs: coalescingWindowMs) { [weak self] in
      guard let self else { return }
      self.publication.armed = false
      // The last stream may have closed meanwhile: the cache stays stale.
      guard self.publication.stale, self.publication.streams > 0, !self.publication.stopped
      else { return }
      self.publishState()
    }
  }

  /// Take a snapshot now, on main — `stateProvider` reads main-only app state
  /// — and hand the immutable value to `queue` to cache and push. Main
  /// enqueues both this and the stale marks, so the queue applies them in
  /// the order main saw them.
  private func publishState() {
    dispatchPrecondition(condition: .onQueue(.main))
    publication.stale = false
    let snapshot = stateProvider()
    queue.async { [weak self] in
      guard let self else { return }
      self.cachedState = snapshot
      self.cachedStateIsCurrent = true
      self.broadcast(event: "state", object: snapshot)
    }
  }

  /// Runs on `queue`. A current cache answers at once; a stale one, or an
  /// explicit `?refresh=1` — the way to resample values no event reports,
  /// such as plugin memory — hops to main for a fresh snapshot, which every
  /// open stream receives too.
  private func sendState(refresh: Bool, connection: NWConnection) {
    guard refresh || !cachedStateIsCurrent else {
      return sendJSON(cachedState, connection: connection)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return connection.cancel() }
      if refresh || self.publication.stale { self.publishState() }
      self.queue.async { self.sendJSON(self.cachedState, connection: connection) }
    }
  }

  private func append(_ record: FlashLog.Record) {
    queue.async { [weak self] in
      guard let self else { return }
      let object = record.jsonObject
      self.logs.append(object)
      if self.logs.count > self.maxLogs {
        self.logs.removeFirst(self.logs.count - self.maxLogs)
      }
      self.broadcast(event: "log", object: object)
    }
  }

  static func dashboardURL(host: String, port: UInt16, page: Page) -> URL? {
    guard parse(host: host, port: Int(port)) != nil else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host == "::1" ? "[::1]" : host
    components.port = Int(port)
    components.percentEncodedPath = page.path
    return components.url
  }

  private func handle(_ connection: NWConnection) {
    guard Self.isLoopback(endpoint: connection.endpoint) else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    readRequest(connection, buffer: Data())
  }

  /// Headers plus `Content-Length` bytes, capped so a Save can carry a real
  /// config. A GET with no length is complete at the header break. An empty
  /// chunk that has not ended the connection is not the end of the request.
  static let maxRequestBytes = 256 * 1024

  enum AssembledRequest: Equatable {
    case incomplete
    case tooLarge
    case ready(headers: String, body: Data)
  }

  static func assembleRequest(_ data: Data) -> AssembledRequest {
    if data.count > maxRequestBytes { return .tooLarge }
    let marker = Data([13, 10, 13, 10])
    guard let range = data.range(of: marker) else { return .incomplete }
    let headerData = data.subdata(in: 0..<range.lowerBound)
    guard let headers = String(data: headerData, encoding: .utf8) else { return .tooLarge }
    let body = data.subdata(in: range.upperBound..<data.endIndex)
    guard let length = contentLength(in: headers) else {
      return .ready(headers: headers, body: Data())
    }
    if length < 0 || range.upperBound + length > maxRequestBytes { return .tooLarge }
    if body.count < length { return .incomplete }
    return .ready(headers: headers, body: Data(body.prefix(length)))
  }

  static func contentLength(in headers: String) -> Int? {
    for line in headers.split(whereSeparator: \.isNewline) {
      guard line.lowercased().hasPrefix("content-length:") else { continue }
      let raw = line.dropFirst("content-length:".count)
        .trimmingCharacters(in: .whitespaces)
      return Int(raw)
    }
    return nil
  }

  private func readRequest(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
      [weak self] data, _, isComplete, _ in
      guard let self else {
        connection.cancel()
        return
      }
      var buffer = buffer
      if let data, !data.isEmpty { buffer.append(data) }
      switch Self.assembleRequest(buffer) {
      case .ready(let headers, let body):
        self.respond(headers: headers, body: body, connection: connection)
      case .tooLarge:
        self.sendText("payload too large", status: "413 Payload Too Large", connection: connection)
      case .incomplete:
        guard !isComplete else {
          connection.cancel()
          return
        }
        self.readRequest(connection, buffer: buffer)
      }
    }
  }

  private func respond(headers: String, body: Data, connection: NWConnection) {
    // A loopback peer is not enough: a web page can rebind its own hostname
    // to 127.0.0.1 and read /api/state (clipboard, hints) and /api/logs through the
    // victim's browser. That request carries the attacker's hostname.
    guard Self.hostIsLoopback(request: headers, port: listeningPort) else {
      FlashLog.warn("[debug] http inspector refused a request for a foreign host")
      sendText("forbidden", status: "403 Forbidden", connection: connection)
      return
    }
    switch Self.route(path: Self.requestPath(headers)) {
    case .app(let found):
      sendHTML(found: found, connection: connection)
    case .state:
      sendState(refresh: Self.queryValue("refresh", in: headers) == "1", connection: connection)
    case .logs:
      let trace = Self.queryValue("trace", in: headers)
      let logs = trace.map { id in self.logs.filter { $0["trace"] as? String == id } } ?? self.logs
      sendJSON(["logs": logs], connection: connection)
    case .traces:
      sendJSON(["traces": Self.traceSummaries(self.logs)], connection: connection)
    case .events:
      startEvents(connection)
    case .clipboardItem(let id):
      serveClipboardItem(id, request: headers, connection: connection)
    case .config:
      serveConfig(purge: false, request: headers, body: body, connection: connection)
    case .configPurge:
      serveConfig(purge: true, request: headers, body: body, connection: connection)
    case .missingEndpoint:
      sendText("not found", status: "404 Not Found", connection: connection)
    }
  }

  private func serveConfig(purge: Bool, request: String, body: Data, connection: NWConnection) {
    let method = Self.requestMethod(request)
    let allowed = purge ? method == "POST" : method == "GET" || method == "PUT"
    guard allowed else {
      sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
      return
    }
    guard let configHTTP else {
      sendText("unavailable", status: "503 Service Unavailable", connection: connection)
      return
    }
    configHTTP(method, purge, body) { [weak self] status, contentType, body in
      guard let self else { return }
      self.queue.async {
        self.sendBytes(body, status: status, contentType: contentType, connection: connection)
      }
    }
  }

  /// Every page path receives the same single-page app, which renders its own
  /// view (including "not found") from the URL; only the status differs.
  private func sendHTML(found: Bool, connection: NWConnection) {
    send(
      Self.response(
        body: Self.pageHTML,
        status: found ? "200 OK" : "404 Not Found",
        contentType: "text/html; charset=utf-8"),
      connection: connection,
      close: true)
  }

  /// The inspector UI is a Svelte app built in `Inspector/` and shipped as
  /// one self-contained HTML file. A dev install replaces the copy inside
  /// the app bundle after SwiftPM has already copied the committed resource
  /// into the build directory. The generated `Bundle.module` lookup misses
  /// `Contents/Resources` and then reads that build directory, so the app
  /// copy has to win. Loaded once and cached.
  private static let pageHTML: String = inspectorPage(
    appCopy: Bundle.main.resourceURL?
      .appendingPathComponent("Flash_flash.bundle/inspector.html"),
    moduleCopy: Bundle.module.url(forResource: "inspector", withExtension: "html"))

  static func inspectorPage(appCopy: URL?, moduleCopy: URL?) -> String {
    for url in [appCopy, moduleCopy].compactMap({ $0 }) {
      if let html = try? String(contentsOf: url, encoding: .utf8), !html.isEmpty {
        return html
      }
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"><title>Flash Inspector</title></head>
      <body style="font-family: ui-monospace, monospace; background:#101214; color:#e7edf3; padding:24px">
      <h1>Flash Inspector</h1>
      <p>UI bundle missing. Run <code>Scripts/build-inspector.sh</code> and rebuild.</p>
      </body></html>
      """
  }

  private func sendJSON(_ object: Any, connection: NWConnection) {
    let body = Self.jsonString(object)
    send(
      Self.response(body: body, contentType: "application/json; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func serveClipboardItem(_ id: String, request: String, connection: NWConnection) {
    let method = Self.requestMethod(request)
    guard method == "GET" || method == "DELETE" else {
      sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
      return
    }
    guard let clipboardHTTP else {
      sendText("unavailable", status: "503 Service Unavailable", connection: connection)
      return
    }
    clipboardHTTP(method, id) { [weak self] status, contentType, body in
      guard let self else { return }
      self.queue.async {
        self.sendBytes(body, status: status, contentType: contentType, connection: connection)
      }
    }
  }

  private func sendBytes(
    _ body: Data, status: String, contentType: String, connection: NWConnection
  ) {
    let type =
      contentType.contains(where: \.isNewline) ? "application/octet-stream" : contentType
    let header =
      [
        "HTTP/1.1 \(status)",
        "Content-Type: \(type)",
        "Content-Length: \(body.count)",
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
      ].joined(separator: "\r\n") + "\r\n\r\n"
    var bytes = Data(header.utf8)
    bytes.append(body)
    connection.send(
      content: bytes,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private func sendText(_ text: String, status: String, connection: NWConnection) {
    send(
      Self.response(body: text, status: status, contentType: "text/plain; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func startEvents(_ connection: NWConnection) {
    guard !stopped else { return connection.cancel() }
    let id = UUID()
    eventConnections[id] = connection
    DispatchQueue.main.async { [weak self] in self?.streamsDidChange(by: 1) }
    // A multiline string drops the newline before its closing delimiter, so
    // the blank line has to be an ordinary string. A bare CR here makes
    // strict clients reject the stream and the inspector stays disconnected.
    let headers =
      "HTTP/1.1 200 OK\r\n"
      + "Content-Type: text/event-stream\r\n"
      + "Cache-Control: no-cache\r\n"
      + "Connection: keep-alive\r\n"
      + "\r\n"
    send(headers, connection: connection, close: false)
    // A stale cache is not sent: the publish this stream arms delivers the
    // current state instead.
    if cachedStateIsCurrent { sendEvent("state", object: cachedState, connection: connection) }
    sendEvent("logs", object: ["logs": logs], connection: connection)
    // Handlers run on `queue`, where the connection was started.
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled:
        guard let self, self.eventConnections.removeValue(forKey: id) != nil else { return }
        DispatchQueue.main.async { self.streamsDidChange(by: -1) }
      case .failed:
        connection.cancel()
      default:
        break
      }
    }
    awaitClose(connection)
  }

  /// An event-stream client sends nothing after its request, so the next
  /// receive completes only when it goes away: that is the disconnect.
  private func awaitClose(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] _, _, isComplete, error in
      guard !isComplete, error == nil else { return connection.cancel() }
      self?.awaitClose(connection)
    }
  }

  private func broadcast(event: String, object: Any) {
    for connection in eventConnections.values {
      sendEvent(event, object: object, connection: connection)
    }
  }

  private func sendEvent(_ event: String, object: Any, connection: NWConnection) {
    let payload = "event: \(event)\ndata: \(Self.jsonString(object))\n\n"
    send(payload, connection: connection, close: false)
  }

  private func send(_ text: String, connection: NWConnection, close: Bool) {
    connection.send(
      content: text.data(using: .utf8),
      completion: .contentProcessed { _ in
        if close {
          connection.cancel()
        }
      })
  }

  private static func response(
    body: String,
    status: String = "200 OK",
    contentType: String
  ) -> String {
    let length = body.data(using: .utf8)?.count ?? 0
    return """
      HTTP/1.1 \(status)\r
      Content-Type: \(contentType)\r
      Content-Length: \(length)\r
      Cache-Control: no-cache\r
      \r
      \(body)
      """
  }

  /// The request's `Host` header names this loopback listener: 127.0.0.1,
  /// localhost or [::1], on its own port.
  static func hostIsLoopback(request: String, port: UInt16?) -> Bool {
    let header = request.split(whereSeparator: \.isNewline).dropFirst().first { line in
      line.lowercased().hasPrefix("host:")
    }
    guard let header else { return false }
    let value = header.dropFirst("host:".count).trimmingCharacters(in: .whitespaces).lowercased()
    for name in ["127.0.0.1", "localhost", "[::1]"] {
      if value == name { return port == 80 }
      if let port, value == "\(name):\(port)" { return true }
    }
    return false
  }

  /// Recent interactions (`Trace`), newest first: when each began and last
  /// logged, how many lines it produced, its worst level, and which host and
  /// plugin sources took part — the index into `/api/logs?trace=`.
  static func traceSummaries(_ logs: [[String: Any]]) -> [[String: Any]] {
    struct Summary {
      var origin = ""
      var first = Int64.max
      var last = Int64.min
      var lines = 0
      var worst = FlashLog.Level.trace
      var sources: [String] = []
    }
    var summaries: [String: Summary] = [:]
    for log in logs {
      guard let trace = log["trace"] as? String else { continue }
      var summary = summaries[trace] ?? Summary()
      let time = (log["time_unix_ms"] as? Int64) ?? Int64(log["time_unix_ms"] as? Int ?? 0)
      summary.first = min(summary.first, time)
      summary.last = max(summary.last, time)
      summary.lines += 1
      if let level = (log["level"] as? String).flatMap(FlashLog.Level.parse), level > summary.worst
      {
        summary.worst = level
      }
      if log["message"] as? String == "[trace] begin",
        let origin = (log["fields"] as? [String: String])?["origin"]
      {
        summary.origin = origin
      }
      if let source = log["source"] as? String {
        let owner = source.hasPrefix("plugin:") ? source : "core"
        if !summary.sources.contains(owner) { summary.sources.append(owner) }
      }
      summaries[trace] = summary
    }
    return summaries.sorted { $0.value.first > $1.value.first }.prefix(200).map { trace, summary in
      [
        "trace": trace,
        "origin": summary.origin,
        "started_unix_ms": summary.first,
        "duration_ms": summary.last - summary.first,
        "lines": summary.lines,
        "worst_level": summary.worst.name,
        "sources": summary.sources,
      ]
    }
  }

  static func queryValue(_ name: String, in request: String) -> String? {
    let first = request.split(separator: "\n", maxSplits: 1).first ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2,
      let query = parts[1].split(separator: "?", maxSplits: 1).dropFirst().first
    else { return nil }
    for pair in query.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.first == Substring(name), kv.count == 2 {
        return String(kv[1]).removingPercentEncoding
      }
    }
    return nil
  }

  /// How the server answers a request path. Data endpoints live under
  /// `/api/`; every other path belongs to the help app, found or not.
  enum Route: Equatable {
    case app(found: Bool)
    case state
    case logs
    case traces
    case events
    case clipboardItem(id: String)
    case config
    case configPurge
    case missingEndpoint
  }

  static func route(path: String) -> Route {
    switch path {
    case "/api/state": return .state
    case "/api/logs": return .logs
    case "/api/traces": return .traces
    case "/api/events": return .events
    case "/api/config": return .config
    case "/api/config/purge": return .configPurge
    default:
      if let id = clipboardItemID(path: path) { return .clipboardItem(id: id) }
      if path == "/api" || path.hasPrefix("/api/") { return .missingEndpoint }
      return .app(found: Page(path: path) != nil)
    }
  }

  /// `/api/clipboard/<32 lowercase hex>` is one history entry. Anything else
  /// under `/api/` stays missing, so a crafted id cannot escape that shape.
  static func clipboardItemID(path: String) -> String? {
    let prefix = "/api/clipboard/"
    guard path.hasPrefix(prefix) else { return nil }
    let id = path.dropFirst(prefix.count)
    guard id.utf8.count == 32,
      id.utf8.allSatisfy({ byte in (48...57).contains(byte) || (97...102).contains(byte) })
    else { return nil }
    return String(id)
  }

  static func requestMethod(_ request: String) -> String {
    let line = request.split(whereSeparator: \.isNewline).first ?? ""
    return String(line.split(separator: " ").first ?? "GET").uppercased()
  }

  private static func requestPath(_ request: String) -> String {
    let first = request.split(separator: "\n", maxSplits: 1).first ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return "/" }
    return String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
  }

  private static func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  /// Validates a configured `(host, port)` pair before binding. Allows
  /// `port == 0` for "let the OS pick" (used by tests). The user-facing
  /// config validation in `ConfigLoader` is stricter (`1..65535`).
  static func parse(host: String, port: Int) -> (host: String, port: NWEndpoint.Port)? {
    guard ["localhost", "127.0.0.1", "::1"].contains(host),
      (0...65535).contains(port),
      let endpointPort = NWEndpoint.Port(rawValue: UInt16(port))
    else { return nil }
    return (host, endpointPort)
  }

  static func isLoopback(endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .name(let name, _):
      return name == "localhost"
    case .ipv4(let address):
      return address.rawValue.first == 127
    case .ipv6(let address):
      return address == IPv6Address("::1")
    default:
      return false
    }
  }
}

extension DebugServer {
  /// A page of the browser help app. The app routes itself with the History
  /// API; the server recognizes the same paths so a direct load or reload of
  /// any page receives the app. `Inspector/src/lib/routes.ts` mirrors this
  /// table: `/`, `/docs[/<topic>]`, `/mappings`, `/commands`,
  /// `/plugins[/<id>]`, `/state`, `/logs`, `/clipboard` and
  /// `/search`. Fragments stay free for in-page anchors.
  enum Page: Equatable {
    case home
    case docs(topic: String?)
    case mappings
    case commands
    case plugins(id: String?)
    case state
    case logs
    case clipboard
    /// Search results across guides, commands, mappings and plugins; the
    /// query travels in `?q=` so a search can be reloaded and shared.
    case search

    /// Pages that accept one detail segment, such as a topic or plugin id.
    private static let detailPages: Set<String> = ["docs", "plugins"]
    private static let pages: Set<String> = [
      "docs", "mappings", "commands", "plugins", "state", "logs", "clipboard",
      "search",
    ]
    /// RFC 3986 unreserved characters: everything else in a detail segment,
    /// including `/`, `?` and `#`, is percent-encoded.
    private static let segmentCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The percent-encoded absolute path of the page.
    var path: String {
      switch self {
      case .home: return "/"
      case .docs(let topic): return Self.path("docs", detail: topic)
      case .mappings: return "/mappings"
      case .commands: return "/commands"
      case .plugins(let id): return Self.path("plugins", detail: id)
      case .state: return "/state"
      case .logs: return "/logs"
      case .clipboard: return "/clipboard"
      case .search: return "/search"
      }
    }

    /// Parses a percent-encoded request path without its query.
    init?(path: String) {
      guard path.hasPrefix("/") else { return nil }
      let segments = path.split(separator: "/").map(String.init)
      guard let head = segments.first else {
        self = .home
        return
      }
      guard Self.pages.contains(head), segments.count <= (Self.detailPages.contains(head) ? 2 : 1)
      else { return nil }
      var detail: String?
      if segments.count == 2 {
        guard let decoded = segments[1].removingPercentEncoding else { return nil }
        detail = decoded
      }
      switch head {
      case "docs": self = .docs(topic: detail)
      case "mappings": self = .mappings
      case "commands": self = .commands
      case "plugins": self = .plugins(id: detail)
      case "state": self = .state
      case "logs": self = .logs
      case "search": self = .search
      default: self = .clipboard
      }
    }

    private static func path(_ name: String, detail: String?) -> String {
      guard let detail = detail?.trimmed, !detail.isEmpty,
        let encoded = detail.addingPercentEncoding(withAllowedCharacters: segmentCharacters)
      else { return "/\(name)" }
      return "/\(name)/\(encoded)"
    }
  }
}
