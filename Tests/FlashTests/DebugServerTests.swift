import Network
import XCTest

@testable import flash

final class DebugServerTests: XCTestCase {
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
      DebugServer.queryValue("trace", in: "GET /logs?x=1&trace=a1 HTTP/1.1\r\n"), "a1")
    XCTAssertNil(DebugServer.queryValue("trace", in: "GET /logs HTTP/1.1\r\n"))
  }

  /// DNS rebinding: a page on its own hostname, rebound to 127.0.0.1, must
  /// not read the inspector; only requests naming this listener pass.
  func testInspectorServesOnlyRequestsForItsOwnLoopbackHost() {
    func request(_ host: String?) -> String {
      "GET /state HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + "Accept: */*\r\n\r\n"
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
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/state"))
    let body = try fetch(url: url, deadline: Date().addingTimeInterval(10))
    XCTAssertTrue(body.contains("\"ok\":true"), body)
  }

  func testServesSvelteInspectorBundle() throws {
    let server = DebugServer(host: "localhost", port: 0) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let port = try waitForListeningPort(server)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
    let body = try fetch(url: url, deadline: Date().addingTimeInterval(10))

    // The inspector UI is the Svelte single-file bundle shipped as a
    // resource; assert on stable, non-minified markers rather than the
    // old inline-JS internals.
    XCTAssertTrue(body.contains("<title>Flash Inspector</title>"), body)
    XCTAssertTrue(body.contains("id=\"app\""), body)
    // The runtime data wiring survives minification as string literals.
    XCTAssertTrue(body.contains("/events"), body)
    XCTAssertTrue(body.contains("/state"), body)
    // Confirms it is the built bundle, not the missing-resource fallback.
    XCTAssertGreaterThan(body.count, 5_000, "served body looks like the fallback page")
    // The rename is complete — no "Flash Debug" anywhere.
    XCTAssertFalse(body.contains("Flash Debug"), body)
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

  private func fetch(url: URL, deadline: Date) throws -> String {
    var lastError: Error?
    while Date() < deadline {
      let sem = DispatchSemaphore(value: 0)
      var result: Result<String, Error>?
      URLSession.shared.dataTask(with: url) { data, _, error in
        if let error {
          result = .failure(error)
        } else {
          result = .success(String(data: data ?? Data(), encoding: .utf8) ?? "")
        }
        sem.signal()
      }.resume()
      _ = sem.wait(timeout: .now() + 0.25)
      if let result {
        switch result {
        case .success(let body):
          return body
        case .failure(let error):
          lastError = error
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if let lastError { throw lastError }
    return ""
  }
}
