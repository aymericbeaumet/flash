import AppKit
import Network
import XCTest

@testable import flash

final class DebugServerTests: XCTestCase {
  func testRuntimeSnapshotIsSerializableAndKeepsPluginSettingsPrivate() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    delegate.config = ConfigLoader.parse(
      """
      [plugin.sample]
      token = "private-test-token"
      """)
    let state = delegate.debugStateJSON()
    let data = try JSONSerialization.data(withJSONObject: state)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("private-test-token"))
    let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
    XCTAssertEqual(runtime["pid"] as? Int32, ProcessInfo.processInfo.processIdentifier)
    // Uptime is derived client-side from a fixed start time, never pushed.
    XCTAssertNil(runtime["uptime_seconds"])
    let started = try XCTUnwrap(runtime["started_at_unix_ms"] as? Int64)
    XCTAssertEqual(
      Double(started), delegate.runtimeStartedAt.timeIntervalSince1970 * 1000, accuracy: 1)
    XCTAssertEqual(runtime["keyboard_capture_active"] as? Bool, false)
    XCTAssertNotNil(state["snapshot_at_unix_ms"] as? Int64)
    XCTAssertEqual(state["overlay"] as? String, String(describing: delegate.overlay.inputMode))
    let mappings = try XCTUnwrap(state["mappings"] as? [String: Any])
    let rows = try XCTUnwrap(mappings["effective_rows"] as? [[String: String]])
    XCTAssertEqual(rows, mappings["rows"] as? [[String: String]])
    XCTAssertTrue(rows.contains { $0["key"] == "?" && $0["action"] == "flash mappings_show" })
  }

  func testDashboardLinksUsePagePaths() throws {
    XCTAssertEqual(
      DebugServer.dashboardURL(host: "localhost", port: 4242, page: .home)?.absoluteString,
      "http://localhost:4242/")
    XCTAssertEqual(
      DebugServer.dashboardURL(host: "127.0.0.1", port: 4242, page: .mappings)?.absoluteString,
      "http://127.0.0.1:4242/mappings")
    let topic = "plugin / symbols #?%"
    let url = try XCTUnwrap(
      DebugServer.dashboardURL(host: "::1", port: 4242, page: .docs(topic: topic)))
    XCTAssertEqual(
      url.absoluteString, "http://[::1]:4242/docs/plugin%20%2F%20symbols%20%23%3F%25")
    XCTAssertNil(url.fragment)
    XCTAssertNil(url.query)
    XCTAssertEqual(DebugServer.Page(path: url.path(percentEncoded: true)), .docs(topic: topic))
    XCTAssertEqual(
      DebugServer.dashboardURL(host: "localhost", port: 4242, page: .docs(topic: "  "))?.path,
      "/docs")
    XCTAssertNil(DebugServer.dashboardURL(host: "example.com", port: 4242, page: .home))
  }

  func testEveryPageRoundTripsThroughItsPath() {
    let pages: [DebugServer.Page] = [
      .home, .docs(topic: nil), .docs(topic: "getting-started"), .docs(topic: "é/ü"),
      .mappings, .commands, .plugins(id: nil), .plugins(id: "tmux"), .state, .logs, .clipboard,
    ]
    for page in pages {
      XCTAssertEqual(DebugServer.Page(path: page.path), page, page.path)
      XCTAssertEqual(DebugServer.route(path: page.path), .app(found: true), page.path)
    }
  }

  /// Every page path, including deep links and reloads, receives the help
  /// app; data lives under `/api/`; anything else is not found.
  func testRoutesSeparatePagesFromEndpoints() {
    XCTAssertEqual(DebugServer.route(path: "/api/state"), .state)
    XCTAssertEqual(DebugServer.route(path: "/api/logs"), .logs)
    XCTAssertEqual(DebugServer.route(path: "/api/traces"), .traces)
    XCTAssertEqual(DebugServer.route(path: "/api/events"), .events)
    for path in ["/api", "/api/", "/api/state/x", "/api/docs"] {
      XCTAssertEqual(DebugServer.route(path: path), .missingEndpoint, path)
    }
    for path in ["/docs/", "/mappings/", "/plugins/tmux/"] {
      XCTAssertEqual(DebugServer.route(path: path), .app(found: true), path)
    }
    for path in [
      "/home", "/missing", "/docs/a/b", "/state/x", "/mappings/gg", "/docs/%zz", "/index.html",
    ] {
      XCTAssertEqual(DebugServer.route(path: path), .app(found: false), path)
    }
  }

  func testTracesSummarizeEachInteractionAcrossHostAndPlugins() {
    let logs: [[String: Any]] = [
      [
        "trace": "a1", "time_unix_ms": Int64(100), "level": "debug", "message": "[trace] begin",
        "fields": ["origin": "key"], "source": "core:AppDelegate.swift.route()",
      ],
      ["trace": "a1", "time_unix_ms": Int64(130), "level": "warn", "source": "plugin:tmux"],
      ["time_unix_ms": Int64(140), "level": "info", "source": "core:x"],
      [
        "trace": "b2", "time_unix_ms": Int64(200), "level": "debug", "message": "[trace] begin",
        "fields": ["origin": "cli"], "source": "core:y",
      ],
    ]
    let traces = DebugServer.traceSummaries(logs)
    XCTAssertEqual(traces.map { $0["trace"] as? String }, ["b2", "a1"], "newest first")
    let first = traces[1]
    XCTAssertEqual(first["origin"] as? String, "key")
    XCTAssertEqual(first["duration_ms"] as? Int64, 30)
    XCTAssertEqual(first["lines"] as? Int, 2)
    XCTAssertEqual(first["worst_level"] as? String, "warn")
    XCTAssertEqual(first["sources"] as? [String], ["core", "plugin:tmux"])
    XCTAssertEqual(
      DebugServer.queryValue("trace", in: "GET /api/logs?x=1&trace=a1 HTTP/1.1\r\n"), "a1")
    XCTAssertNil(DebugServer.queryValue("trace", in: "GET /api/logs HTTP/1.1\r\n"))
  }

  /// DNS rebinding: a page on its own hostname, rebound to 127.0.0.1, must
  /// not read the inspector; only requests naming this listener pass.
  func testInspectorServesOnlyRequestsForItsOwnLoopbackHost() {
    func request(_ host: String?) -> String {
      "GET /api/state HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + "Accept: */*\r\n\r\n"
    }
    for host in ["127.0.0.1:4242", "localhost:4242", "[::1]:4242", "LOCALHOST:4242"] {
      XCTAssertTrue(DebugServer.hostIsLoopback(request: request(host), port: 4242), host)
    }
    for host in ["evil.example:4242", "127.0.0.1:9999", "localhost", "127.0.0.1.evil.example:4242"]
    {
      XCTAssertFalse(DebugServer.hostIsLoopback(request: request(host), port: 4242), host)
    }
    XCTAssertFalse(DebugServer.hostIsLoopback(request: request(nil), port: 4242))
  }

  func testParsesLoopbackHostAndPort() {
    let localhost = DebugServer.parse(host: "localhost", port: 4242)
    XCTAssertEqual(localhost?.host, "localhost")
    XCTAssertEqual(localhost?.port.rawValue, 4242)

    let ipv4 = DebugServer.parse(host: "127.0.0.1", port: 4343)
    XCTAssertEqual(ipv4?.host, "127.0.0.1")
    XCTAssertEqual(ipv4?.port.rawValue, 4343)

    let ipv6 = DebugServer.parse(host: "::1", port: 4444)
    XCTAssertEqual(ipv6?.host, "::1")
    XCTAssertEqual(ipv6?.port.rawValue, 4444)
  }

  func testRejectsNonLoopbackHostAndOutOfRangePort() {
    XCTAssertNil(DebugServer.parse(host: "0.0.0.0", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "192.168.1.10", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "example.com", port: 4242))
    XCTAssertNil(DebugServer.parse(host: "localhost", port: -1))
    XCTAssertNil(DebugServer.parse(host: "localhost", port: 70000))
  }

  func testLoopbackEndpointFilter() {
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .name("localhost", nil), port: 4242)))
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: 4242)))
    XCTAssertTrue(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv6(IPv6Address("::1")!), port: 4242)))
    XCTAssertFalse(
      DebugServer.isLoopback(
        endpoint: .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 4242)))
  }

  func testServesStateJSON() throws {
    let server = DebugServer(host: "localhost", port: 0) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let port = try waitForListeningPort(server)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/state"))
    let response = try fetch(url: url, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(response.body.contains("\"ok\":true"), response.body)
  }

  func testServesSvelteInspectorBundleOnEveryPage() throws {
    let server = DebugServer(host: "localhost", port: 0) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let port = try waitForListeningPort(server)
    let root = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
    let home = try fetch(url: root, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(home.status, 200)
    let body = home.body

    // The inspector UI is the Svelte single-file bundle shipped as a
    // resource; assert on stable, non-minified markers rather than the
    // old inline-JS internals.
    XCTAssertTrue(body.contains("<title>Flash Help</title>"), "missing help document title")
    XCTAssertTrue(body.contains("id=\"app\""), body)
    // The runtime data wiring survives minification as string literals.
    XCTAssertTrue(body.contains("/api/events"), body)
    XCTAssertTrue(body.contains("/api/state"), body)
    // Confirms it is the built bundle, not the missing-resource fallback.
    XCTAssertGreaterThan(body.count, 5_000, "served body looks like the fallback page")
    // The rename is complete — no "Flash Debug" anywhere.
    XCTAssertFalse(body.contains("Flash Debug"), body)

    // Direct loads and reloads of deep pages receive the same app; unknown
    // pages receive it with a 404 so it can render its own not-found view.
    for (path, status) in [
      ("/docs/getting-started", 200), ("/mappings?q=gg", 200), ("/state", 200),
      ("/missing", 404),
    ] {
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
      let response = try fetch(url: url, deadline: Date().addingTimeInterval(10))
      XCTAssertEqual(response.status, status, path)
      XCTAssertEqual(response.body, body, path)
    }
    let missing = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/missing"))
    let endpoint = try fetch(url: missing, deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(endpoint.status, 404)
    XCTAssertEqual(endpoint.body, "not found")
  }

  /// The inspector has no clock: an open event stream registers nothing with
  /// the shared poll scheduler, and a burst of changes reaches it as exactly
  /// one pushed snapshot.
  func testAnOpenEventStreamRegistersNoCadenceAndReceivesOneSnapshotPerBurst() throws {
    var version = 0
    let server = DebugServer(host: "localhost", port: 0) {
      version += 1
      return ["version": version]
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    let before = registrations(PollScheduler.shared)

    let stream = EventStreamClient(port: port)
    defer { stream.cancel() }
    XCTAssertTrue(
      spin { stream.count(of: "event: logs") == 1 && server.publication.streams == 1 },
      "the stream opens with the cached state and logs")
    XCTAssertEqual(stream.count(of: "event: state"), 1)
    XCTAssertEqual(
      registrations(PollScheduler.shared), before, "an open stream registers no cadence")

    for _ in 0..<5 { server.stateDidChange() }
    XCTAssertTrue(spin { stream.count(of: "event: state") == 2 }, "the burst is pushed")
    spin(for: 0.3)
    XCTAssertEqual(stream.count(of: "event: state"), 2, "a burst is one snapshot, then quiet")
    XCTAssertTrue(stream.text.contains("\"version\":2"), stream.text)
    XCTAssertEqual(registrations(PollScheduler.shared), before)

    stream.cancel()
    XCTAssertTrue(spin { server.publication.streams == 0 }, "the closed stream is released")
  }

  /// Changes inside one window collapse into one snapshot; with no stream
  /// open nothing is taken, and a stream arriving on a stale cache gets a
  /// fresh snapshot.
  func testChangesCoalesceIntoOneSnapshotPerWindowOnlyWhileObserved() {
    var snapshots = 0
    let server = DebugServer(host: "localhost", port: 0, coalescingWindow: .milliseconds(20)) {
      snapshots += 1
      return [:]
    }
    defer { server.stop() }
    server.streamsDidChange(by: 1)
    for _ in 0..<10 { server.stateDidChange() }
    XCTAssertEqual(snapshots, 0, "the first change waits out the window")
    XCTAssertTrue(spin { snapshots == 1 })
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 1, "ten changes, one snapshot")
    server.stateDidChange()
    XCTAssertTrue(spin { snapshots == 2 }, "the next burst is the next snapshot")

    server.streamsDidChange(by: -1)
    server.stateDidChange()
    server.stateDidChange()
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 2, "nobody reads it, nothing is taken")
    XCTAssertTrue(server.publication.stale)
    server.streamsDidChange(by: 1)
    XCTAssertTrue(spin { snapshots == 3 }, "a stream opening on a stale cache gets a fresh one")
    XCTAssertFalse(server.publication.stale)
  }

  /// `/api/state` answers from the cache while it is current; a stale cache
  /// or an explicit `?refresh=1` takes one fresh snapshot.
  func testStateRequestsSnapshotOnlyWhenStaleOrAskedTo() throws {
    var snapshots = 0
    let server = DebugServer(host: "localhost", port: 0, coalescingWindow: .milliseconds(10)) {
      snapshots += 1
      return ["n": snapshots]
    }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(snapshots, 1, "start seeds the cache")

    for _ in 0..<3 { server.stateDidChange() }
    spin(for: 0.1)
    XCTAssertEqual(snapshots, 1, "no stream is open")
    XCTAssertTrue(try fetchSpinningMain(port: port, path: "/api/state").contains("\"n\":2"))
    XCTAssertEqual(snapshots, 2, "the stale cache is refreshed once")
    XCTAssertTrue(try fetchSpinningMain(port: port, path: "/api/state").contains("\"n\":2"))
    XCTAssertEqual(snapshots, 2, "a current cache answers without a snapshot")
    XCTAssertTrue(
      try fetchSpinningMain(port: port, path: "/api/state?refresh=1").contains("\"n\":3"))
    XCTAssertEqual(snapshots, 3, "an explicit refresh resamples")
  }

  func testWhenListeningAnswersFromTheListenerState() throws {
    let server = DebugServer(host: "localhost", port: 0) { ["ok": true] }
    server.start()
    defer { server.stop() }
    let ready = expectation(description: "ready")
    server.whenListening(timeoutSeconds: 10) { port in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertNotNil(port)
      XCTAssertEqual(port, server.listeningPort)
      ready.fulfill()
    }
    wait(for: [ready], timeout: 10)

    // A second listener on the same port fails to bind: it answers nil at
    // once rather than at the deadline.
    let port = try XCTUnwrap(server.listeningPort)
    let clash = DebugServer(host: "localhost", port: Int(port)) { [:] }
    clash.start()
    defer { clash.stop() }
    let failed = expectation(description: "bind failure reported")
    let started = Date()
    clash.whenListening(timeoutSeconds: 30) { port in
      XCTAssertNil(port)
      XCTAssertLessThan(Date().timeIntervalSince(started), 10)
      failed.fulfill()
    }
    wait(for: [failed], timeout: 15)
  }

  private func registrations(_ scheduler: PollScheduler) -> [String] {
    let listed = DispatchSemaphore(value: 0)
    var ids: [String] = []
    scheduler.registeredIDs {
      ids = $0
      listed.signal()
    }
    listed.wait()
    return ids
  }

  /// Runs the main run loop, where the server's publication lives, until
  /// `condition` holds or `timeout` passes.
  @discardableResult
  private func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
  }

  private func spin(for seconds: TimeInterval) {
    spin(timeout: seconds) { false }
  }

  /// A request that may need the main thread to answer (a stale cache).
  private func fetchSpinningMain(port: UInt16, path: String) throws -> String {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    var body: String?
    URLSession.shared.dataTask(with: url) { data, _, _ in
      let text = String(decoding: data ?? Data(), as: UTF8.self)
      DispatchQueue.main.async { body = text }
    }.resume()
    XCTAssertTrue(spin { body != nil }, "no reply for \(path)")
    return body ?? ""
  }

  /// Polls until the `NWListener` reaches `.ready` and publishes its port.
  /// The ceiling is generous so a loaded CI runner doesn't flake; the happy
  /// path returns within a few milliseconds.
  private func waitForListeningPort(_ server: DebugServer) throws -> UInt16 {
    let deadline = Date().addingTimeInterval(10)
    while server.listeningPort == nil, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    return try XCTUnwrap(server.listeningPort, "DebugServer never started listening")
  }

  private func fetch(url: URL, deadline: Date) throws -> (status: Int, body: String) {
    var lastError: Error?
    while Date() < deadline {
      let sem = DispatchSemaphore(value: 0)
      var result: Result<(status: Int, body: String), Error>?
      URLSession.shared.dataTask(with: url) { data, response, error in
        if let error {
          result = .failure(error)
        } else {
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          result = .success((status, String(data: data ?? Data(), encoding: .utf8) ?? ""))
        }
        sem.signal()
      }.resume()
      _ = sem.wait(timeout: .now() + 0.25)
      if let result {
        switch result {
        case .success(let response):
          return response
        case .failure(let error):
          lastError = error
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if let lastError { throw lastError }
    return (0, "")
  }
}

/// A raw `/api/events` subscriber accumulating everything the server sends.
private final class EventStreamClient {
  private let connection: NWConnection
  private let lock = NSLock()
  private var received = ""

  init(port: UInt16) {
    connection = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, case .ready = state else { return }
      let request = "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
      self.connection.send(content: request.data(using: .utf8), completion: .idempotent)
      self.receive()
    }
    connection.start(queue: DispatchQueue(label: "debug.tests.stream"))
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  func count(of marker: String) -> Int {
    text.components(separatedBy: marker).count - 1
  }

  func cancel() { connection.cancel() }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        self.lock.lock()
        self.received += String(decoding: data, as: UTF8.self)
        self.lock.unlock()
      }
      if !isComplete, error == nil { self.receive() }
    }
  }
}
