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

  /// Nothing refreshes the inspector's state on a clock while no browser
  /// holds an event stream; the cadence starts with the first stream and
  /// stops with the last.
  func testStateRefreshRunsOnlyWhileAnEventStreamIsOpen() throws {
    let scheduler = PollScheduler()
    let server = DebugServer(host: "localhost", port: 0, scheduler: scheduler) { ["ok": true] }
    server.start()
    defer { server.stop() }
    let port = try waitForListeningPort(server)
    XCTAssertEqual(registrations(scheduler), [])

    let client = NWConnection(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let streaming = expectation(description: "event stream open")
    client.stateUpdateHandler = { state in
      guard case .ready = state else { return }
      let request = "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
      client.send(content: request.data(using: .utf8), completion: .idempotent)
      client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
        if String(decoding: data ?? Data(), as: UTF8.self).contains("text/event-stream") {
          streaming.fulfill()
        }
      }
    }
    client.start(queue: DispatchQueue(label: "debug.tests.client"))
    wait(for: [streaming], timeout: 10)
    XCTAssertTrue(
      waitFor { self.registrations(scheduler) == [DebugServer.pollClientID] },
      "an open stream registers the refresh")

    client.cancel()
    XCTAssertTrue(
      waitFor { self.registrations(scheduler).isEmpty }, "the last stream closing releases it")
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

  private func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { return false }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return true
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
