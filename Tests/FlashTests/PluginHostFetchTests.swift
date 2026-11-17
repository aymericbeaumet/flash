import Foundation
import XCTest
import os

@testable import flash

private final class FetchFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let handler = OSAllocatedUnfairLock<((FetchFixtureProtocol) -> Void)?>(initialState: nil)

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.handler.withLock { $0 }?(self)
  }

  override func stopLoading() {}

  func respond(headers: [String: String] = [:], chunks: [Data], finish: Bool = true) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }

  func redirect(to url: URL) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
      headerFields: ["Location": url.absoluteString])!
    client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
  }
}

final class PluginHostFetchTests: XCTestCase {
  private func fetch(
    _ url: String = "https://allowed.test/api/start",
    handler: @escaping (FetchFixtureProtocol) -> Void
  ) throws -> Result<PluginHostFetch.Payload, PluginHostFetch.Failure> {
    FetchFixtureProtocol.handler.withLock { $0 = handler }
    defer { FetchFixtureProtocol.handler.withLock { $0 = nil } }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FetchFixtureProtocol.self]
    let reply = expectation(description: "fetch settles")
    reply.assertForOverFulfill = true
    let received = OSAllocatedUnfairLock<Result<PluginHostFetch.Payload, PluginHostFetch.Failure>?>(
      initialState: nil)
    let task = PluginHostFetch.start(
      request: URLRequest(url: try XCTUnwrap(URL(string: url))),
      allowlist: ["https://allowed.test/api"], configuration: configuration
    ) { result in
      XCTAssertFalse(Thread.isMainThread, "host fetch must never run its callback on main")
      received.withLock { $0 = result }
      reply.fulfill()
    }
    defer { task.cancel() }
    wait(for: [reply], timeout: 2)
    return try XCTUnwrap(received.withLock { $0 })
  }

  func testRejectsRedirectBeforeContactingAnUnallowlistedDestination() throws {
    let destinations = OSAllocatedUnfairLock<[String]>(initialState: [])
    let result = try fetch { fixture in
      destinations.withLock { $0.append(fixture.request.url!.host!) }
      if fixture.request.url?.host == "allowed.test" {
        fixture.redirect(to: URL(string: "https://private.test/internal")!)
      } else {
        fixture.respond(chunks: [Data("private response".utf8)])
      }
    }
    guard case .failure(.disallowedRedirect) = result else {
      return XCTFail("redirect escaped allowlist: \(result)")
    }
    XCTAssertEqual(destinations.withLock { $0 }, ["allowed.test"])
  }

  func testAllowsRedirectOnlyWithinTheApprovedPrefix() throws {
    let result = try fetch { fixture in
      if fixture.request.url?.path == "/api/start" {
        fixture.redirect(to: URL(string: "https://allowed.test/api/final")!)
      } else {
        fixture.respond(chunks: [Data("allowed".utf8)])
      }
    }
    guard case .success(let payload) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(payload.data, Data("allowed".utf8))
    XCTAssertEqual(payload.status, 200)
  }

  func testOversizedStreamSettlesBeforeTheServerFinishes() throws {
    let result = try fetch { fixture in
      fixture.respond(
        chunks: [Data(repeating: 120, count: PluginProtocol.maxFetchResponseBytes + 1)],
        finish: false)
    }
    guard case .failure(.oversized) = result else { return XCTFail("\(result)") }
  }

  func testOversizedContentLengthIsRejectedWithoutWaitingForTheBody() throws {
    let result = try fetch { fixture in
      // CFNetwork batches mock headers with an initial input buffer. Flush
      // that buffer, then withhold the rest of the declared oversized body.
      fixture.respond(
        headers: ["Content-Length": String(PluginProtocol.maxFetchResponseBytes + 1)],
        chunks: [Data(repeating: 120, count: 64 * 1024)], finish: false)
    }
    guard case .failure(.oversized) = result else { return XCTFail("\(result)") }
  }

  func testAcceptsStreamingBodyExactlyAtTheByteLimit() throws {
    let first = Data(repeating: 120, count: PluginProtocol.maxFetchResponseBytes - 3)
    let result = try fetch { fixture in
      fixture.respond(chunks: [first, Data("end".utf8)])
    }
    guard case .success(let payload) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(payload.data.count, PluginProtocol.maxFetchResponseBytes)
    XCTAssertEqual(payload.data.suffix(3), Data("end".utf8))
  }

  func testRejectsRedirectOutsideApprovedPathOnTheSameHost() throws {
    let result = try fetch { fixture in
      if fixture.request.url?.path == "/api/start" {
        fixture.redirect(to: URL(string: "https://allowed.test/private")!)
      } else {
        fixture.respond(chunks: [Data("private".utf8)])
      }
    }
    guard case .failure(.disallowedRedirect) = result else { return XCTFail("\(result)") }
  }

  func testRejectsRedirectFromHTTPSIntoHTTP() throws {
    let result = try fetch { fixture in
      if fixture.request.url?.scheme == "https" {
        fixture.redirect(to: URL(string: "http://allowed.test/api/final")!)
      } else {
        fixture.respond(chunks: [Data("insecure".utf8)])
      }
    }
    guard case .failure(.disallowedRedirect) = result else { return XCTFail("\(result)") }
  }

  func testRejectsUnapprovedInitialURLBeforeStartingTheRequest() throws {
    let result = try fetch("https://private.test/internal") { _ in
      XCTFail("unapproved request reached the transport")
    }
    guard case .failure(.disallowedURL) = result else { return XCTFail("\(result)") }
  }

  func testCancellationSettlesOnceOffMain() throws {
    let started = expectation(description: "request started")
    FetchFixtureProtocol.handler.withLock { handler in
      handler = { _ in started.fulfill() }
    }
    defer { FetchFixtureProtocol.handler.withLock { $0 = nil } }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FetchFixtureProtocol.self]
    let replied = expectation(description: "cancellation settles")
    replied.assertForOverFulfill = true
    let task = PluginHostFetch.start(
      request: URLRequest(url: URL(string: "https://allowed.test/api")!),
      allowlist: ["https://allowed.test/api"], configuration: configuration
    ) { result in
      XCTAssertFalse(Thread.isMainThread)
      guard case .failure(.transport(let error)) = result else {
        replied.fulfill()
        return XCTFail("\(result)")
      }
      XCTAssertEqual((error as NSError).code, NSURLErrorCancelled)
      replied.fulfill()
    }
    wait(for: [started], timeout: 2)
    task.cancel()
    wait(for: [replied], timeout: 2)
  }

  func testAllowlistChecksNormalizedOriginsAndPaths() {
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed(
        "https://allowed.test/api/../private", byPrefix: "https://allowed.test/api"))
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed(
        "https://allowed.test/api/%2e%2e/private", byPrefix: "https://allowed.test/api"))
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed(
        "https://user:secret@allowed.test/api", byPrefix: "https://user:secret@allowed.test/api"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed(
        "https://ALLOWED.test:443/api/value", byPrefix: "https://allowed.test/api"))
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed(
        "https://allowed.test:8443/api/value", byPrefix: "https://allowed.test/api"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://127.0.0.1/api", byPrefix: "https://127.0.0.1/"))
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed("https://127.0.0.1/api", byPrefix: "https://allowed.test/api"))
  }
}
