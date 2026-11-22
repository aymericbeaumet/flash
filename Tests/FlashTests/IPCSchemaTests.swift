import AppKit
import XCTest

@testable import flash

/// `docs/schema/ipc/` pins every message of the socket protocol: each
/// message the CLI and the resident really encode validates against its
/// schema, the catalogs in the schemas are the code's, and the validator
/// itself refuses what the schemas forbid.
final class IPCSchemaTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let directory = root.appendingPathComponent("docs/schema/ipc")

  private var validator: JSONSchemaValidator!

  override func setUpWithError() throws {
    validator = try JSONSchemaValidator(directory: Self.directory)
  }

  private func assertValid(
    _ frame: Data, _ schema: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let json = frame.last == 0x0A ? frame.dropLast() : frame
    let text = String(decoding: json, as: UTF8.self)
    XCTAssertEqual(
      validator.problems(json: json, against: schema), [], text, file: file, line: line)
    let union =
      IPCProtocol.clientMessageTypes.contains(
        schema.replacingOccurrences(of: ".schema.json", with: ""))
      ? "client-message.schema.json" : "server-message.schema.json"
    XCTAssertEqual(
      validator.problems(json: json, against: union), [], "\(union): \(text)", file: file,
      line: line)
  }

  private func assertInvalid(
    _ object: [String: Any], _ schema: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    XCTAssertFalse(
      validator.problems(json: data, against: schema).isEmpty, "\(object)", file: file, line: line)
  }

  // MARK: - The documents

  func testEveryMessageHasASchemaAndTheUnionsListThemAll() throws {
    let expected = Set(
      (IPCProtocol.clientMessageTypes + IPCProtocol.serverMessageTypes).map { "\($0).schema.json" }
        + ["client-message.schema.json", "server-message.schema.json"])
    XCTAssertEqual(Set(validator.documents.keys), expected)
    for (file, document) in validator.documents {
      XCTAssertEqual(
        document["$schema"] as? String, "http://json-schema.org/draft-07/schema#", file)
      XCTAssertEqual(
        document["$id"] as? String,
        "https://raw.githubusercontent.com/aymericbeaumet/flash/main/docs/schema/ipc/\(file)", file)
      XCTAssertNotNil(document["description"] as? String, file)
    }
    func union(_ file: String) -> [String] {
      (validator.documents[file]?["oneOf"] as? [[String: String]] ?? []).compactMap { $0["$ref"] }
    }
    XCTAssertEqual(
      union("client-message.schema.json"),
      IPCProtocol.clientMessageTypes.map { "\($0).schema.json" })
    XCTAssertEqual(
      union("server-message.schema.json"),
      IPCProtocol.serverMessageTypes.map { "\($0).schema.json" })
  }

  func testTheSchemasNameTheCodesCatalogs() throws {
    func property(_ file: String, _ name: String) -> [String: Any] {
      ((validator.documents[file]?["properties"] as? [String: Any])?[name] as? [String: Any])
        ?? [:]
    }
    XCTAssertEqual(
      property("event.schema.json", "name")["enum"] as? [String], IPCProtocol.streamedEvents)
    let subscribed = property("subscribed.schema.json", "events")["items"] as? [String: Any]
    XCTAssertEqual(subscribed?["enum"] as? [String], IPCProtocol.streamedEvents)
    XCTAssertEqual(
      property("error.schema.json", "code")["enum"] as? [String],
      IPCProtocol.ErrorCode.allCases.map(\.rawValue))
    let limits = property("welcome.schema.json", "limits")["required"] as? [String]
    XCTAssertEqual(limits, IPCProtocol.Limits.standard.announced.keys.sorted())
    let variants = try XCTUnwrap(validator.documents["event.schema.json"]?["oneOf"] as? [Any])
    XCTAssertEqual(variants.count, IPCProtocol.streamedEvents.count)
  }

  // MARK: - What the CLI sends

  func testTheCLIsMessagesValidate() {
    assertValid(
      IPCProtocol.frame(IPCProtocol.helloMessage(client: "flash-cli 1.1.0")), "hello.schema.json")
    assertValid(IPCProtocol.frame(IPCProtocol.helloMessage(client: nil)), "hello.schema.json")
    assertValid(
      IPCProtocol.frame(
        IPCProtocol.requestMessage(id: "1", words: ["tab", "next"], cwd: "/Users/me")),
      "request.schema.json")
    assertValid(
      IPCProtocol.frame(IPCProtocol.requestMessage(id: "2", words: ["q"], cwd: "relative")),
      "request.schema.json")
    assertValid(
      IPCProtocol.frame(IPCProtocol.subscribeMessage(id: "3", events: ["core:*"])),
      "subscribe.schema.json")
    assertValid(
      IPCProtocol.frame(IPCProtocol.subscribeMessage(id: "4", events: [])),
      "subscribe.schema.json")
  }

  // MARK: - What the resident sends

  func testTheResidentsRepliesValidate() {
    assertValid(IPCProtocol.welcomeFrame(server: "Flash 1.1.0 (1)", pid: 42), "welcome.schema.json")
    for result in [
      CommandInvocationResult.succeeded(), .succeeded("out"), .failed("why", output: "out"),
      .rejected("'ta n' is ambiguous: new, next"),
      .local(.configCheck, arguments: ["file": "/tmp/x.toml"]),
      .local(.eventsWatch, arguments: [:]),
    ] {
      assertValid(IPCProtocol.resultFrame(id: "7", result: result), "result.schema.json")
    }
    assertValid(
      IPCProtocol.subscribedFrame(id: "s", events: ["core:hints.shown", "core:mode.changed"]),
      "subscribed.schema.json")
    assertValid(IPCProtocol.subscribedFrame(id: "s", events: []), "subscribed.schema.json")
    for code in IPCProtocol.ErrorCode.allCases {
      assertValid(IPCProtocol.errorFrame(code, "because"), "error.schema.json")
      assertValid(IPCProtocol.errorFrame(code, "because", id: "9"), "error.schema.json")
    }
  }

  /// The events as the resident emits them: built by the payload builders
  /// their sources use, framed by the hub.
  func testEveryStreamedEventValidates() throws {
    let app =
      ["bundle_id": "com.apple.Notes", "localized_name": "Notes", "pid": 42] as [String: Any]
    let payloads: [HostEvent: PluginEvent] = [
      .appsLaunched: PluginEvent(.appsLaunched, payload: app, bundleID: "com.apple.Notes"),
      .appsTerminated: PluginEvent(.appsTerminated, payload: app, bundleID: "com.apple.Notes"),
      .focusChanged: PluginEvent(.focusChanged, payload: app, bundleID: "com.apple.Notes"),
      .windowFocusChanged: .windowFocusChanged(pid: 42, bundleID: "com.apple.Notes"),
      .displaysChanged: PluginEvent(
        .displaysChanged,
        payload: try XCTUnwrap(
          SystemEventObservers.displayChange(from: [1: "Built-in"], to: [1: "Built-in", 2: "LG"]))),
      .userIdle: PluginEvent(.userIdle, payload: ["seconds": 300]),
      .userActive: PluginEvent(.userActive, payload: ["idle_seconds": 312]),
      .usbAttached: PluginEvent(
        .usbAttached,
        payload: USBDeviceMonitor.payload(vendorID: 1452, productID: 3, name: "Keyboard")),
      .usbDetached: PluginEvent(
        .usbDetached, payload: USBDeviceMonitor.payload(vendorID: nil, productID: nil, name: nil)),
      .clockMinute: PluginEvent(
        .clockMinute,
        payload: ClockWatch.Announcement(
          minute: Date(), time: try XCTUnwrap(ClockTime("09:55")), weekday: .fri,
          date: "2026-10-23", lateSeconds: 0
        ).payload),
      .workspaceChanged: PluginEvent(
        .workspaceChanged,
        payload: try XCTUnwrap(
          TilingStatus(focused: "2", listed: ["1", "2"], previous: "1").workspaceChange(
            since: nil))),
    ]
    var frames: [String: Data] = [:]
    let hub = IPCEventHub(clock: { 1_792_000_000_000 })
    hub.deliver = { frame, _, _ in
      let name = (try? JSONSerialization.jsonObject(with: frame) as? [String: Any])?["name"]
      frames[name as? String ?? ""] = frame
    }
    hub.setSubscription(1, events: IPCProtocol.streamedEvents)
    let flashOwn: Set<HostEvent> = [
      .modeChanged, .hintsShown, .hintsCommitted, .hintsCancelled, .monitorTriggered,
    ]
    for name in IPCProtocol.streamedEvents {
      let event = try XCTUnwrap(HostEvent(rawValue: name))
      guard !flashOwn.contains(event) else { continue }
      hub.publish(payloads[event] ?? PluginEvent(event))
    }
    // Flash's own events, from the resident's own emitters.
    let delegate = AppDelegate()
    delegate.ipcEvents.deliver = hub.deliver
    delegate.ipcEvents.setSubscription(1, events: IPCProtocol.streamedEvents)
    delegate.emitModeChanged(from: .insert, to: .normal)
    delegate.announceHintSession(surface: "targets", targets: 12)
    delegate.noteHintCommitted()
    delegate.noteHintSessionEnding(
      {
        var session = HintSession()
        session.shownSurface = "grid"
        return session
      }())
    delegate.emitMonitorTriggered("battery", .warning)
    XCTAssertEqual(Set(frames.keys), Set(IPCProtocol.streamedEvents))
    for name in IPCProtocol.streamedEvents {
      assertValid(try XCTUnwrap(frames[name], name), "event.schema.json")
    }
    let mode = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(frames["core:mode.changed"]))
        as? [String: Any])
    XCTAssertEqual(mode["payload"] as? [String: String], ["mode": "normal", "previous": "insert"])
  }

  // MARK: - Flash's own events

  /// A session announces its first labels once, each committed pick, and a
  /// cancellation only when it ends without one; a mode event only when the
  /// mode's name changes.
  func testHintSessionAndModeEventsFollowTheSession() throws {
    let delegate = AppDelegate()
    var names: [String] = []
    delegate.ipcEvents.deliver = { frame, _, _ in
      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
      names.append(object?["name"] as? String ?? "")
    }
    delegate.ipcEvents.setSubscription(1, events: IPCProtocol.streamedEvents)
    delegate.announceHintSession(surface: "targets", targets: 3)
    delegate.announceHintSession(surface: "targets", targets: 2)
    delegate.noteHintCommitted()
    delegate.noteHintSessionEnding(delegate.hintSession)
    var unshown = HintSession()
    delegate.noteHintSessionEnding(unshown)
    unshown.shownSurface = "grid"
    delegate.noteHintSessionEnding(unshown)
    delegate.emitModeChanged(from: .normal, to: .normal)
    delegate.emitModeChanged(
      from: .command(restoreTo: .normal), to: .command(restoreTo: .insert))
    delegate.emitModeChanged(from: .normal, to: .hold)
    XCTAssertEqual(
      names,
      ["core:hints.shown", "core:hints.committed", "core:hints.cancelled", "core:mode.changed"])
  }

  func testOnlyAFinalPickCommits() {
    let click = MouseCommand.click(.leftClick, modifiers: [])
    XCTAssertTrue(AppDelegate.pickCommits(click, anchored: false, grid: false))
    XCTAssertFalse(AppDelegate.pickCommits(.drag(modifiers: []), anchored: false, grid: false))
    XCTAssertTrue(AppDelegate.pickCommits(.drag(modifiers: []), anchored: true, grid: true))
    XCTAssertFalse(
      AppDelegate.pickCommits(.adjust(.leftClick, modifiers: []), anchored: false, grid: false))
    XCTAssertTrue(
      AppDelegate.pickCommits(.adjust(.leftClick, modifiers: []), anchored: false, grid: true))
    XCTAssertFalse(
      AppDelegate.pickCommits(.path(.leftClick, modifiers: []), anchored: false, grid: false))
    XCTAssertTrue(
      AppDelegate.pickCommits(.path(.leftClick, modifiers: []), anchored: false, grid: true))
    XCTAssertTrue(AppDelegate.pickCommits(.copyURL, anchored: false, grid: false))
    XCTAssertFalse(AppDelegate.pickCommits(.copyText, anchored: false, grid: true))
  }

  // MARK: - The validator refuses what the schemas forbid

  func testTheSchemasRefuseWhatTheResidentRefuses() {
    assertInvalid(["type": "hello", "protocol": 2], "hello.schema.json")
    assertInvalid(["type": "hello", "protocol": 1, "extra": true], "hello.schema.json")
    assertInvalid(["type": "request", "words": ["q"]], "request.schema.json")
    assertInvalid(["type": "request", "id": "1", "words": []], "request.schema.json")
    assertInvalid(
      ["type": "request", "id": "1", "words": ["q"], "cwd": "rel"], "request.schema.json")
    assertInvalid(["type": "subscribe", "id": "1", "events": "core:*"], "subscribe.schema.json")
    assertInvalid(
      ["type": "result", "id": "1", "result": ["status": "maybe"]], "result.schema.json")
    assertInvalid(
      [
        "type": "event", "seq": 1, "name": "core:ax.changed", "time_ms": 0,
        "payload": ["pid": 1, "notification": "AXValueChanged"],
      ], "event.schema.json")
    assertInvalid(
      [
        "type": "event", "seq": 1, "name": "core:mode.changed", "time_ms": 0,
        "payload": ["mode": "normal"],
      ], "event.schema.json")
    assertInvalid(["type": "error", "code": "teapot", "message": ""], "error.schema.json")
    assertInvalid(["type": "welcome", "protocol": 1], "server-message.schema.json")
  }
}
