import XCTest

@testable import flash

/// The socket protocol's pure parts: line framing, message decoding, one
/// connection's session, and a subscriber's bounded queue.
final class IPCProtocolTests: XCTestCase {
  private static func object(_ frame: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] ?? [:]
  }

  private static func line(_ object: [String: Any]) -> Data {
    IPCProtocol.frame(object).dropLast()
  }

  // MARK: - Framing

  func testFramesSplitOnNewlinesAcrossChunks() {
    var reader = IPCFrameReader(maxFrameBytes: 64)
    XCTAssertEqual(reader.append(Data(#"{"a":1}"#.utf8)), [])
    XCTAssertEqual(
      reader.append(Data("\n{\"b\":2}\n{\"c\"".utf8)),
      [.frame(Data(#"{"a":1}"#.utf8)), .frame(Data(#"{"b":2}"#.utf8))])
    XCTAssertEqual(reader.append(Data(":3}\n".utf8)), [.frame(Data(#"{"c":3}"#.utf8))])
  }

  func testBlankLinesAreSkipped() {
    var reader = IPCFrameReader(maxFrameBytes: 64)
    XCTAssertEqual(reader.append(Data("\n \r\n{}\n\n".utf8)), [.frame(Data("{}".utf8))])
  }

  func testALineOverTheLimitPoisonsTheStream() {
    var reader = IPCFrameReader(maxFrameBytes: 8)
    XCTAssertEqual(reader.append(Data("12345678\n".utf8)), [.frame(Data("12345678".utf8))])
    // Unterminated past the limit: no boundary can be trusted any more.
    XCTAssertEqual(reader.append(Data("123456789".utf8)), [.tooLarge])
    XCTAssertTrue(reader.poisoned)
    XCTAssertEqual(reader.append(Data("{}\n".utf8)), [])
    // Terminated, but too long.
    var other = IPCFrameReader(maxFrameBytes: 4)
    XCTAssertEqual(
      other.append(Data("{}\n12345\n{}\n".utf8)), [.frame(Data("{}".utf8)), .tooLarge])
  }

  // MARK: - Decoding

  func testClientMessagesDecode() {
    XCTAssertEqual(
      try IPCProtocol.decodeClientMessage(Self.line(["type": "hello", "protocol": 1])).get(),
      .hello(protocolVersion: 1, client: nil))
    XCTAssertEqual(
      try IPCProtocol.decodeClientMessage(
        Self.line(["type": "request", "id": "7", "words": ["tab", "next"], "cwd": "/tmp"])
      ).get(),
      .request(id: "7", words: ["tab", "next"], cwd: "/tmp"))
    XCTAssertEqual(
      try IPCProtocol.decodeClientMessage(
        Self.line(["type": "subscribe", "id": "s", "events": ["core:mode.*"]])
      ).get(),
      .subscribe(id: "s", events: ["core:mode.*"]))
  }

  func testMalformedLinesAreFatalAndBadFieldsAnswerTheirID() {
    func code(_ frame: Data) -> (IPCProtocol.ErrorCode, String?)? {
      guard case .failure(let rejection) = IPCProtocol.decodeClientMessage(frame) else {
        return nil
      }
      return (rejection.code, rejection.id)
    }
    XCTAssertEqual(code(Data("not json".utf8))?.0, .malformed)
    XCTAssertEqual(code(Data("[1]".utf8))?.0, .malformed)
    XCTAssertEqual(code(Self.line(["type": "dance"]))?.0, .malformed)
    XCTAssertEqual(code(Self.line(["type": "hello", "protocol": "1"]))?.0, .malformed)
    XCTAssertEqual(code(Self.line(["type": "hello", "protocol": true]))?.0, .malformed)
    XCTAssertEqual(code(Self.line(["type": "hello", "protocol": 1, "x": 1]))?.0, .malformed)
    // Without a trustworthy id nothing can be answered: fatal.
    XCTAssertEqual(code(Self.line(["type": "request", "words": ["a"]]))?.0, .malformed)
    XCTAssertEqual(
      code(Self.line(["type": "request", "id": "", "words": ["a"]]))?.0, .malformed)
    // With one, the request alone is refused.
    for bad: [String: Any] in [
      ["type": "request", "id": "1", "words": []],
      ["type": "request", "id": "1", "words": [1]],
      ["type": "request", "id": "1", "words": ["a"], "cwd": "relative"],
      ["type": "request", "id": "1", "words": ["a"], "extra": true],
      ["type": "subscribe", "id": "1", "events": "core:*"],
    ] {
      XCTAssertEqual(code(Self.line(bad))?.0, .invalidRequest, "\(bad)")
      XCTAssertEqual(code(Self.line(bad))?.1, "1", "\(bad)")
    }
  }

  func testSubscriptionsResolveToStreamedEventsOnly() throws {
    XCTAssertEqual(
      try IPCProtocol.resolveSubscription(["core:hints.*", "core:mode.changed"]).get(),
      ["core:hints.cancelled", "core:hints.committed", "core:hints.shown", "core:mode.changed"])
    let all = try IPCProtocol.resolveSubscription(["core:*"]).get()
    XCTAssertEqual(Set(all), Set(IPCProtocol.streamedEvents))
    // Plugin plumbing never leaves the process: an AX notification is posted
    // by every keystroke.
    for plumbing in [
      "core:apps.changed", "core:ax.changed", "core:session.opened", "core:status.observed",
    ] {
      XCTAssertFalse(all.contains(plumbing), plumbing)
      guard case .failure(let rejection) = IPCProtocol.resolveSubscription([plumbing]) else {
        return XCTFail(plumbing)
      }
      XCTAssertEqual(rejection.code, .unknownEvent)
    }
    XCTAssertEqual(try IPCProtocol.resolveSubscription([]).get(), [])
  }

  func testOnlyPerRequestErrorsKeepTheConnection() {
    let kept = IPCProtocol.ErrorCode.allCases.filter { !$0.closesConnection }
    XCTAssertEqual(kept, [.invalidRequest, .tooManyRequests, .unknownEvent, .replyTooLarge])
  }

  func testTheResultFrameCarriesTheCLIsReplyObject() throws {
    let result = CommandInvocationResult.failed("no tab", output: "x")
    let frame = IPCProtocol.resultFrame(id: "9", result: result)
    XCTAssertEqual(frame.last, 0x0A)
    let object = Self.object(frame)
    XCTAssertEqual(object["type"] as? String, "result")
    let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["result"]))
    XCTAssertEqual(CommandInvocationResult(json: body), result)
    XCTAssertEqual(
      IPCProtocol.decodeServerMessage(frame.dropLast()), .result(id: "9", result))
  }

  // MARK: - Session

  private func session(maxInFlight: Int = 2) -> IPCSession {
    IPCSession(
      welcome: IPCProtocol.welcomeFrame(server: "Flash test", pid: 1),
      maxInFlightRequests: maxInFlight)
  }

  private func errors(_ actions: [IPCSession.Action]) -> [String] {
    actions.compactMap { action in
      guard case .send(let frame) = action else { return nil }
      let object = Self.object(frame)
      return object["type"] as? String == "error" ? object["code"] as? String : nil
    }
  }

  private func receive(_ session: inout IPCSession, _ object: [String: Any])
    -> [IPCSession.Action]
  {
    session.receive(.frame(Self.line(object)))
  }

  func testHelloMustComeFirst() {
    var session = session()
    let actions = receive(&session, ["type": "request", "id": "1", "words": ["tab", "next"]])
    XCTAssertEqual(errors(actions), ["handshake_required"])
    XCTAssertEqual(actions.last, .close)
    XCTAssertEqual(session.phase, .closed)
    XCTAssertEqual(receive(&session, ["type": "hello", "protocol": 1]), [])
  }

  func testAnotherVersionIsRefusedNamingThisOne() throws {
    var session = session()
    let actions = receive(&session, ["type": "hello", "protocol": 2])
    XCTAssertEqual(errors(actions), ["protocol_mismatch"])
    XCTAssertEqual(actions.last, .close)
    guard case .send(let frame) = try XCTUnwrap(actions.first) else { return XCTFail() }
    XCTAssertEqual(Self.object(frame)["protocol"] as? Int, IPCProtocol.version)
  }

  func testHelloOnceThenRequestsAndSubscriptions() {
    var session = session()
    let hello = receive(&session, ["type": "hello", "protocol": 1, "client": "test"])
    XCTAssertEqual(hello, [.send(session.welcome)])
    XCTAssertEqual(session.client, "test")
    XCTAssertEqual(
      receive(&session, ["type": "request", "id": "a", "words": ["tab", "next"], "cwd": "/"]),
      [.run(id: "a", invocation: CommandInvocation(words: ["tab", "next"], workingDirectory: "/"))])
    XCTAssertEqual(
      receive(&session, ["type": "subscribe", "id": "s", "events": ["core:mode.*"]]),
      [.subscribe(id: "s", events: ["core:mode.changed"])])
    XCTAssertEqual(
      errors(receive(&session, ["type": "subscribe", "id": "t", "events": ["core:nope"]])),
      ["unknown_event"])
    let again = receive(&session, ["type": "hello", "protocol": 1])
    XCTAssertEqual(errors(again), ["handshake_required"])
    XCTAssertEqual(again.last, .close)
  }

  func testInFlightRequestsAreBoundedAndTheirIDsUnique() {
    var session = session(maxInFlight: 2)
    _ = receive(&session, ["type": "hello", "protocol": 1])
    let request: (String) -> [String: Any] = { ["type": "request", "id": $0, "words": ["q"]] }
    XCTAssertEqual(receive(&session, request("1")).count, 1)
    XCTAssertEqual(errors(receive(&session, request("1"))), ["invalid_request"])
    XCTAssertEqual(receive(&session, request("2")).count, 1)
    XCTAssertEqual(errors(receive(&session, request("3"))), ["too_many_requests"])
    XCTAssertEqual(session.phase, .ready)
    session.finished(id: "1")
    XCTAssertEqual(receive(&session, request("1")).count, 1)
  }

  func testAnOverlongLineAndTheHandshakeDeadlineClose() {
    var session = session()
    XCTAssertEqual(errors(session.receive(.tooLarge)), ["frame_too_large"])
    XCTAssertEqual(session.phase, .closed)
    var waiting = self.session()
    XCTAssertEqual(errors(waiting.handshakeExpired()), ["handshake_timeout"])
    var ready = self.session()
    _ = receive(&ready, ["type": "hello", "protocol": 1])
    XCTAssertEqual(ready.handshakeExpired(), [])
  }

  // MARK: - A subscriber's queue

  private func event(_ name: String, _ size: Int = 10) -> Data {
    Data(repeating: 0x61, count: size)
  }

  /// A slow subscriber keeps the latest of each state signal, in emission
  /// order, and is cut off only when distinct events no longer fit.
  func testASlowSubscriberCoalescesStateThenOverflows() {
    var outbox = IPCOutbox(maxEvents: 3, maxEventBytes: 1_000)
    XCTAssertEqual(outbox.enqueueEvent(event("mode"), coalescingKey: "core:mode.changed"), .queued)
    XCTAssertEqual(outbox.enqueueEvent(event("launch"), coalescingKey: nil), .queued)
    XCTAssertEqual(
      outbox.enqueueEvent(event("mode"), coalescingKey: "core:mode.changed"), .coalesced)
    XCTAssertEqual(outbox.keys, [nil, "core:mode.changed"])
    XCTAssertEqual(outbox.eventCount, 2)
    XCTAssertEqual(outbox.enqueueEvent(event("launch"), coalescingKey: nil), .queued)
    XCTAssertEqual(outbox.enqueueEvent(event("launch"), coalescingKey: nil), .overflow)
    // Replies are never refused: the in-flight cap bounds them.
    outbox.enqueueReply(Data("reply".utf8))
    XCTAssertEqual(outbox.count, 4)
  }

  func testTheEventBytesAreBoundedToo() {
    var outbox = IPCOutbox(maxEvents: 100, maxEventBytes: 25)
    XCTAssertEqual(outbox.enqueueEvent(event("a", 20), coalescingKey: nil), .queued)
    XCTAssertEqual(outbox.enqueueEvent(event("b", 10), coalescingKey: nil), .overflow)
  }

  /// The frame being written is never coalesced away: half a line would
  /// corrupt the stream.
  func testAHalfWrittenFrameIsKept() {
    var outbox = IPCOutbox(maxEvents: 4, maxEventBytes: 1_000)
    _ = outbox.enqueueEvent(Data("first-mode\n".utf8), coalescingKey: "core:mode.changed")
    var taken = Data()
    XCTAssertTrue(
      outbox.drain { bytes in
        guard taken.isEmpty else { return 0 }
        taken.append(contentsOf: bytes.prefix(5))
        return 5
      })
    XCTAssertEqual(
      outbox.enqueueEvent(Data("second-mode\n".utf8), coalescingKey: "core:mode.changed"), .queued)
    XCTAssertEqual(outbox.keys, ["core:mode.changed", "core:mode.changed"])
    XCTAssertTrue(
      outbox.drain { bytes in
        taken.append(contentsOf: bytes)
        return bytes.count
      })
    XCTAssertEqual(String(decoding: taken, as: UTF8.self), "first-mode\nsecond-mode\n")
    XCTAssertTrue(outbox.isEmpty)
    XCTAssertEqual(outbox.eventCount, 0)
    XCTAssertEqual(outbox.eventBytes, 0)
  }

  func testAFinalFrameReplacesWhatWaitsButEndsTheLineInProgress() {
    var outbox = IPCOutbox(maxEvents: 4, maxEventBytes: 1_000)
    _ = outbox.enqueueEvent(Data("one\n".utf8), coalescingKey: nil)
    _ = outbox.enqueueEvent(Data("two\n".utf8), coalescingKey: nil)
    var taken = Data()
    _ = outbox.drain { bytes in
      guard taken.isEmpty else { return 0 }
      taken.append(contentsOf: bytes.prefix(2))
      return 2
    }
    outbox.replaceWithFinal(Data("bye\n".utf8))
    _ = outbox.drain { bytes in
      taken.append(contentsOf: bytes)
      return bytes.count
    }
    XCTAssertEqual(String(decoding: taken, as: UTF8.self), "one\nbye\n")
  }

  func testAFailedWriteIsReported() {
    var outbox = IPCOutbox()
    outbox.enqueueReply(Data("x\n".utf8))
    XCTAssertFalse(outbox.drain { _ in -1 })
  }
}
