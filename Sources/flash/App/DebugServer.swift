import Foundation
import Network

final class DebugServer {
  let host: String
  let port: Int
  private(set) var listeningPort: UInt16?
  private let stateProvider: () -> [String: Any]
  private let queue = DispatchQueue(label: "flash.debug_server", qos: .utility)
  private var listener: NWListener?
  private var logSinkID: UUID?
  private var logs: [[String: Any]] = []
  private var eventConnections: [UUID: NWConnection] = [:]
  /// Last app-state snapshot — taken on the main thread, then confined to
  /// `queue`. The server serves this on `/state` and `/events` rather than
  /// calling `stateProvider` on its own queue (which raced the main thread, the
  /// data race this fixes — and a synchronous main hop would instead deadlock if
  /// a caller blocks main, as the test harness does). Seeded in `start()` and
  /// refreshed by `broadcastState()` and the state timer.
  private var cachedState: [String: Any] = [:]
  private let maxLogs = 2_000

  init(host: String, port: Int, stateProvider: @escaping () -> [String: Any]) {
    self.host = host
    self.port = port
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
        if case .ready = state {
          let port = listener.port?.rawValue
          self?.listeningPort = port
          FlashLog.info("[debug] http inspector listening http://\(endpoint.host):\(port ?? 0)")
        }
        if case .failed(let error) = state {
          FlashLog.warn("[debug] http inspector failed \(error)")
        }
      }
      // Seed the cache on the main thread (start() runs on main) so the first
      // /state request returns data before any broadcast/timer refresh fires.
      let initialState = stateProvider()
      queue.async { [weak self] in self?.cachedState = initialState }
      listener.start(queue: queue)
      self.listener = listener
      startStateTimer()
      // Follows `[debug] log_level`: the inspector shows what the log file
      // gets, and never forces lower-level messages on hot paths to be built.
      logSinkID = FlashLog.addSink(minLevel: nil) { [weak self] record in
        self?.append(record)
      }
    } catch {
      FlashLog.warn("[debug] could not start http inspector \(host):\(port): \(error)")
    }
  }

  func stop() {
    if let logSinkID {
      FlashLog.removeSink(logSinkID)
    }
    logSinkID = nil
    PollScheduler.shared.unregister(Self.pollClientID)
    listener?.cancel()
    listener = nil
    for connection in eventConnections.values {
      connection.cancel()
    }
    eventConnections.removeAll()
  }

  /// Refresh the cache and push state to subscribers. Must be called on the main
  /// thread — `stateProvider` reads main-only app state (mode, overlay input,
  /// clipboard, frontmost app, plugin statuses). The snapshot is taken here, on
  /// main, then the immutable value is handed to `queue`.
  func broadcastState() {
    let snapshot = stateProvider()
    queue.async { [weak self] in
      guard let self else { return }
      self.cachedState = snapshot
      self.broadcast(event: "state", object: snapshot)
    }
  }

  /// Refresh the cached snapshot from the main thread, then broadcast it. Async,
  /// so a busy/blocked main thread only delays the refresh — it can never
  /// deadlock the server queue the way a synchronous main hop would.
  private func refreshStateFromMain() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let snapshot = self.stateProvider()
      self.queue.async {
        self.cachedState = snapshot
        self.broadcast(event: "state", object: snapshot)
      }
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

  /// The inspector page is a debug surface with no change notification of its
  /// own, so it refreshes on a cadence — registered with the shared clock like
  /// everything else, and only while a browser is actually listening.
  private func startStateTimer() {
    PollScheduler.shared.register(
      Self.pollClientID, everyMs: 1000, priority: .low, on: queue
    ) { [weak self] in
      guard let self, !self.eventConnections.isEmpty else { return }
      self.refreshStateFromMain()
    }
  }

  static let pollClientID = "core:debug_inspector"

  private func handle(_ connection: NWConnection) {
    guard Self.isLoopback(endpoint: connection.endpoint) else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, _, _ in
      guard let self else {
        connection.cancel()
        return
      }
      guard let data, let request = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
      }
      // A loopback peer is not enough: a web page can rebind its own hostname
      // to 127.0.0.1 and read /state (clipboard, hints) and /logs through the
      // victim's browser. That request carries the attacker's hostname.
      guard Self.hostIsLoopback(request: request, port: self.listeningPort) else {
        FlashLog.warn("[debug] http inspector refused a request for a foreign host")
        self.sendText("forbidden", status: "403 Forbidden", connection: connection)
        return
      }
      let path = Self.requestPath(request)
      switch path {
      case "/":
        self.sendHTML(connection)
      case "/state":
        self.sendJSON(self.cachedState, connection: connection)
      case "/logs":
        let trace = Self.queryValue("trace", in: request)
        let logs =
          trace.map { id in self.logs.filter { $0["trace"] as? String == id } } ?? self.logs
        self.sendJSON(["logs": logs], connection: connection)
      case "/traces":
        self.sendJSON(["traces": Self.traceSummaries(self.logs)], connection: connection)
      case "/events":
        self.startEvents(connection)
      default:
        self.sendText("not found", status: "404 Not Found", connection: connection)
      }
    }
  }

  private func sendHTML(_ connection: NWConnection) {
    send(
      Self.response(
        body: Self.pageHTML,
        contentType: "text/html; charset=utf-8"),
      connection: connection,
      close: true)
  }

  /// The inspector UI is a Svelte app built in `Inspector/` and shipped as
  /// a single self-contained HTML resource (`Scripts/build-inspector.sh`
  /// regenerates it). Loaded once and cached; the fallback only fires if
  /// the resource is somehow missing from the bundle.
  private static let pageHTML: String = {
    if let url = Bundle.module.url(forResource: "inspector", withExtension: "html"),
      let html = try? String(contentsOf: url, encoding: .utf8)
    {
      return html
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"><title>Flash Inspector</title></head>
      <body style="font-family: ui-monospace, monospace; background:#101214; color:#e7edf3; padding:24px">
      <h1>Flash Inspector</h1>
      <p>UI bundle missing. Run <code>Scripts/build-inspector.sh</code> and rebuild.</p>
      </body></html>
      """
  }()

  private func sendJSON(_ object: Any, connection: NWConnection) {
    let body = Self.jsonString(object)
    send(
      Self.response(body: body, contentType: "application/json; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func sendText(_ text: String, status: String, connection: NWConnection) {
    send(
      Self.response(body: text, status: status, contentType: "text/plain; charset=utf-8"),
      connection: connection,
      close: true)
  }

  private func startEvents(_ connection: NWConnection) {
    let id = UUID()
    eventConnections[id] = connection
    let headers = """
      HTTP/1.1 200 OK\r
      Content-Type: text/event-stream\r
      Cache-Control: no-cache\r
      Connection: keep-alive\r
      \r
      """
    send(headers, connection: connection, close: false)
    sendEvent("state", object: cachedState, connection: connection)
    sendEvent("logs", object: ["logs": logs], connection: connection)
    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state {
        self?.queue.async {
          self?.eventConnections.removeValue(forKey: id)
        }
      }
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
  /// plugin sources took part — the index into `/logs?trace=`.
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
