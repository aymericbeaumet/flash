import FlashOTLP
import Foundation
import XCTest

@testable import flash

/// The loopback OTLP/HTTP receiver: request framing, the checks that keep
/// browsers out, OTLP's status codes and partial success, and the socket
/// itself.
final class OTLPReceiverTests: XCTestCase {
  private let port: UInt16 = 4318

  private func store() -> TelemetryStore {
    TelemetryStore(scheduler: PollScheduler())
  }

  private func request(
    _ method: String = "POST", path: String = "/v1/metrics", host: String? = "127.0.0.1:4318",
    contentType: String? = "application/json", headers: [String: String] = [:],
    body: Data = Data("{}".utf8)
  ) -> OTLPHTTPRequest {
    var all = headers
    if let host { all["host"] = host }
    if let contentType { all["content-type"] = contentType }
    return OTLPHTTPRequest(method: method, path: path, headers: all, body: body)
  }

  private func respond(
    _ request: OTLPHTTPRequest, store: TelemetryStore? = nil, token: String = ""
  ) -> OTLPHTTPResponse {
    OTLPReceiver.respond(to: request, port: port, store: store ?? self.store(), token: token)
  }

  /// Every account and process shares the loopback address, and a metric
  /// can drive a monitor whose `run` executes. With `token` set, a request
  /// without it (or with another) is refused before anything is decoded.
  func testATokenIsRequiredOnceConfigured() {
    let token = "s3cret-0123456789"
    let store = store()
    XCTAssertEqual(respond(request(), store: store, token: token).status, 401)
    XCTAssertEqual(
      respond(request(headers: ["authorization": "Bearer nope"]), store: store, token: token)
        .status,
      401)
    XCTAssertEqual(
      respond(request(headers: ["authorization": "Basic \(token)"]), store: store, token: token)
        .status, 401)
    XCTAssertEqual(store.counterSnapshot().counters.requests, [:], "nothing refused is counted")
    XCTAssertEqual(
      respond(request(headers: ["authorization": "Bearer \(token)"]), store: store, token: token)
        .status, 200)
    XCTAssertEqual(respond(request()).status, 200, "without a token configured, none is asked")
  }

  // MARK: Answers

  func testAnEmptyExportSucceedsWithAnEmptyBody() {
    let json = respond(request())
    XCTAssertEqual(json.status, 200)
    XCTAssertEqual(json.contentType, "application/json")
    XCTAssertEqual(String(decoding: json.body, as: UTF8.self), "{}")
    let protobuf = respond(request(contentType: "application/x-protobuf", body: Data()))
    XCTAssertEqual(protobuf.status, 200)
    XCTAssertEqual(protobuf.contentType, "application/x-protobuf")
    XCTAssertEqual(protobuf.body, Data())
  }

  func testEachSignalHasItsPath() throws {
    let store = store()
    for (path, fixture) in [
      ("/v1/metrics", "metrics.json"), ("/v1/logs", "logs.json"), ("/v1/traces", "trace.json"),
    ] {
      let body = try TelemetryStoreTests.fixture(fixture)
      XCTAssertEqual(respond(request(path: path, body: body), store: store).status, 200, path)
    }
    let snapshot = store.counterSnapshot()
    XCTAssertEqual(snapshot.series, 4)
    XCTAssertEqual(snapshot.logs, 1)
    XCTAssertEqual(snapshot.spans, 1)
    XCTAssertEqual(snapshot.counters.requests, [.metrics: 1, .logs: 1, .traces: 1])
  }

  func testRejectedPointsAnswerAPartialSuccess() throws {
    let body = Data(
      #"{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"ok","gauge":{"dataPoints":[{"asInt":"1","timeUnixNano":"1"}]}},{"name":"bad","gauge":{"dataPoints":[{"timeUnixNano":"1"}]}}]}]}]}"#
        .utf8)
    let json = respond(request(body: body))
    XCTAssertEqual(json.status, 200)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: json.body) as? [String: Any])
    let partial = try XCTUnwrap(object["partialSuccess"] as? [String: Any])
    XCTAssertEqual(partial["rejectedDataPoints"] as? String, "1")
    XCTAssertEqual(
      partial["errorMessage"] as? String, "1 data point rejected: a number point without a value")

    guard case .metrics(let decoded) = try OTLPCodec.decode(body, signal: .metrics, encoding: .json)
    else { return XCTFail("not metrics") }
    let protobuf = respond(
      request(contentType: "application/x-protobuf", body: try decoded.serializedData()))
    let response = try OTLPMetricsResponse(serializedBytes: protobuf.body)
    XCTAssertEqual(response.partialSuccess.rejectedDataPoints, 1)
  }

  func testGzipBodiesAreInflated() throws {
    let body = OTLPCodec.gzip(try TelemetryStoreTests.fixture("metrics.binpb"))
    let store = store()
    let response = respond(
      request(
        contentType: "application/x-protobuf", headers: ["content-encoding": "gzip"], body: body),
      store: store)
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(store.counterSnapshot().series, 4)
    XCTAssertEqual(
      respond(request(headers: ["content-encoding": "gzip"], body: Data("not gzip".utf8)))
        .status, 400)
    XCTAssertEqual(
      respond(request(headers: ["content-encoding": "br"])).status, 415)
  }

  func testAGzipBombIsRefusedWhileInflating() {
    let bomb = OTLPCodec.gzip(Data(count: OTLPReceiver.maxDecodedBytes + 1))
    XCTAssertLessThan(bomb.count, OTLPReceiver.maxBodyBytes)
    let response = respond(request(headers: ["content-encoding": "gzip"], body: bomb))
    XCTAssertEqual(response.status, 413)
  }

  func testUndecodableBodiesAreBadRequestsWithAStatus() throws {
    let json = respond(request(body: Data("{".utf8)))
    XCTAssertEqual(json.status, 400)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json.body) as? [String: Any])
    XCTAssertEqual(object["code"] as? Int, 3)
    XCTAssertEqual(object["message"] as? String, "request body is not JSON")
    let protobuf = respond(
      request(contentType: "application/x-protobuf", body: Data([0x0A, 0xFF])))
    XCTAssertEqual(protobuf.status, 400)
    // google.rpc.Status: code 3, then the message.
    XCTAssertEqual(Array(protobuf.body.prefix(2)), [0x08, 0x03])
    XCTAssertTrue(
      String(decoding: protobuf.body, as: UTF8.self).contains("invalid protobuf metrics request"))
  }

  func testOnlyPostToTheThreeSignalsIsServed() {
    XCTAssertEqual(respond(request(path: "/v1/profiles")).status, 404)
    XCTAssertEqual(respond(request(path: "/")).status, 404)
    let get = respond(request("GET"))
    XCTAssertEqual(get.status, 405)
    XCTAssertEqual(get.headers.first { $0.0 == "Allow" }?.1, "POST")
    XCTAssertEqual(respond(request("OPTIONS")).status, 405)
  }

  func testOnlyTheTwoOTLPMediaTypesAreAccepted() {
    for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
      XCTAssertEqual(respond(request(contentType: type)).status, 415, type)
    }
    XCTAssertEqual(respond(request(contentType: nil)).status, 415)
    XCTAssertEqual(respond(request(contentType: "application/json; charset=utf-8")).status, 200)
  }

  /// A web page can make the user's browser send a POST anywhere; it always
  /// carries the page's `Origin`, and a rebinding page carries its own
  /// hostname as `Host`. Neither reaches the store, and no answer opens CORS.
  func testBrowsersAreKeptOut() {
    let store = store()
    let crossOrigin = respond(
      request(headers: ["origin": "https://evil.example"]), store: store)
    XCTAssertEqual(crossOrigin.status, 403)
    XCTAssertEqual(
      respond(request(headers: ["origin": "null"]), store: store).status, 403)
    XCTAssertEqual(
      respond(request(headers: ["origin": "http://127.0.0.1:9999"]), store: store).status, 403)
    XCTAssertEqual(
      respond(request(headers: ["sec-fetch-site": "cross-site"]), store: store).status, 403)
    XCTAssertEqual(respond(request(host: "evil.example:4318"), store: store).status, 403)
    XCTAssertEqual(respond(request(host: "127.0.0.1:4242"), store: store).status, 403)
    XCTAssertEqual(respond(request(host: nil), store: store).status, 403)
    XCTAssertEqual(store.counterSnapshot().counters.requests, [:])
    for response in [crossOrigin, respond(request())] {
      XCTAssertFalse(
        response.headers.contains { $0.0.lowercased().hasPrefix("access-control-") })
      XCTAssertFalse(
        String(decoding: response.serialized, as: UTF8.self).lowercased()
          .contains("access-control"))
    }
    // Same-origin and non-browser senders are served.
    XCTAssertEqual(respond(request(headers: ["origin": "http://localhost:4318"])).status, 200)
    XCTAssertEqual(respond(request(host: "localhost:4318")).status, 200)
  }

  func testFlashsOwnExportIsNeverTakenBack() {
    let response = respond(
      request(headers: ["user-agent": OTLPReceiver.exporterUserAgentPrefix + "1.2.0"]))
    XCTAssertEqual(response.status, 403)
  }

  func testErrorsCarryTheirStatusAndCloseTheConnection() {
    let text = String(
      decoding: OTLPHTTPResponse.error(413, "too large", encoding: .json).serialized, as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"), text)
    XCTAssertTrue(text.contains("Connection: close\r\n"), text)
    XCTAssertTrue(text.hasSuffix(#"{"code":8,"message":"too large"}"#), text)
  }

  // MARK: Framing

  private func assemble(_ text: String, body: Data = Data(), maxBody: Int = 1024)
    -> OTLPHTTP.Assembly
  {
    var data = Data(text.utf8)
    data.append(body)
    return OTLPHTTP.assemble(data, maxBody: maxBody)
  }

  func testAContentLengthBodyIsReadWhole() {
    let head = "POST /v1/logs?x=1 HTTP/1.1\r\nHost: 127.0.0.1:4318\r\nContent-Length: 5\r\n\r\n"
    XCTAssertEqual(assemble(head, body: Data("abc".utf8)), .incomplete(expectsContinue: false))
    guard case .ready(let request) = assemble(head, body: Data("abcdef".utf8)) else {
      return XCTFail("not ready")
    }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/v1/logs")
    XCTAssertEqual(request.header("host"), "127.0.0.1:4318")
    XCTAssertEqual(request.body, Data("abcde".utf8))
  }

  func testAChunkedBodyIsDecoded() {
    let head = "POST /v1/metrics HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
    XCTAssertEqual(
      assemble(head, body: Data("3\r\nabc\r\n".utf8)), .incomplete(expectsContinue: false))
    guard
      case .ready(let request) = assemble(
        head, body: Data("3;ext=1\r\nabc\r\nA\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n".utf8))
    else { return XCTFail("not ready") }
    XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "abc0123456789")
    XCTAssertEqual(
      assemble(head, body: Data("3\r\nabcX\r\n0\r\n\r\n".utf8)),
      .malformed("malformed chunked body"))
    XCTAssertEqual(
      assemble(head, body: Data("zz\r\n".utf8)), .malformed("malformed chunked body"))
    XCTAssertEqual(
      assemble(head, body: Data("800\r\n".utf8), maxBody: 1024), .tooLarge)
  }

  func testExpectContinueIsAnswered() {
    XCTAssertEqual(
      assemble(
        "POST /v1/metrics HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
      ),
      .incomplete(expectsContinue: true))
  }

  func testFramingAbusesAreRefused() {
    XCTAssertEqual(
      assemble("POST /v1/metrics HTTP/1.1\r\nContent-Length: 2000\r\n\r\n"), .tooLarge)
    XCTAssertEqual(
      assemble(
        "POST /v1/metrics HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n"),
      .malformed("Content-Length and Transfer-Encoding together"))
    XCTAssertEqual(
      assemble("POST /v1/metrics HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"),
      .malformed("unsupported Transfer-Encoding"))
    XCTAssertEqual(
      assemble("POST /v1/metrics HTTP/1.1\r\nContent-Length: -1\r\n\r\n"),
      .malformed("malformed Content-Length"))
    XCTAssertEqual(
      assemble("POST /v1/metrics HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n"),
      .malformed("malformed header line"))
    XCTAssertEqual(assemble("GARBAGE\r\n\r\n"), .malformed("malformed request line"))
    XCTAssertEqual(
      OTLPHTTP.assemble(Data(count: OTLPReceiver.maxHeaderBytes + 1), maxBody: 10), .tooLarge)
  }

  // MARK: The socket

  private func startReceiver(_ store: TelemetryStore) throws -> (OTLPReceiver, UInt16) {
    let receiver = OTLPReceiver(port: 0, store: store)
    let listening = expectation(description: "listening")
    var bound: UInt16?
    receiver.start()
    receiver.whenListening { port in
      bound = port
      listening.fulfill()
    }
    wait(for: [listening], timeout: 10)
    return (receiver, try XCTUnwrap(bound, "the receiver never listened"))
  }

  func testTheListenerBindsTheLoopbackAddressOnly() throws {
    let (receiver, port) = try startReceiver(store())
    defer { receiver.stop() }
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let output = Pipe()
    lsof.standardOutput = output
    lsof.standardError = FileHandle.nullDevice
    try lsof.run()
    lsof.waitUntilExit()
    let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(listing.contains("127.0.0.1:\(port) (LISTEN)"), listing)
    XCTAssertFalse(listing.contains("*:\(port)"), listing)
  }

  private func post(
    port: UInt16, path: String, type: String, body: Data, headers: [String: String] = [:]
  ) throws -> (status: Int, body: Data) {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue(type, forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let done = expectation(description: "response")
    var result: (Int, Data)?
    URLSession.shared.dataTask(with: request) { data, response, _ in
      result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 10)
    return try XCTUnwrap(result)
  }

  /// End to end over the socket: JSON and gzip protobuf exports land in
  /// the store and read back through the status format's value.
  func testRealExportsReadBackThroughTheStatusFormat() throws {
    let store = store()
    let (receiver, port) = try startReceiver(store)
    defer { receiver.stop() }
    let json = try post(
      port: port, path: "/v1/metrics", type: "application/json",
      body: TelemetryStoreTests.fixture("metrics.json"))
    XCTAssertEqual(json.status, 200)
    let protobuf = try post(
      port: port, path: "/v1/traces", type: "application/x-protobuf",
      body: OTLPCodec.gzip(TelemetryStoreTests.fixture("trace.binpb")),
      headers: ["Content-Encoding": "gzip"])
    XCTAssertEqual(protobuf.status, 200)
    let refused = try post(
      port: port, path: "/v1/metrics", type: "application/json", body: Data("{}".utf8),
      headers: ["Origin": "https://evil.example"])
    XCTAssertEqual(refused.status, 403)

    let template = FlashStatusBarTemplate(
      template: "#{flash.otel:my.gauge} #{flash.otel.total:my.counter[my.counter.attr=some value]}")
    var context = StatusFormatContext()
    context.values = store.values(for: template.program.dependencies.values)
    XCTAssertEqual(template.program.evaluate(context).text, "10 5")
    XCTAssertEqual(store.counterSnapshot().spans, 1)
    XCTAssertEqual(receiver.currentStatus.refused[403], 1)
  }

  /// curl frames its body chunked and waits for `100 Continue` when asked,
  /// as several SDKs do.
  func testCurlChunkedWithExpectContinue() throws {
    let store = store()
    let (receiver, port) = try startReceiver(store)
    defer { receiver.stop() }
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = [
      "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10",
      "-H", "Content-Type: application/json", "-H", "Transfer-Encoding: chunked",
      "-H", "Expect: 100-continue", "--data-binary",
      "@" + TelemetryStoreTests.fixtures.appendingPathComponent("logs.json").path,
      "http://127.0.0.1:\(port)/v1/logs",
    ]
    let output = Pipe()
    curl.standardOutput = output
    curl.standardError = FileHandle.nullDevice
    try curl.run()
    curl.waitUntilExit()
    XCTAssertEqual(
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "200")
    XCTAssertEqual(store.counterSnapshot().logs, 1)
  }
}
