import Network
import XCTest

@testable import flash

final class DebugServerTests: XCTestCase {
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

    let deadline = Date().addingTimeInterval(2)
    while server.listeningPort == nil, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    let port = try XCTUnwrap(server.listeningPort)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/state"))
    let body = try fetch(url: url, deadline: deadline)
    XCTAssertTrue(body.contains("\"ok\":true"), body)
  }

  func testServesSvelteInspectorBundle() throws {
    let server = DebugServer(host: "localhost", port: 0) {
      ["ok": true]
    }
    server.start()
    defer { server.stop() }

    let deadline = Date().addingTimeInterval(2)
    while server.listeningPort == nil, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    let port = try XCTUnwrap(server.listeningPort)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
    let body = try fetch(url: url, deadline: deadline)

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
