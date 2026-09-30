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
        "Plugins/_flash_plugin_rust/fixtures/wire-values.fixture"))
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

  /// The `status_observed` group pins what a `core:status.observed` payload
  /// may be; every payload the host builds must be one the SDK accepts.
  func testStatusObservedPayloadsTheHostBuildsSatisfyTheSharedCorpus() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "Plugins/_flash_plugin_rust/fixtures/wire-values.fixture"))
    let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    func accepted(_ payload: [String: Any]) -> Bool {
      guard let segments = payload["segments"] as? [Any] else { return false }
      let names = segments.compactMap { $0 as? String }
      return names.count == segments.count && !names.contains("")
        && Set(names).count == names.count
    }
    for item in try XCTUnwrap(corpus["status_observed"] as? [[String: Any]]) {
      let value = try XCTUnwrap(item["value"] as? [String: Any])
      let valid = try XCTUnwrap(item["valid"] as? Bool)
      XCTAssertEqual(accepted(value), valid, "status_observed: \(item["name"] ?? "")")
      guard valid, let names = value["segments"] as? [String] else { continue }
      let built = PluginProcess.statusObservedSegments(
        Set(names).union(["undeclared"]), declared: names.reversed() + ["other"])
      XCTAssertEqual(built, names.sorted(), "\(item["name"] ?? "")")
    }
    for (observed, declared) in [
      (Set(["", "b", "a", "x"]), ["", "a", "b"]), ([], ["a"]), (["a"], []),
    ] {
      let segments = PluginProcess.statusObservedSegments(observed, declared: declared)
      XCTAssertTrue(accepted(["segments": segments]), "\(segments)")
      XCTAssertEqual(segments, segments.sorted())
    }
  }

  /// The `ax_changed` group pins what a `core:ax.changed` payload may be;
  /// every payload the host builds must be one the SDK accepts.
  func testAXChangedPayloadsTheHostBuildsSatisfyTheSharedCorpus() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "Plugins/_flash_plugin_rust/fixtures/wire-values.fixture"))
    let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    func accepted(_ payload: [String: Any]) -> Bool {
      guard PluginJSON.pid(payload["pid"]) != nil,
        let notification = payload["notification"] as? String
      else { return false }
      return !notification.isEmpty
    }
    for item in try XCTUnwrap(corpus["ax_changed"] as? [[String: Any]]) {
      let value = try XCTUnwrap(item["value"] as? [String: Any])
      let valid = try XCTUnwrap(item["valid"] as? Bool)
      XCTAssertEqual(accepted(value), valid, "ax_changed: \(item["name"] ?? "")")
    }
    for notification in AppMonitor.observedNotifications {
      let event = PluginEvent.axChanged(pid: 42, notification: notification, bundleID: nil)
      XCTAssertEqual(event.name, "core:ax.changed")
      XCTAssertTrue(accepted(event.payload), notification)
      XCTAssertEqual(
        PluginProtocol.coalescingKey(eventName: event.name, payload: event.payload),
        "core:ax.changed\u{0}42\u{0}\(notification)")
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

  func testStderrFloodBeforeTheInitializeReplyNeverWedgesTheTransport() throws {
    // stderr is diagnostics only and the host drains it on the pipe callback,
    // so a plugin writing far more than the pipe buffer before its first reply
    // still reaches `running`. A host that queued stderr behind the lifecycle
    // queue, or never read it, would block the child here and time out
    // initialize.
    let fixture = try PluginFixtureKit.make(
      id: "stderrflood",
      manifest: PluginFixtureKit.manifest(id: "stderrflood"),
      script: PluginFixtureKit.script(
        onInitialize: """
          head -c 262144 /dev/zero | tr '\\0' x >&2
          \(PluginFixtureKit.initializeOK)
          """))
    defer { fixture.cleanup() }
    let process = PluginProcess(
      root: fixture.root,
      manifest: try PluginManifest.load(from: fixture.root),
      origin: .official,
      baseDataDir: fixture.baseDataDir,
      watchFiles: false)
    process.start()
    waitUntilTrue("running after a 256 KiB stderr flood") {
      process.runtimeStateSnapshot() == .running
    }
    process.stopAndWait(reason: "test")
  }

  /// A child that briefly stops reading stdin must not be restarted for a
  /// burst of pure state signals: while a replacement event waits unsent, a
  /// newer one with the same coalescing key replaces it. The child then reads
  /// the latest event of every key, in emission order, and every other frame
  /// in FIFO order.
  func testReplacementEventBurstToAStalledChildCoalescesInsteadOfOverflowing() throws {
    let fixture = try PluginFixtureKit.make(
      id: "stalled",
      manifest: PluginFixtureKit.manifest(id: "stalled", extra: #""listen": ["core:*"]"#),
      script: PluginFixtureKit.script(
        onInitialize: """
          \(PluginFixtureKit.initializeOK)
          while [ ! -f "$D/go" ]; do sleep 0.02; done
          exec cat >> "$D/events"
          """))
    defer { fixture.cleanup() }
    let process = PluginProcess(
      root: fixture.root,
      manifest: try PluginManifest.load(from: fixture.root),
      origin: .official,
      baseDataDir: fixture.baseDataDir,
      watchFiles: false)
    process.start()
    defer { process.stopAndWait(reason: "test") }
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }

    // Far beyond the pipe buffer plus the 256-frame outbound budget.
    let burst = 4 * PluginProtocol.maxOutboundFrames * 8
    var latest: [String: Int] = [:]
    for sequence in 0..<burst {
      let pid = 100 + sequence % 3
      let notification = sequence % 2 == 0 ? "AXValueChanged" : "AXTitleChanged"
      latest["\(pid) \(notification)"] = sequence
      process.sendEvent(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["notification": notification, "pid": pid, "sequence": sequence],
          bundleID: "dev.flash.stalled"))
      if sequence % 1_000 == 0 {
        process.sendEvent(
          PluginEvent(
            name: "core:apps.launched", payload: ["sequence": sequence], bundleID: nil))
      }
    }
    process.sendEvent(
      PluginEvent(name: "core:apps.launched", payload: ["sequence": burst], bundleID: nil))
    settleRunLoop(0.5)
    FileManager.default.createFile(
      atPath: fixture.dataDir.appendingPathComponent("go").path, contents: Data())

    func delivered() -> [[String: Any]] {
      guard
        let text = try? String(
          contentsOf: fixture.dataDir.appendingPathComponent("events"), encoding: .utf8)
      else { return [] }
      return text.split(separator: "\n").compactMap {
        let frame = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        return frame?["params"] as? [String: Any]
      }
    }
    func sequence(_ event: [String: Any]) -> Int? {
      (event["payload"] as? [String: Any])?["sequence"] as? Int
    }
    waitUntilTrue("the burst's final marker") {
      delivered().contains {
        $0["name"] as? String == "core:apps.launched" && sequence($0) == burst
      }
    }
    XCTAssertEqual(fixture.spawnCount(), 1, "the stalled child was never restarted")
    XCTAssertEqual(process.runtimeStateSnapshot(), .running)
    XCTAssertNil(process.statusSnapshot().lastError)

    let events = delivered()
    let ordered = events.compactMap(sequence)
    XCTAssertEqual(ordered, ordered.sorted(), "a subsequence of emission order")
    let markers = events.filter { $0["name"] as? String == "core:apps.launched" }
    XCTAssertEqual(
      markers.compactMap(sequence), Array(stride(from: 0, to: burst, by: 1_000)) + [burst],
      "non-replacement events are never coalesced")
    var received: [String: Int] = [:]
    for event in events where event["name"] as? String == "core:ax.changed" {
      let payload = try XCTUnwrap(event["payload"] as? [String: Any])
      let key = "\(payload["pid"] as? Int ?? 0) \(payload["notification"] as? String ?? "")"
      received[key] = sequence(event)
    }
    XCTAssertEqual(received, latest, "the latest event of every key arrives")
    XCTAssertLessThan(events.count, burst / 2, "superseded frames were dropped")
  }

  func testOnlyReplacementEventsCoalesceAndAXChangesKeyByAppAndNotification() {
    func key(_ name: String, _ payload: [String: Any] = [:]) -> String? {
      PluginProtocol.coalescingKey(eventName: name, payload: payload)
    }
    for name in PluginProtocol.hostEvents
    where !PluginProtocol.replacementEvents.contains(name) {
      XCTAssertNil(key(name, ["pid": 1]), name)
    }
    XCTAssertNil(key("core:poll:tick"))
    XCTAssertEqual(key("core:focus.changed", ["pid": 1]), key("core:focus.changed", ["pid": 2]))
    XCTAssertNotEqual(key("core:focus.changed"), key("core:space.changed"))
    let title = key("core:ax.changed", ["pid": 7, "notification": "AXTitleChanged"])
    XCTAssertEqual(title, key("core:ax.changed", ["notification": "AXTitleChanged", "pid": 7]))
    XCTAssertNotEqual(title, key("core:ax.changed", ["pid": 7, "notification": "AXValueChanged"]))
    XCTAssertNotEqual(title, key("core:ax.changed", ["pid": 8, "notification": "AXTitleChanged"]))
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
