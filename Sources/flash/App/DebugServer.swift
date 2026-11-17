import CryptoKit
import FlashCore
import Foundation
import Network

final class DebugServer {
  let host: String
  let port: Int
  /// The secret every data endpoint requires (`HelpAccess`): the loopback
  /// address is shared by every account and process on the Mac.
  private let accessToken: String
  /// How long a connection may take to send its whole request.
  private let requestDeadlineMs: Int
  /// Connections still sending their request, on `queue`: each owes it
  /// before its deadline, and past `maxAwaitingRequests` a new one is closed,
  /// so a process holding connections open cannot use up Flash's descriptors.
  private var awaitingRequests: Set<UUID> = []
  static let maxAwaitingRequests = 32
  /// On `queue`; read from elsewhere through `whenListening`.
  private(set) var listeningPort: UInt16?
  /// `GET` and `DELETE /api/clipboard/<id>`. Nil answers those routes with
  /// 503. Invoked on the server queue; the completion may run on any queue.
  typealias ClipboardHTTPHandler = (
    _ method: String, _ id: String,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void
  /// `PUT` (pin) and `DELETE` (unpin) `/api/clipboard/<id>/pin`. Nil
  /// answers 503. Invoked on the server queue; the completion may run on any
  /// queue.
  typealias ClipboardPinHTTPHandler = (
    _ pinned: Bool, _ id: String,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void
  /// `GET /api/clipboard/history?offset=N`, one bounded page at a time.
  typealias ClipboardHistoryHTTPHandler = (
    _ offset: Int,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void
  /// `GET`/`PUT /api/config` and `POST /api/config/purge`. Nil answers 503.
  /// Invoked on the server queue; the completion may run on any queue.
  typealias ConfigHTTPHandler = (
    _ method: String, _ purge: Bool, _ body: Data,
    _ completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) -> Void

  /// `GET /api/telemetry`: the received metrics, logs and spans. Invoked on
  /// the server queue; it must not wait on main. Nil answers 503.
  typealias TelemetryHTTPHandler = () -> [String: Any]

  private let stateProvider: () -> [String: Any]
  /// Rebuilds only the named top-level sections, for a change that touched
  /// nothing else (`stateDidChange(.sections(...))`); main thread. Nil
  /// rebuilds the whole state for every change.
  private let sectionsProvider: ((Set<String>) -> [String: Any])?
  private let telemetryHTTP: TelemetryHTTPHandler?
  /// The manual the build bundled (`Contents/Resources/docs`): `docs.json`,
  /// `search.json` and `files/`. Read on `queue`, never on main.
  private let docsRoot: URL?
  private let clipboardHTTP: ClipboardHTTPHandler?
  private let clipboardPinHTTP: ClipboardPinHTTPHandler?
  private let clipboardHistoryHTTP: ClipboardHistoryHTTPHandler?
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
  /// User-initiated: a browser waits on every reply, and under CPU load the
  /// kernel starves utility threads first (`docs/performance.md`).
  private let queue = DispatchQueue(label: "flash.debug_server", qos: .userInitiated)
  private var listener: NWListener?
  private var logSinkID: UUID?
  private var logs: [[String: Any]] = []
  /// Each record of `logs` encoded once, as it arrived: `/api/logs` and a new
  /// stream join these instead of encoding every record again.
  private var encodedLogs: [Data] = []
  private var eventConnections: [UUID: NWConnection] = [:]
  /// Streams that opened on a stale cache and have no state yet: the next
  /// snapshot reaches them whole, every other stream as a patch.
  private var streamsAwaitingState: Set<UUID> = []
  /// Bytes each event stream was handed and the network stack has not yet
  /// taken; on `queue`, where every connection runs.
  private var eventBacklogs: [UUID: Int] = [:]
  /// Queue-confined. The listener's outcome: nil while it is still binding.
  private var readiness: ListenerReadiness?
  /// Queue-confined callers of `whenListening` waiting for that outcome.
  private var readinessWaiters: [UUID: (UInt16?) -> Void] = [:]
  private var stopped = false

  private enum ListenerReadiness {
    case listening(UInt16)
    case failed
  }
  /// Last app-state snapshot, encoded — taken on the main thread, encoded
  /// and confined to `queue`. The server serves this on `/api/state` and
  /// `/api/events` rather than calling `stateProvider` on its own queue
  /// (which raced the main thread — and a synchronous main hop would instead
  /// deadlock if a caller blocks main, as the test harness does). Seeded in
  /// `start()` and replaced by each publish.
  private var encodedState = EncodedState.empty
  /// Queue-confined mirror of `publication.stale`, in main's order: whether
  /// `encodedState` still reflects every change main has reported.
  private var cachedStateIsCurrent = true
  /// Main-confined: what the pushed state owes its readers.
  private(set) var publication = Publication()
  /// Main-confined: the last snapshot, which a scoped one updates, and its number.
  private var latestSnapshot: [String: Any] = [:]
  private var snapshotSeq = 0
  private let maxLogs = 2_000

  /// Main-confined publication state. The inspector has no clock: app
  /// changes call `stateDidChange`, and a snapshot is taken only when someone
  /// can read it — once per coalescing window while a browser holds an event
  /// stream, or when a request finds the cache stale.
  struct Publication: Equatable {
    /// Event streams open, mirrored from `queue`.
    var streams = 0
    /// What changed since the last snapshot; nil while it is current.
    var pending: StateScope?
    /// A coalesced publish is waiting out its window.
    var armed = false
    var stopped = false

    /// A change arrived since the last snapshot.
    var stale: Bool { pending != nil }
  }

  /// What a change touched, so the next snapshot rebuilds no more than that.
  enum StateScope: Equatable {
    /// Only these top-level sections (the status bar's, a widget's): the
    /// next snapshot rebuilds them and keeps the rest of the last one.
    case sections(Set<String>)
    case all

    func union(_ other: StateScope) -> StateScope {
      guard case .sections(let mine) = self, case .sections(let theirs) = other else { return .all }
      return .sections(mine.union(theirs))
    }
  }

  init(
    host: String, port: Int, accessToken: String, requestDeadlineMs: Int = 10_000,
    coalescingWindowMs: Int = 100,
    clipboardHTTP: ClipboardHTTPHandler? = nil,
    clipboardPinHTTP: ClipboardPinHTTPHandler? = nil,
    clipboardHistoryHTTP: ClipboardHistoryHTTPHandler? = nil,
    configHTTP: ConfigHTTPHandler? = nil,
    telemetryHTTP: TelemetryHTTPHandler? = nil,
    docsRoot: URL? = DebugServer.bundledDocs,
    sectionsProvider: ((Set<String>) -> [String: Any])? = nil,
    stateProvider: @escaping () -> [String: Any]
  ) {
    self.telemetryHTTP = telemetryHTTP
    self.host = host
    self.port = port
    self.accessToken = accessToken
    self.requestDeadlineMs = requestDeadlineMs
    self.coalescingWindowMs = coalescingWindowMs
    self.docsRoot = docsRoot
    self.clipboardHTTP = clipboardHTTP
    self.clipboardPinHTTP = clipboardPinHTTP
    self.clipboardHistoryHTTP = clipboardHistoryHTTP
    self.configHTTP = configHTTP
    self.stateProvider = stateProvider
    self.sectionsProvider = sectionsProvider
  }

  func start() {
    guard let endpoint = Self.parse(host: host, port: port) else {
      FlashLog.warn("[debug] invalid http_inspector_host/port \(host):\(port)")
      return
    }
    do {
      // Bind the socket to the loopback address itself. An interface
      // restriction alone still listens on every address (`*:<port>`) and
      // only refuses what arrives elsewhere; the per-connection `isLoopback`
      // check and the Host check stay as defense in depth.
      let parameters: NWParameters = .tcp
      parameters.requiredInterfaceType = .loopback
      parameters.requiredLocalEndpoint = .hostPort(
        host: Self.bindAddress(host: endpoint.host), port: endpoint.port)
      let listener = try NWListener(using: parameters)
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
      FlashLog.error("[debug] could not start http inspector \(host):\(port): \(error)")
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
      eventBacklogs.removeAll()
      streamsAwaitingState.removeAll()
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
  /// or stream takes a fresh snapshot. A change that names its sections
  /// rebuilds only those when the burst is all such changes.
  func stateDidChange(_ scope: StateScope = .all) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !publication.stopped else { return }
    if let pending = publication.pending {
      publication.pending = pending.union(scope)
    } else {
      publication.pending = scope
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

  /// Take a snapshot now, on main — the providers read main-only app state
  /// — and hand the immutable value to `queue` to encode, cache and push.
  /// A scoped change rebuilds only its sections over the last snapshot;
  /// `everything` (start, `?refresh=1`) rebuilds it all, resampling what no
  /// event reports. Main enqueues both this and the stale marks, so the
  /// queue applies them in the order main saw them.
  private func publishState(everything: Bool = false) {
    dispatchPrecondition(condition: .onQueue(.main))
    let scope = everything ? .all : (publication.pending ?? .all)
    publication.pending = nil
    var snapshot: [String: Any]
    if case .sections(let keys) = scope, let sectionsProvider, !latestSnapshot.isEmpty {
      snapshot = latestSnapshot
      snapshot.merge(sectionsProvider(keys)) { _, rebuilt in rebuilt }
    } else {
      snapshot = stateProvider()
    }
    snapshotSeq += 1
    snapshot["snapshot_seq"] = snapshotSeq
    latestSnapshot = snapshot
    let seq = snapshotSeq
    queue.async { [weak self] in
      guard let self else { return }
      let previous = self.encodedState
      self.encodedState = EncodedState(snapshot, seq: seq)
      self.cachedStateIsCurrent = true
      self.broadcastState(previous: previous)
    }
  }

  /// Runs on `queue`. A current cache answers at once; a stale one, or an
  /// explicit `?refresh=1` — the way to resample values no event reports,
  /// such as plugin memory — hops to main for a fresh snapshot, which every
  /// open stream receives too.
  private func sendState(refresh: Bool, connection: NWConnection) {
    guard refresh || !cachedStateIsCurrent else {
      return sendJSON(encodedState.document, connection: connection)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return connection.cancel() }
      if refresh || self.publication.stale { self.publishState(everything: refresh) }
      self.queue.async { self.sendJSON(self.encodedState.document, connection: connection) }
    }
  }

  private func append(_ record: FlashLog.Record) {
    queue.async { [weak self] in
      guard let self else { return }
      let object = record.jsonObject
      let encoded = Self.jsonData(object) ?? Data("{}".utf8)
      self.logs.append(object)
      self.encodedLogs.append(encoded)
      if self.logs.count > self.maxLogs {
        self.logs.removeFirst(self.logs.count - self.maxLogs)
        self.encodedLogs.removeFirst(self.encodedLogs.count - self.maxLogs)
      }
      self.broadcast(Self.eventFrame("log", data: encoded))
    }
  }

  /// `{"logs":[…]}` from encoded records.
  static func logsDocument(_ records: [Data]) -> Data {
    var document = Data(#"{"logs":["#.utf8)
    for (index, record) in records.enumerated() {
      if index > 0 { document.append(UInt8(ascii: ",")) }
      document.append(record)
    }
    document.append(contentsOf: Array("]}".utf8))
    return document
  }

  /// The address Flash opens: the page, carrying the access token once. The
  /// page keeps it (per origin, so per port) and drops it from the address.
  static func dashboardURL(host: String, port: UInt16, page: Page, token: String) -> URL? {
    guard parse(host: host, port: Int(port)) != nil else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host == "::1" ? "[::1]" : host
    components.port = Int(port)
    components.percentEncodedPath = page.path
    components.queryItems = [URLQueryItem(name: HelpAccess.queryName, value: token)]
    return components.url
  }

  /// Whether `request` carries the access token: `Authorization: Bearer`,
  /// or `?token=` for what cannot set a header (an event stream, an image).
  static func isAuthorized(request: String, token: String) -> Bool {
    for line in request.split(whereSeparator: \.isNewline).dropFirst() {
      let lower = line.lowercased()
      guard lower.hasPrefix("authorization:") else { continue }
      let value = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
      guard value.lowercased().hasPrefix("bearer ") else { return false }
      return HelpAccess.matches(
        String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces), token)
    }
    guard let candidate = queryValue(HelpAccess.queryName, in: request) else { return false }
    return HelpAccess.matches(candidate, token)
  }

  private func handle(_ connection: NWConnection) {
    guard Self.isLoopback(endpoint: connection.endpoint) else {
      connection.cancel()
      return
    }
    guard awaitingRequests.count < Self.maxAwaitingRequests else {
      connection.cancel()
      return
    }
    let request = UUID()
    awaitingRequests.insert(request)
    connection.start(queue: queue)
    // A timeout bounding one operation: the request arrives whole, or the
    // connection goes.
    queue.asyncAfter(deadline: .now() + .milliseconds(requestDeadlineMs)) { [weak self] in
      guard let self, self.awaitingRequests.remove(request) != nil else { return }
      connection.cancel()
    }
    readRequest(connection, request: request, buffer: Data())
  }

  /// Headers plus `Content-Length` bytes, capped so a Save can carry a real
  /// config. A GET with no length is complete at the header break. An empty
  /// chunk that has not ended the connection is not the end of the request.
  static let maxRequestBytes = 256 * 1024
  /// Bytes an event stream may have handed to its connection and not yet
  /// had accepted by the network stack before it is dropped.
  static let maxStreamBacklogBytes = 8 * 1024 * 1024

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

  private func readRequest(_ connection: NWConnection, request: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
      [weak self] data, _, isComplete, _ in
      guard let self else {
        connection.cancel()
        return
      }
      // Past its deadline the connection is already cancelled.
      guard self.awaitingRequests.contains(request) else { return }
      var buffer = buffer
      if let data, !data.isEmpty { buffer.append(data) }
      switch Self.assembleRequest(buffer) {
      case .ready(let headers, let body):
        self.awaitingRequests.remove(request)
        self.respond(headers: headers, body: body, connection: connection)
      case .tooLarge:
        self.awaitingRequests.remove(request)
        self.sendText("payload too large", status: "413 Payload Too Large", connection: connection)
      case .incomplete:
        guard !isComplete else {
          self.awaitingRequests.remove(request)
          connection.cancel()
          return
        }
        self.readRequest(connection, request: request, buffer: buffer)
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
    // A page on another site that names this listener is not stopped by
    // the Host check: refuse any change a browser marks as cross-site.
    guard !Self.isCrossSiteChange(request: headers, port: listeningPort) else {
      FlashLog.warn("[debug] http inspector refused a change from another site")
      sendText("forbidden", status: "403 Forbidden", connection: connection)
      return
    }
    let route = Self.route(path: Self.requestPath(headers))
    // Every account and process shares the loopback address: data and
    // changes answer only the token, the page shell and the manual anyone.
    guard !route.requiresAccess || Self.isAuthorized(request: headers, token: accessToken) else {
      FlashLog.info("[debug] http inspector refused a request without the access token")
      sendText(
        "unauthorized: open the help from Flash (flash help show) to unlock it",
        status: "401 Unauthorized", connection: connection)
      return
    }
    switch route {
    case .app(let found):
      sendHTML(found: found, request: headers, connection: connection)
    case .state:
      sendState(refresh: Self.queryValue("refresh", in: headers) == "1", connection: connection)
    case .logs:
      let records =
        Self.queryValue("trace", in: headers).map { id in
          zip(logs, encodedLogs).filter { $0.0["trace"] as? String == id }.map(\.1)
        } ?? encodedLogs
      sendJSON(Self.logsDocument(records), connection: connection)
    case .traces:
      sendJSON(["traces": Self.traceSummaries(self.logs)], connection: connection)
    case .events:
      startEvents(connection)
    case .clipboardItem(let id):
      serveClipboardItem(id, request: headers, connection: connection)
    case .clipboardPin(let id):
      serveClipboardPin(id, request: headers, connection: connection)
    case .clipboardHistory:
      serveClipboardHistory(request: headers, connection: connection)
    case .config:
      serveConfig(purge: false, request: headers, body: body, connection: connection)
    case .configPurge:
      serveConfig(purge: true, request: headers, body: body, connection: connection)
    case .telemetry:
      guard Self.requestMethod(headers) == "GET" else {
        sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
        return
      }
      guard let telemetryHTTP else {
        sendText("unavailable", status: "503 Service Unavailable", connection: connection)
        return
      }
      sendJSON(telemetryHTTP(), connection: connection)
    case .docs(let file):
      serveDocs(file, request: headers, connection: connection)
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

  /// The manual the app bundle carries; nil outside one (a bare `swift run`).
  static let bundledDocs: URL? = Bundle.main.resourceURL?.appendingPathComponent("docs")

  /// `GET` of a bundled documentation file, read on `queue`: the manual
  /// (`/api/docs`), its search sections, or a file a page links. The bundle
  /// changes only with the app, so the browser keeps its copy and asks with
  /// the file's validator: a match is a bodiless 304, and the file is not read.
  private func serveDocs(_ file: String, request: String, connection: NWConnection) {
    guard Self.requestMethod(request) == "GET" else {
      sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
      return
    }
    guard let url = Self.docsURL(file, root: docsRoot), let etag = Self.fileETag(url) else {
      sendText("not found", status: "404 Not Found", connection: connection)
      return
    }
    if Self.ifNoneMatch(request, matches: etag) {
      return sendNotModified(etag: etag, connection: connection)
    }
    guard let body = try? Data(contentsOf: url) else {
      sendText("not found", status: "404 Not Found", connection: connection)
      return
    }
    sendBytes(
      body, status: "200 OK", contentType: Self.docsContentType(file), cacheControl: "no-cache",
      etag: etag, connection: connection)
  }

  /// A file's validator, from its size and modification time: the bundled
  /// manual changes only when the app is replaced.
  static func fileETag(_ url: URL) -> String? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ]),
      values.isRegularFile == true, let size = values.fileSize,
      let modified = values.contentModificationDate
    else { return nil }
    return "\"\(size)-\(Int64(modified.timeIntervalSince1970 * 1_000_000))\""
  }

  /// A strong validator of `body`: the start of its SHA-256.
  static func contentETag(_ body: Data) -> String {
    "\"" + SHA256.hash(data: body).prefix(12).map { String(format: "%02x", $0) }.joined() + "\""
  }

  /// Whether the request's `If-None-Match` names `etag` (or `*`): the
  /// browser already holds this representation.
  static func ifNoneMatch(_ request: String, matches etag: String) -> Bool {
    let header = request.split(whereSeparator: \.isNewline).dropFirst().first { line in
      line.lowercased().hasPrefix("if-none-match:")
    }
    guard let header else { return false }
    let opaque = { (tag: Substring) -> Substring in tag.hasPrefix("W/") ? tag.dropFirst(2) : tag }
    let wanted = opaque(Substring(etag))
    return header.dropFirst("if-none-match:".count).split(separator: ",").contains { candidate in
      let tag = candidate.trimmingCharacters(in: .whitespaces)
      return tag == "*" || opaque(Substring(tag)) == wanted
    }
  }

  /// A bundled documentation file inside `root`, or nil when it escapes it.
  static func docsURL(_ file: String, root: URL?) -> URL? {
    guard let root else { return nil }
    let base = root.standardizedFileURL.resolvingSymlinksInPath()
    let url = base.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(base.path + "/") else { return nil }
    return url
  }

  static func docsContentType(_ file: String) -> String {
    switch (file as NSString).pathExtension.lowercased() {
    case "json": return "application/json; charset=utf-8"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return "text/plain; charset=utf-8"
    }
  }

  /// Every page path receives the same single-page app, which renders its own
  /// view (including "not found") from the URL; only the status differs. The
  /// page changes only with the app: a browser revalidates its copy, and the
  /// same bytes answer a bodiless 304.
  private func sendHTML(found: Bool, request: String, connection: NWConnection) {
    let page = Self.page
    if found, Self.ifNoneMatch(request, matches: page.etag) {
      return sendNotModified(etag: page.etag, connection: connection)
    }
    sendBytes(
      page.body, status: found ? "200 OK" : "404 Not Found",
      contentType: "text/html; charset=utf-8", cacheControl: "no-cache",
      etag: found ? page.etag : nil, connection: connection)
  }

  /// The page as bytes with its validator, built once.
  private static let page: (body: Data, etag: String) = {
    let body = Data(pageHTML.utf8)
    return (body, contentETag(body))
  }()

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
      <p>UI bundle missing. Run <code>mise run build:inspector</code> and rebuild.</p>
      </body></html>
      """
  }

  private func sendJSON(_ object: Any, connection: NWConnection) {
    sendJSON(Self.jsonData(object) ?? Data("{}".utf8), connection: connection)
  }

  /// Runtime data: never kept in the browser's cache.
  private func sendJSON(_ body: Data, connection: NWConnection) {
    sendBytes(
      body, status: "200 OK", contentType: "application/json; charset=utf-8",
      connection: connection)
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

  /// `PUT` pins the entry and `DELETE` unpins it. Neither is a simple
  /// cross-origin request, so a web page cannot send one without a preflight
  /// this server never answers.
  private func serveClipboardPin(_ id: String, request: String, connection: NWConnection) {
    let method = Self.requestMethod(request)
    guard method == "PUT" || method == "DELETE" else {
      sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
      return
    }
    guard let clipboardPinHTTP else {
      sendText("unavailable", status: "503 Service Unavailable", connection: connection)
      return
    }
    clipboardPinHTTP(method == "PUT", id) { [weak self] status, contentType, body in
      guard let self else { return }
      self.queue.async {
        self.sendBytes(body, status: status, contentType: contentType, connection: connection)
      }
    }
  }

  private func serveClipboardHistory(request: String, connection: NWConnection) {
    guard Self.requestMethod(request) == "GET" else {
      sendText("method not allowed", status: "405 Method Not Allowed", connection: connection)
      return
    }
    guard let offset = Self.clipboardHistoryOffset(request) else {
      sendText("invalid offset", status: "400 Bad Request", connection: connection)
      return
    }
    guard let clipboardHistoryHTTP else {
      sendText("unavailable", status: "503 Service Unavailable", connection: connection)
      return
    }
    clipboardHistoryHTTP(offset) { [weak self] status, contentType, body in
      guard let self else { return }
      self.queue.async {
        self.sendBytes(body, status: status, contentType: contentType, connection: connection)
      }
    }
  }

  private func sendBytes(
    _ body: Data, status: String, contentType: String, cacheControl: String = "no-store",
    etag: String? = nil, connection: NWConnection
  ) {
    let header = Self.responseHeaders(
      status: status, contentType: contentType, contentLength: body.count,
      cacheControl: cacheControl, etag: etag)
    var bytes = Data(header.utf8)
    bytes.append(body)
    connection.send(
      content: bytes,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  /// A bodiless 304: the browser's copy, named by `etag`, is current.
  private func sendNotModified(etag: String, connection: NWConnection) {
    let header = Self.responseHeaders(
      status: "304 Not Modified", contentType: nil, contentLength: nil, cacheControl: "no-cache",
      etag: etag)
    send(header, connection: connection, close: true)
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
      + "Cross-Origin-Resource-Policy: same-origin\r\n"
      + "Connection: keep-alive\r\n"
      + "\r\n"
    send(headers, connection: connection, close: false)
    // A stale cache is not sent: the publish this stream arms delivers the
    // current state whole instead.
    if cachedStateIsCurrent {
      sendEvent(
        Self.eventFrame("state", data: encodedState.document), id: id, connection: connection)
    } else {
      streamsAwaitingState.insert(id)
    }
    sendEvent(
      Self.eventFrame("logs", data: Self.logsDocument(encodedLogs)), id: id, connection: connection)
    // Handlers run on `queue`, where the connection was started.
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled:
        guard let self, self.eventConnections.removeValue(forKey: id) != nil else { return }
        self.eventBacklogs[id] = nil
        self.streamsAwaitingState.remove(id)
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

  /// One frame, encoded once, to every stream.
  private func broadcast(_ frame: Data) {
    for (id, connection) in eventConnections {
      sendEvent(frame, id: id, connection: connection)
    }
  }

  /// The snapshot just cached, to every stream: a `patch` of the sections
  /// that changed since `previous`, which every stream holds, or the whole
  /// `state` to a stream that has none yet. Each frame is encoded once.
  private func broadcastState(previous: EncodedState) {
    guard !eventConnections.isEmpty else { return }
    var whole: Data?
    var patch: Data?
    for (id, connection) in eventConnections {
      let frame: Data
      if streamsAwaitingState.remove(id) != nil {
        if whole == nil { whole = Self.eventFrame("state", data: encodedState.document) }
        frame = whole!
      } else {
        if patch == nil {
          patch = Self.eventFrame("patch", data: encodedState.patch(from: previous))
        }
        frame = patch!
      }
      sendEvent(frame, id: id, connection: connection)
    }
  }

  private static func eventFrame(_ event: String, data: Data) -> Data {
    var frame = Data("event: \(event)\ndata: ".utf8)
    frame.append(data)
    frame.append(contentsOf: Array("\n\n".utf8))
    return frame
  }

  /// Send `frame` to stream `id`. A stream that stopped reading would keep
  /// every frame in memory: once what it has not taken would pass
  /// `maxStreamBacklogBytes`, it is dropped (an EventSource reconnects).
  /// An idle stream always takes one frame, whatever its size.
  private func sendEvent(_ frame: Data, id: UUID, connection: NWConnection) {
    let pending = eventBacklogs[id] ?? 0
    guard pending == 0 || pending + frame.count <= Self.maxStreamBacklogBytes else {
      FlashLog.warn(
        "[debug] http inspector dropped an event stream that stopped reading",
        fields: ["backlog_bytes": String(pending)])
      eventBacklogs[id] = nil
      connection.cancel()
      return
    }
    eventBacklogs[id] = pending + frame.count
    connection.send(
      content: frame,
      completion: .contentProcessed { [weak self] _ in
        guard let self, let pending = self.eventBacklogs[id] else { return }
        self.eventBacklogs[id] = max(0, pending - frame.count)
      })
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
    responseHeaders(
      status: status, contentType: contentType, contentLength: body.utf8.count,
      cacheControl: "no-cache") + body
  }

  /// Finite replies close after one send. Advertise that before a pooled
  /// client can reuse the socket for a request it cannot safely retry. A
  /// 304 has neither a type nor a length.
  private static func responseHeaders(
    status: String, contentType: String?, contentLength: Int?, cacheControl: String,
    etag: String? = nil
  ) -> String {
    var lines = ["HTTP/1.1 \(status)"]
    if let contentType {
      let type =
        contentType.contains(where: \.isNewline) ? "application/octet-stream" : contentType
      lines.append("Content-Type: \(type)")
    }
    if let contentLength { lines.append("Content-Length: \(contentLength)") }
    if let etag { lines.append("ETag: \(etag)") }
    return
      (lines + [
        "Cache-Control: \(cacheControl)",
        "X-Content-Type-Options: nosniff",
        "Content-Security-Policy: frame-ancestors 'none'",
        "X-Frame-Options: DENY",
        "Referrer-Policy: no-referrer",
        "Cross-Origin-Resource-Policy: same-origin",
        "Connection: close",
      ]).joined(separator: "\r\n") + "\r\n\r\n"
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

  /// A request other than GET or HEAD that a browser sent from another
  /// site: its `Origin` is not this listener, or `Sec-Fetch-Site` says
  /// `cross-site`. The inspector's own requests carry this listener's
  /// origin; a command-line client sends neither header.
  static func isCrossSiteChange(request: String, port: UInt16?) -> Bool {
    let method = requestMethod(request)
    guard method != "GET", method != "HEAD" else { return false }
    let lines = request.split(whereSeparator: \.isNewline).dropFirst()
    func header(_ name: String) -> String? {
      let prefix = name.lowercased() + ":"
      return lines.first { $0.lowercased().hasPrefix(prefix) }
        .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).lowercased() }
    }
    if header("Sec-Fetch-Site") == "cross-site" { return true }
    guard let origin = header("Origin") else { return false }
    guard let port else { return true }
    return !["127.0.0.1", "localhost", "[::1]"].contains { origin == "http://\($0):\(port)" }
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

  static func clipboardHistoryOffset(_ request: String) -> Int? {
    let first = request.split(whereSeparator: \.isNewline).first ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    guard target.count == 2 else { return target.count == 1 ? 0 : nil }
    guard target[1].hasPrefix("offset=") else { return nil }
    let raw = target[1].dropFirst("offset=".count)
    guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
      let offset = Int(raw), offset <= 10_000
    else { return nil }
    return offset
  }

  /// How the server answers a request path. Data endpoints live under
  /// `/api/`; every other path belongs to the help app, found or not.
  enum Route: Equatable {
    case app(found: Bool)
    case state
    case logs
    case traces
    case events
    case clipboardHistory
    case clipboardItem(id: String)
    case clipboardPin(id: String)
    case config
    case configPurge
    case telemetry
    /// A file of the bundled manual, relative to its root: `docs.json`,
    /// `search.json` or `files/<path>`.
    case docs(file: String)
    case missingEndpoint

    /// Everything but the page shell, the bundled manual and a missing
    /// endpoint reads or changes your data.
    var requiresAccess: Bool {
      switch self {
      case .app, .docs, .missingEndpoint: return false
      case .state, .logs, .traces, .events, .clipboardHistory, .clipboardItem, .clipboardPin,
        .config, .configPurge, .telemetry:
        return true
      }
    }
  }

  static func route(path: String) -> Route {
    switch path {
    case "/api/state": return .state
    case "/api/logs": return .logs
    case "/api/traces": return .traces
    case "/api/events": return .events
    case "/api/clipboard/history": return .clipboardHistory
    case "/api/config": return .config
    case "/api/config/purge": return .configPurge
    case "/api/telemetry": return .telemetry
    case "/api/docs": return .docs(file: "docs.json")
    case "/api/docs/search": return .docs(file: "search.json")
    default:
      if let id = clipboardItemID(path: path) { return .clipboardItem(id: id) }
      if path.hasSuffix("/pin"), let id = clipboardItemID(path: String(path.dropLast(4))) {
        return .clipboardPin(id: id)
      }
      if let file = docsFile(path: path) { return .docs(file: "files/" + file) }
      if path == "/api" || path.hasPrefix("/api/") { return .missingEndpoint }
      return .app(found: Page(path: path) != nil)
    }
  }

  /// File types a manual page may link (`[example](flash.toml)`, an image).
  /// No SVG or HTML: nothing served here runs script in the help's origin.
  private static let docsFileExtensions: Set<String> = [
    "toml", "json", "txt", "png", "jpg", "jpeg", "gif", "webp",
  ]
  private static let docsSegment = try! NSRegularExpression(
    pattern: "^[A-Za-z0-9_][A-Za-z0-9._-]*$")

  /// `/docs/<path>.<ext>` is a file under `docs/` that a manual page links,
  /// served as it is; the manual's pages have no extension. Each segment is
  /// a plain name: no dot file, no `..`, no encoded separator.
  static func docsFile(path: String) -> String? {
    guard path.hasPrefix("/docs/") else { return nil }
    let encoded = path.dropFirst("/docs/".count).split(
      separator: "/", omittingEmptySubsequences: false)
    var segments: [String] = []
    for segment in encoded {
      guard let decoded = String(segment).removingPercentEncoding,
        docsSegment.firstMatch(
          in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) != nil
      else { return nil }
      segments.append(decoded)
    }
    guard let last = segments.last, last.contains("."),
      docsFileExtensions.contains((last as NSString).pathExtension.lowercased())
    else { return nil }
    return segments.joined(separator: "/")
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

  /// `value` as JSON with sorted keys, so equal values encode to equal
  /// bytes; nil for what JSON cannot carry. A scalar is a fragment.
  static func jsonData(_ value: Any) -> Data? {
    guard JSONSerialization.isValidJSONObject([value]) else { return nil }
    return try? JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  }

  /// A snapshot encoded once, off main: each top-level section on its own,
  /// so the next snapshot's patch carries only the sections whose bytes
  /// changed, and the whole document `/api/state` and a new stream receive.
  struct EncodedState {
    let seq: Int
    let sections: [String: Data]
    let document: Data

    static let empty = EncodedState(seq: 0, sections: [:])

    init(seq: Int, sections: [String: Data]) {
      self.seq = seq
      self.sections = sections
      document = Self.object(sections)
    }

    /// A section JSON cannot carry is left out, as the whole document once was.
    init(_ snapshot: [String: Any], seq: Int) {
      self.init(seq: seq, sections: snapshot.compactMapValues(DebugServer.jsonData))
    }

    /// `{"<key>":<value>,…}` in key order, from encoded values.
    static func object(_ members: [String: Data]) -> Data {
      var out = Data("{".utf8)
      for (index, key) in members.keys.sorted().enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        out.append(DebugServer.jsonData(key) ?? Data(#""""#.utf8))
        out.append(UInt8(ascii: ":"))
        out.append(members[key] ?? Data("null".utf8))
      }
      out.append(UInt8(ascii: "}"))
      return out
    }

    /// `{"base":<previous seq>,"set":{…},"unset":[…]}`: the sections that
    /// differ from `previous`, and those it had and this has not.
    func patch(from previous: EncodedState) -> Data {
      let changed = sections.filter { previous.sections[$0.key] != $0.value }
      let removed = previous.sections.keys.filter { sections[$0] == nil }.sorted()
      var out = Data(#"{"base":\#(previous.seq),"set":"#.utf8)
      out.append(Self.object(changed))
      out.append(contentsOf: Array(#","unset":"#.utf8))
      out.append(DebugServer.jsonData(removed) ?? Data("[]".utf8))
      out.append(UInt8(ascii: "}"))
      return out
    }
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

  /// The address the listener binds for a validated host: `::1` for `::1`,
  /// otherwise IPv4 loopback (`localhost` resolves to both; browsers fall
  /// back to 127.0.0.1).
  static func bindAddress(host: String) -> NWEndpoint.Host {
    host == "::1" ? .ipv6(.loopback) : .ipv4(.loopback)
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
  /// table: `/`, `/docs[/<page>]`, `/mappings`, `/commands`,
  /// `/plugins[/<id>]`, `/monitors`, `/telemetry`, `/state`, `/logs`,
  /// `/clipboard` and `/search`. Fragments stay free for in-page anchors.
  enum Page: Equatable {
    case home
    /// A page of the manual (`docs/`) by its path or alias, such as
    /// `normal-mode`, `config` or `alternatives/neru`, or a plugin's guide;
    /// nil is the manual's home. The published site has the same page at
    /// `<site>/<page>/`.
    case docs(page: String?)
    case mappings
    case commands
    case plugins(id: String?)
    /// Every `[monitors.<name>]` with its value, thresholds and state, worst
    /// first.
    case monitors
    /// Received OpenTelemetry metrics, logs and spans, with the receiver's
    /// and exporter's state.
    case telemetry
    case state
    case logs
    case clipboard
    /// Search results across the manual, commands, mappings and plugins; the
    /// query travels in `?q=` so a search can be reloaded and shared.
    case search

    /// Pages that accept one detail segment, such as a topic or plugin id.
    private static let detailPages: Set<String> = ["plugins"]
    private static let pages: Set<String> = [
      "docs", "mappings", "commands", "plugins", "monitors", "telemetry", "state", "logs",
      "clipboard", "search",
    ]
    /// RFC 3986 unreserved characters: everything else in a detail segment,
    /// including `/`, `?` and `#`, is percent-encoded.
    private static let segmentCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The percent-encoded absolute path of the page.
    var path: String {
      switch self {
      case .home: return "/"
      case .docs(let page):
        let segments = (page ?? "").split(separator: "/").compactMap {
          String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters)
        }
        return (["/docs"] + segments).joined(separator: "/")
      case .mappings: return "/mappings"
      case .commands: return "/commands"
      case .plugins(let id): return Self.path("plugins", detail: id)
      case .monitors: return "/monitors"
      case .telemetry: return "/telemetry"
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
      guard Self.pages.contains(head) else { return nil }
      if head == "docs" {
        // Any depth; a last segment with a dot is a linked file, not a page.
        var decoded: [String] = []
        for segment in segments.dropFirst() {
          guard let value = segment.removingPercentEncoding, !value.isEmpty else { return nil }
          decoded.append(value)
        }
        guard decoded.last?.contains(".") != true else { return nil }
        self = .docs(page: decoded.isEmpty ? nil : decoded.joined(separator: "/"))
        return
      }
      guard segments.count <= (Self.detailPages.contains(head) ? 2 : 1) else { return nil }
      var detail: String?
      if segments.count == 2 {
        guard let decoded = segments[1].removingPercentEncoding else { return nil }
        detail = decoded
      }
      switch head {
      case "mappings": self = .mappings
      case "commands": self = .commands
      case "plugins": self = .plugins(id: detail)
      case "monitors": self = .monitors
      case "telemetry": self = .telemetry
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
