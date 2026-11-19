import EventKit
import Foundation
import XCTest

@testable import flash

/// `host.calendar_events` and `core:calendar.changed`: what a plugin holding
/// the `calendar_events` capability reads of the calendar, when macOS is
/// asked, and what crosses the wire. The calendar is a stub: no test here
/// reads the Mac's calendars or shows a prompt.
final class HostCalendarEventsTests: XCTestCase {
  private static let method = "host.calendar_events"
  private static let t0 = CalendarEventStub.t0
  private static let window: [String: Any] = [
    "operation": "list", "start": 1_800_000_000, "end": 1_800_172_800,
  ]

  /// Counts the `core:calendar.changed` the host would send.
  private final class Changes {
    private let lock = NSLock()
    private var total = 0
    func note() {
      lock.lock()
      total += 1
      lock.unlock()
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return total
    }
  }

  private func dispatcher(
    _ stub: CalendarEventStub, changes: Changes = Changes()
  ) -> PluginHostRPC {
    let rpc = PluginHostRPC()
    rpc.calendarEvents = HostCalendarEvents(
      provider: stub, scheduler: PollScheduler(), changed: changes.note)
    return rpc
  }

  private func call(
    _ rpc: PluginHostRPC, _ params: [String: Any],
    capabilities: Set<PluginCapability> = [.calendarEvents], servesUser: Bool = false,
    done: @escaping ([String: Any]) -> Void
  ) {
    rpc.handleHostRequest(
      method: Self.method, params: params, pluginID: "calendartest", capabilities: capabilities,
      scope: PluginHostRequestScope(isCurrent: { true }, servesUser: { servesUser }), reply: done)
  }

  private func reply(
    _ rpc: PluginHostRPC, _ params: [String: Any],
    capabilities: Set<PluginCapability> = [.calendarEvents], servesUser: Bool = false
  ) -> NSDictionary {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: "\(params["operation"] ?? "")")
    call(rpc, params, capabilities: capabilities, servesUser: servesUser) { result in
      lock.lock()
      reply = result
      lock.unlock()
      replied.fulfill()
    }
    wait(for: [replied], timeout: 5)
    lock.lock()
    defer { lock.unlock() }
    return reply as NSDictionary
  }

  // MARK: - Reading

  func testTheAccessAndAListAreReadOffMain() throws {
    let stub = CalendarEventStub.corpus()
    let rpc = dispatcher(stub)
    XCTAssertEqual(
      reply(rpc, ["operation": "access"]), ["ok": true, "access": "granted"] as NSDictionary)
    let listed = reply(rpc, Self.window)
    XCTAssertEqual(listed["ok"] as? Bool, true)
    XCTAssertEqual(listed["access"] as? String, "granted")
    XCTAssertNil(listed["truncated"])
    let events = try XCTUnwrap(listed["events"] as? [[String: Any]])
    XCTAssertEqual(events.map { $0["title"] as? String }, ["Standup", "Lunch"], "start order")
    XCTAssertEqual(
      events[0] as NSDictionary,
      [
        "id": "E1@1800000720", "title": "Standup", "start": 1_800_000_720, "end": 1_800_002_520,
        "all_day": false, "calendar": "Work", "declined": false, "canceled": false,
        "url": "https://example.com/standup", "location": "Room 4",
        "links": ["https://zoom.us/j/123?pwd=abc"],
      ] as NSDictionary)
    XCTAssertEqual(
      Set(events[1].keys),
      ["id", "title", "start", "end", "all_day", "calendar", "declined", "canceled"],
      "an event without a URL, a location or a link carries none")
    XCTAssertEqual(stub.ranges, [Self.t0...Self.t0.addingTimeInterval(172_800)])
    XCTAssertEqual(stub.calendars, [[]], "no title reads every calendar")

    var named = Self.window
    named["calendars"] = ["Work"]
    let work = try XCTUnwrap(reply(rpc, named)["events"] as? [[String: Any]])
    XCTAssertEqual(work.map { $0["title"] as? String }, ["Standup"])
    XCTAssertEqual(stub.calendars.last, ["Work"])
    XCTAssertFalse(stub.calledOnMain)
    XCTAssertEqual(stub.asks, 0, "a read never asks")
  }

  /// The notes are read by the host alone: a plugin gets the link-shaped
  /// runs in them and none of the prose around.
  func testTheNotesNeverCrossTheWire() throws {
    let secret = "Salary review for Dana. Dial-in PIN 4471."
    let stub = CalendarEventStub(
      access: .granted,
      events: [
        HostCalendarEvent(
          id: "E@1", title: "1:1", start: Self.t0.addingTimeInterval(60),
          end: Self.t0.addingTimeInterval(120),
          notes: "\(secret) <a href=\"https://meet.google.com/abc-defg-hij\">Join</a>")
      ])
    let listed = reply(dispatcher(stub), Self.window)
    let encoded = String(
      decoding: try JSONSerialization.data(withJSONObject: listed), as: UTF8.self)
    for word in ["Salary", "Dana", "4471", "notes"] {
      XCTAssertFalse(encoded.contains(word), word)
    }
    let events = try XCTUnwrap(listed["events"] as? [[String: Any]])
    XCTAssertEqual(events[0]["links"] as? [String], ["https://meet.google.com/abc-defg-hij"])
  }

  func testLinkRunsAreSchemesAndWhatALinkRunsTo() {
    func runs(_ text: String) -> [String] { HostCalendarEvents.linkRuns(in: text) }
    XCTAssertEqual(
      runs("Join Zoom Meeting (https://us02web.zoom.us/j/857?pwd=x&amp;uname=a).\nOr dial in."),
      ["https://us02web.zoom.us/j/857?pwd=x&amp;uname=a"],
      "the bracket ends it; the sentence's full stop is the plugin's to drop")
    XCTAssertEqual(
      runs("zoommtg://zoom.us/join?confno=1 msteams:/l/meetup-join/x facetime-audio://a@b.c"),
      ["zoommtg://zoom.us/join?confno=1", "msteams:/l/meetup-join/x", "facetime-audio://a@b.c"])
    XCTAssertEqual(runs("HTTPS://Zoom.us/j/1\u{00A0}Room"), ["HTTPS://Zoom.us/j/1"])
    XCTAssertEqual(runs("mailto:a@b.c, call 12:30, see example.com/agenda"), [])
    XCTAssertEqual(runs(""), [])
    let many = (1...40).map { "https://example.com/\($0)" }.joined(separator: " ")
    XCTAssertEqual(runs(many).count, HostCalendarEvents.maxLinks)
    XCTAssertEqual(runs(many).first, "https://example.com/1", "the earliest ones are kept")
    let long = "https://example.com/" + String(repeating: "a", count: PluginProtocol.maxURLBytes)
    XCTAssertEqual(runs("\(long) https://zoom.us/j/1"), ["https://zoom.us/j/1"], "never cut")
  }

  func testAReplyHoldsTheEarliestEventsWithinItsBounds() throws {
    func event(_ index: Int, title: String = "Event") -> HostCalendarEvent {
      HostCalendarEvent(
        id: "E\(index)", title: title, start: Self.t0.addingTimeInterval(Double(index) * 60),
        end: Self.t0.addingTimeInterval(Double(index) * 60 + 30))
    }
    let exact = HostCalendarEvents.wire((0..<HostCalendarEvents.maxEvents).map { event($0) })
    XCTAssertEqual(exact.events.count, HostCalendarEvents.maxEvents)
    XCTAssertFalse(exact.truncated)
    let over = HostCalendarEvents.wire(
      (0...HostCalendarEvents.maxEvents).reversed().map { event($0) })
    XCTAssertEqual(over.events.count, HostCalendarEvents.maxEvents)
    XCTAssertTrue(over.truncated)
    XCTAssertEqual(over.events.first?["id"] as? String, "E0")
    XCTAssertEqual(over.events.last?["id"] as? String, "E\(HostCalendarEvents.maxEvents - 1)")

    // Titles at their bound: the reply stops at its byte bound.
    let wide = String(repeating: "é", count: PluginProtocol.maxTitleBytes)
    let heavy = HostCalendarEvents.wire((0..<600).map { event($0, title: wide) })
    XCTAssertTrue(heavy.truncated)
    XCTAssertLessThan(heavy.events.count, 600)
    let bytes = try JSONSerialization.data(
      withJSONObject: heavy.events, options: [.withoutEscapingSlashes]
    ).count
    XCTAssertLessThanOrEqual(bytes, HostCalendarEvents.maxReplyBytes)
    XCTAssertGreaterThan(bytes, HostCalendarEvents.maxReplyBytes - 2 * 4_500)
    let title = try XCTUnwrap(heavy.events.first?["title"] as? String)
    XCTAssertEqual(title.utf8.count, PluginProtocol.maxTitleBytes, "cut at a character")
    XCTAssertTrue(wide.hasPrefix(title))

    // A link is never cut: a field over the URL bound is left out whole.
    let long = "https://example.com/" + String(repeating: "a", count: PluginProtocol.maxURLBytes)
    var odd = event(0)
    odd.url = long
    odd.location = long
    odd.notes = ""
    XCTAssertEqual(
      Set(HostCalendarEvents.wire(odd).keys),
      ["id", "title", "start", "end", "all_day", "calendar", "declined", "canceled"])
  }

  func testAListWithoutTheGrantAnswersTheAccessAloneAndNeverAsks() {
    for (access, name) in [
      (AppleCatalogAccess.denied, "denied"), (.undetermined, "undetermined"),
    ] {
      let stub = CalendarEventStub(access: access, events: [])
      XCTAssertEqual(
        reply(dispatcher(stub), Self.window, servesUser: true),
        ["ok": true, "access": name] as NSDictionary)
      XCTAssertEqual(stub.asks, 0)
      XCTAssertEqual(stub.reads, 0)
    }
    XCTAssertEqual(AppleCatalogAccess.wireNames, ["granted", "denied", "undetermined"])
  }

  func testAFailedReadIsTheReplysError() {
    let stub = CalendarEventStub(access: .granted)
    stub.events = .failed("boom")
    XCTAssertEqual(
      reply(dispatcher(stub), Self.window), ["ok": false, "error": "boom"] as NSDictionary)
    // Access revoked between the check and the read.
    stub.events = .denied
    XCTAssertEqual(
      reply(dispatcher(stub), Self.window), ["ok": true, "access": "denied"] as NSDictionary)
  }

  // MARK: - Asking

  /// macOS's prompt comes up only while the user is using the plugin: one of
  /// its commands is running, or a surface shows one of its values.
  func testOnlyAPluginTheUserIsUsingRaisesThePrompt() {
    let stub = CalendarEventStub(access: .undetermined)
    let changes = Changes()
    let rpc = dispatcher(stub, changes: changes)
    XCTAssertEqual(
      PluginProtocol.userRequestRequiredError, "requires the user to be using the plugin")
    XCTAssertEqual(
      reply(rpc, ["operation": "request_access"]),
      ["ok": false, "error": PluginProtocol.userRequestRequiredError] as NSDictionary)
    XCTAssertEqual(stub.asks, 0, "no prompt from the background")
    XCTAssertEqual(
      reply(rpc, ["operation": "access"]), ["ok": true, "access": "undetermined"] as NSDictionary)

    XCTAssertEqual(
      reply(rpc, ["operation": "request_access"], servesUser: true),
      ["ok": true, "access": "granted"] as NSDictionary)
    XCTAssertEqual(stub.asks, 1)
    rpc.calendarEvents?.drain()
    XCTAssertEqual(changes.count, 1, "the answer is announced")

    // Answered once: nothing asks again, whoever requests.
    XCTAssertEqual(
      reply(rpc, ["operation": "request_access"]),
      ["ok": true, "access": "granted"] as NSDictionary)
    XCTAssertEqual(stub.asks, 1)
    XCTAssertFalse(stub.calledOnMain)
  }

  func testARefusalIsDeniedAndNeverAskedAgain() {
    let stub = CalendarEventStub(access: .undetermined, grants: false)
    let rpc = dispatcher(stub)
    for _ in 0..<2 {
      XCTAssertEqual(
        reply(rpc, ["operation": "request_access"], servesUser: true),
        ["ok": true, "access": "denied"] as NSDictionary)
    }
    XCTAssertEqual(stub.asks, 1)
  }

  func testRequestsMadeWhileThePromptIsOpenShareItsAnswer() {
    let stub = CalendarEventStub(access: .undetermined, holdsAnswer: true)
    let rpc = dispatcher(stub)
    let lock = NSLock()
    var replies: [String] = []
    let answered = expectation(description: "both requests")
    answered.expectedFulfillmentCount = 2
    for _ in 0..<2 {
      call(rpc, ["operation": "request_access"], servesUser: true) { result in
        lock.lock()
        replies.append(result["access"] as? String ?? "")
        lock.unlock()
        answered.fulfill()
      }
    }
    rpc.calendarEvents?.drain()
    XCTAssertEqual(stub.asks, 1, "one prompt")
    // The queue stays free while the prompt is up.
    XCTAssertEqual(
      reply(rpc, ["operation": "access"]), ["ok": true, "access": "undetermined"] as NSDictionary)
    stub.answer()
    wait(for: [answered], timeout: 5)
    XCTAssertEqual(replies, ["granted", "granted"])
  }

  // MARK: - Changes

  func testABurstOfChangesIsAnnouncedOnceAndOnlyWhileObserved() {
    let stub = CalendarEventStub(access: .granted)
    let changes = Changes()
    let events = HostCalendarEvents(
      provider: stub, scheduler: PollScheduler(), changed: changes.note)
    stub.change()
    events.drain()
    XCTAssertFalse(stub.observing, "nothing is observed until a plugin listens")

    let source = CalendarChangeSource { events }
    source.start()
    events.drain()
    XCTAssertTrue(stub.observing)
    for _ in 0..<3 { stub.change() }
    waitUntilTrue("the burst is announced") { changes.count == 1 }
    settleRunLoop(0.2)
    XCTAssertEqual(changes.count, 1)
    stub.change()
    waitUntilTrue("a later change opens a new window") { changes.count == 2 }

    source.stop()
    events.drain()
    XCTAssertFalse(stub.observing)
    stub.change()
    events.drain()
    settleRunLoop(Double(HostCalendarEvents.changeWindowMs) / 1_000 + 0.2)
    XCTAssertEqual(changes.count, 2)
  }

  /// `core:calendar.changed` is for plugins holding the capability: a
  /// manifest that only lists it, a socket client and an event monitor hear
  /// nothing.
  func testOnlyAPluginHoldingTheCapabilityHearsTheCalendarChange() throws {
    XCTAssertEqual(HostEvent.calendarChanged.requiredCapability, .calendarEvents)
    XCTAssertFalse(HostEvent.calendarChanged.isStreamed)
    XCTAssertTrue(HostEvent.calendarChanged.supersedesEarlier, "a payload-free signal")
    XCTAssertFalse(IPCProtocol.streamedEvents.contains(HostEvent.calendarChanged.rawValue))
    for event in HostEvent.allCases where event != .calendarChanged {
      XCTAssertNil(event.requiredCapability, event.rawValue)
    }
    func process(_ id: String, capabilities: String) throws -> (
      PluginProcess, PluginFixtureKit.Fixture
    ) {
      let fixture = try PluginFixtureKit.make(
        id: id,
        manifest: PluginFixtureKit.manifest(
          id: id,
          extra: #""listen": ["core:calendar.changed", "core:space.changed"]"# + capabilities),
        script: PluginFixtureKit.script())
      let process = PluginProcess(
        root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
        origin: .official, baseDataDir: fixture.baseDataDir, watchFiles: false)
      return (process, fixture)
    }
    let (holder, holderFixture) = try process(
      "calholder", capabilities: #", "capabilities": ["calendar_events"]"#)
    defer { holderFixture.cleanup() }
    let (other, otherFixture) = try process("calother", capabilities: "")
    defer { otherFixture.cleanup() }
    XCTAssertTrue(holder.listens(to: HostEvent.calendarChanged.rawValue))
    XCTAssertFalse(other.listens(to: HostEvent.calendarChanged.rawValue))
    XCTAssertTrue(other.listens(to: HostEvent.spaceChanged.rawValue))

    // A monitor naming the event keeps no source running and hears nothing.
    let delegate = AppDelegate()
    let monitors = ConfigLoader.parse(
      """
      [monitors.calendar]
      event = ["core:calendar.changed", "core:space.changed"]
      message = "changed"
      """
    ).eventMonitorSpecs
    XCTAssertEqual(Array(monitors.keys), ["calendar"])
    delegate.eventMonitors = monitors
    XCTAssertTrue(delegate.hostEventHasSubscriber(HostEvent.spaceChanged.rawValue))
    XCTAssertFalse(delegate.hostEventHasSubscriber(HostEvent.calendarChanged.rawValue))
  }

  // MARK: - The contract

  func testCalendarEventsRefusesWhatItsOperationDoesNotTake() {
    let rpc = dispatcher(CalendarEventStub.corpus())
    func refusal(_ params: [String: Any]) -> String? {
      let reply = reply(rpc, params)
      XCTAssertEqual(reply["ok"] as? Bool, false, "\(params)")
      return reply["error"] as? String
    }
    XCTAssertEqual(
      reply(rpc, ["operation": "access"], capabilities: []),
      ["ok": false, "error": "missing calendar_events capability"] as NSDictionary)
    let operation = "host.calendar_events requires a supported operation"
    XCTAssertEqual(refusal([:]), operation)
    XCTAssertEqual(refusal(["operation": "create"]), operation)
    XCTAssertEqual(refusal(["operation": ["list"]]), operation)
    let window =
      "host.calendar_events list requires whole seconds, start before end, at most 1209600 apart"
    for params: [String: Any] in [
      ["operation": "list"], ["operation": "list", "start": 10],
      ["operation": "list", "start": 20, "end": 10], ["operation": "list", "start": 10, "end": 10],
      ["operation": "list", "start": 0, "end": 1_209_601],
      ["operation": "list", "start": -1, "end": 10],
      ["operation": "list", "start": 10.5, "end": 20],
      ["operation": "list", "start": true, "end": 20],
      ["operation": "list", "start": "10", "end": 20],
      ["operation": "list", "start": 10, "end": 253_402_300_800],
    ] {
      XCTAssertEqual(refusal(params), window, "\(params)")
    }
    XCTAssertEqual(
      reply(rpc, ["operation": "list", "start": 0, "end": 1_209_600])["ok"] as? Bool, true,
      "the whole window")
    let calendars = "host.calendar_events list takes at most 64 non-empty calendar titles"
    for titles: Any in [
      "Work", ["Work", ""], [1], Array(repeating: "Work", count: 65),
      [String(repeating: "a", count: PluginProtocol.maxTitleBytes + 1)],
    ] {
      var params = Self.window
      params["calendars"] = titles
      XCTAssertEqual(refusal(params), calendars, "\(titles)")
    }
    let malformed = "invalid host.calendar_events params"
    XCTAssertEqual(refusal(["operation": "access", "start": 10]), malformed)
    XCTAssertEqual(refusal(["operation": "request_access", "calendars": []]), malformed)
    var extra = Self.window
    extra["notes"] = true
    XCTAssertEqual(refusal(extra), malformed)
  }

  func testAnUnwiredHostAnswersWhy() {
    XCTAssertEqual(
      reply(PluginHostRPC(), ["operation": "access"]),
      ["ok": false, "error": "calendar events unavailable"] as NSDictionary)
  }

  /// The resident's own mechanism reads nothing and asks nothing inside the
  /// test runner, whoever reaches it.
  func testTheLiveMechanismIsInertInsideTheTestRunner() {
    XCTAssertFalse(LiveCalendarEvents.mechanismsAllowed)
    let live = LiveCalendarEvents()
    XCTAssertEqual(live.access(), .denied)
    let answered = expectation(description: "no prompt")
    live.requestAccess { granted in
      XCTAssertFalse(granted)
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
    XCTAssertEqual(
      live.events(from: Self.t0, to: Self.t0.addingTimeInterval(60), calendars: []),
      .failed(LiveCalendarEvents.inertReason))
    live.observeChanges {}
    live.stopObservingChanges()
  }

  func testEventKitAuthorizationReadsAsAccess() throws {
    XCTAssertEqual(EventKitAccess.access(.fullAccess), .granted)
    // macOS 13's `.authorized`, deprecated where the test bundle builds.
    let authorized = try XCTUnwrap(EKAuthorizationStatus(rawValue: 3))
    XCTAssertEqual(EventKitAccess.access(authorized), .granted)
    XCTAssertEqual(EventKitAccess.access(.notDetermined), .undetermined)
    XCTAssertEqual(EventKitAccess.access(.writeOnly), .denied)
    XCTAssertEqual(EventKitAccess.access(.denied), .denied)
    XCTAssertEqual(EventKitAccess.access(.restricted), .denied)
  }

  /// macOS kills an app that reads Calendar without saying why. macOS 14
  /// reads the full-access key, macOS 13 the original one.
  func testTheBundleExplainsTheRead() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Info.plist")
    let info = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    XCTAssertNotNil(info["NSCalendarsFullAccessUsageDescription"] as? String)
    XCTAssertEqual(
      info["NSCalendarsUsageDescription"] as? String,
      info["NSCalendarsFullAccessUsageDescription"] as? String)
  }

  func testCalendarEventsContractMatchesSpec() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json")
    let spec = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let contract = try XCTUnwrap(spec["calendar_events"] as? [String: Any])
    XCTAssertEqual(
      contract["operations"] as? [String], PluginHostRequest.Calendar.operations.map(\.name))
    XCTAssertEqual(contract["access"] as? [String], AppleCatalogAccess.wireNames)
    XCTAssertEqual(contract["max_window_seconds"] as? Int, HostCalendarEvents.maxWindowSeconds)
    XCTAssertEqual(contract["max_time"] as? Int, HostCalendarEvents.maxTime)
    XCTAssertEqual(contract["max_calendars"] as? Int, HostCalendarEvents.maxCalendars)
    XCTAssertEqual(contract["max_events"] as? Int, HostCalendarEvents.maxEvents)
    XCTAssertEqual(contract["reply_bytes"] as? Int, HostCalendarEvents.maxReplyBytes)
    XCTAssertEqual(contract["max_links"] as? Int, HostCalendarEvents.maxLinks)
    let shape = try XCTUnwrap(spec["calendar_event"] as? [String: Any])
    var full = HostCalendarEvent(id: "E", title: "T", start: Self.t0, end: Self.t0)
    XCTAssertEqual(
      Set(HostCalendarEvents.wire(full).keys), Set(try XCTUnwrap(shape["required"] as? [String])))
    full.url = "https://example.com/"
    full.location = "Room"
    full.notes = "https://zoom.us/j/1"
    XCTAssertEqual(
      Set(HostCalendarEvents.wire(full).keys),
      Set(
        try XCTUnwrap(shape["required"] as? [String])
          + (try XCTUnwrap(shape["optional"] as? [String]))))
    let errors = try XCTUnwrap(spec["errors"] as? [String: Any])
    XCTAssertEqual(
      errors["user_request_required"] as? String, PluginProtocol.userRequestRequiredError)
    let rpcs = try XCTUnwrap(
      (spec["methods"] as? [String: Any])?["plugin_to_host_rpcs"] as? [String: Any])
    XCTAssertEqual(rpcs[Self.method] as? String, PluginCapability.calendarEvents.rawValue)
  }
}
