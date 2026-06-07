import Network
import XCTest

@testable import flash

final class DebugServerTests: XCTestCase {
  func testParsesLoopbackHTTPHost() {
    let localhost = DebugServer.parse(hostPort: "localhost:4242")
    XCTAssertEqual(localhost?.host, "localhost")
    XCTAssertEqual(localhost?.port.rawValue, 4242)

    let ipv4 = DebugServer.parse(hostPort: "127.0.0.1:4343")
    XCTAssertEqual(ipv4?.host, "127.0.0.1")
    XCTAssertEqual(ipv4?.port.rawValue, 4343)

    let ipv6 = DebugServer.parse(hostPort: "[::1]:4444")
    XCTAssertEqual(ipv6?.host, "::1")
    XCTAssertEqual(ipv6?.port.rawValue, 4444)
  }

  func testRejectsNonLoopbackHTTPHost() {
    XCTAssertNil(DebugServer.parse(hostPort: "0.0.0.0:4242"))
    XCTAssertNil(DebugServer.parse(hostPort: "192.168.1.10:4242"))
    XCTAssertNil(DebugServer.parse(hostPort: "localhost"))
    XCTAssertNil(DebugServer.parse(hostPort: "localhost:not-a-port"))
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
    let server = DebugServer(hostPort: "localhost:0") {
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

  func testServesDenseDebugPageWithLiveLogControls() throws {
    let server = DebugServer(hostPort: "localhost:0") {
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

    XCTAssertTrue(body.contains("class=\"info-grid\""), body)
    XCTAssertTrue(body.contains("grid-template-columns: repeat(3, minmax(0, 1fr))"), body)
    XCTAssertTrue(body.contains("Current State"), body)
    XCTAssertTrue(body.contains("Loaded Plugins"), body)
    XCTAssertTrue(body.contains("id=\"logSearch\""), body)
    XCTAssertTrue(body.contains("id=\"logLevel\""), body)
    XCTAssertTrue(body.contains("id=\"logRows\""), body)
    XCTAssertTrue(body.contains("const rowHeight = 24"), body)
    XCTAssertTrue(body.contains("class=\"timestamp\""), body)
    XCTAssertTrue(body.contains("class=\"source\""), body)
    XCTAssertTrue(body.contains("level-warn"), body)
    XCTAssertFalse(body.contains("id=\"summary\""), body)
    XCTAssertFalse(body.contains("state xxxx"), body)
    XCTAssertFalse(body.contains("Recent Events"), body)
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
