import Foundation
import XCTest

@testable import flash

final class PluginBoundaryTests: XCTestCase {
  func testFrameEnvelopeRejectsCoercionAndContradictoryShapes() throws {
    for json in [
      #"{"id":true,"result":{"ok":true}}"#,
      #"{"id":1.0,"result":{"ok":true}}"#,
      #"{"id":0,"result":{"ok":true}}"#,
      #"{"id":1,"method":"ping","result":{"ok":true}}"#,
      #"{"id":1,"result":{"ok":true},"params":{}}"#,
      #"{"method":"status","params":[]}"#,
      #"{"method":"status","unknown":true}"#,
    ] {
      XCTAssertThrowsError(try PluginWireCodec.decodeFrame(Data(json.utf8)), json)
    }
    XCTAssertNoThrow(try PluginWireCodec.decodeFrame(Data(#"{"id":1,"result":{"ok":true}}"#.utf8)))
  }

  func testSharedWireValueCorpus() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "Plugins/_flash_plugin_specs/fixtures/wire-values.fixture"))
    let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for group in ["protocol_version", "boolean", "pid", "perform", "hints"] {
      for item in try XCTUnwrap(corpus[group] as? [[String: Any]]) {
        let expected = try XCTUnwrap(item["valid"] as? Bool)
        let accepted: Bool
        switch group {
        case "protocol_version":
          accepted = PluginWireCodec.acceptsProtocolVersion(["protocol_version": item["value"]!])
        case "boolean": accepted = PluginJSON.boolean(item["value"]) != nil
        case "pid": accepted = PluginJSON.pid(item["value"]) != nil
        case "perform":
          accepted =
            PluginWireCodec.validatedPerformResult(try XCTUnwrap(item["value"] as? [String: Any]))
            != nil
        default:
          accepted =
            PluginWireCodec.hintTargets(
              from: try XCTUnwrap(item["value"] as? [String: Any]), sourceID: "plugin:s",
              contextPID: 1) != nil
        }
        XCTAssertEqual(accepted, expected, "\(group): \(item["name"] ?? "")")
      }
    }
    for item in try XCTUnwrap(corpus["encoded_rows"] as? [[String: Any]]) {
      let rows = try XCTUnwrap(item["value"] as? [[String: Any]])
      let decoded = try XCTUnwrap(
        PluginWireCodec.catalogRows(from: rows, sourceID: "plugin:s", allowedSources: ["s"]))
      XCTAssertEqual(decoded.encodedBytes, try XCTUnwrap(item["encoded_bytes"] as? Int))
    }
  }

  func testLifecycleRejectsOldAttemptEventsAndExpiresFailuresByClock() {
    var lifecycle = PluginLifecycle()
    func send(_ event: PluginLifecycle.Event, at now: TimeInterval = 0) -> [PluginLifecycle.Effect]
    {
      lifecycle.transition(
        event, now: now, restartLimit: 2, restartWindow: 10, restartDelay: { $0 + 1 })
    }
    XCTAssertEqual(send(.start(resident: true)), [.start(1)])
    XCTAssertEqual(send(.installed(1)), [])
    XCTAssertEqual(send(.initialized(1)), [])
    XCTAssertEqual(send(.interrupted(1)), [.teardown, .retry(1, 1)])
    XCTAssertEqual(send(.retry(1)), [.start(2)])
    XCTAssertEqual(send(.installed(1)), [])
    XCTAssertEqual(lifecycle.state, .installing)
    XCTAssertEqual(send(.installed(2)), [])
    XCTAssertEqual(send(.initialized(2)), [])
    XCTAssertEqual(send(.interrupted(2), at: 11), [.teardown, .retry(2, 1)])
    XCTAssertEqual(send(.stop), [.teardown])
    XCTAssertEqual(send(.retry(2)), [])
    XCTAssertEqual(send(.initialized(2)), [])
    XCTAssertEqual(lifecycle.state, .stopped)
  }

  func testReloadInvalidatesBackoffBeforeStartingReplacement() {
    var lifecycle = PluginLifecycle()
    func send(_ event: PluginLifecycle.Event) -> [PluginLifecycle.Effect] {
      lifecycle.transition(
        event, now: 0, restartLimit: 2, restartWindow: 10, restartDelay: { _ in 1 })
    }
    _ = send(.start(resident: true))
    _ = send(.interrupted(1))
    XCTAssertEqual(send(.reload(resident: true)), [.teardown, .start(3)])
    XCTAssertEqual(send(.retry(1)), [])
    XCTAssertEqual(lifecycle.generation, 3)
  }

  func testTransportAdmissionRecoversCapacityWithoutAcceptingStaleReleases() throws {
    var budget = PluginTransportBudget()
    XCTAssertNil(budget.reserve(.readChunks, bytes: 1))
    budget.begin(1)
    let old = try XCTUnwrap(budget.reserve(.writeFrames, bytes: PluginProtocol.maxOutboundBytes))
    XCTAssertNil(budget.reserve(.writeFrames, bytes: 1))
    budget.begin(2)
    let current = try XCTUnwrap(
      budget.reserve(.writeFrames, bytes: PluginProtocol.maxOutboundBytes))
    budget.release(old)
    XCTAssertNil(
      budget.reserve(.writeFrames, bytes: 1), "old child cannot release new child's budget")
    budget.release(current)
    XCTAssertNotNil(budget.reserve(.writeFrames, bytes: PluginProtocol.maxOutboundBytes))
    for _ in 0..<PluginProtocol.maxInboundFrames {
      XCTAssertNotNil(budget.reserve(.readFrames, bytes: 1))
    }
    XCTAssertNil(budget.reserve(.readFrames, bytes: 1), "tiny frames must be bounded by count too")
    XCTAssertTrue(budget.fail(generation: 2))
    XCTAssertFalse(budget.fail(generation: 2), "overflow schedules only one teardown")
    XCTAssertNil(budget.reserve(.readChunks, bytes: 1), "failed transport cannot enqueue more work")
    budget.begin(3)
    XCTAssertFalse(budget.fail(generation: 2))
    XCTAssertNotNil(budget.reserve(.readChunks, bytes: 1))
  }
}
