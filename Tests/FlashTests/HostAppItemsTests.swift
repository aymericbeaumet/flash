import Carbon
import Foundation
import XCTest

@testable import flash

/// `host.notes`, `host.reminders` and `host.contacts`: what a plugin holding
/// one of those capabilities reads of the app, when macOS is asked, and what
/// crosses the wire. The apps are stubs: no test here reads the Mac's notes,
/// reminders or contacts, runs a script or shows a prompt.
final class HostAppItemsTests: XCTestCase {
  private func dispatcher(_ kind: HostAppItemKind, _ stub: AppItemStub) -> PluginHostRPC {
    let rpc = PluginHostRPC()
    rpc.appItems[kind] = AppItemStub.host(kind, stub)
    return rpc
  }

  private static func capability(_ kind: HostAppItemKind) -> PluginCapability {
    switch kind {
    case .notes: return .notes
    case .reminders: return .reminders
    case .contacts: return .contacts
    }
  }

  private func call(
    _ rpc: PluginHostRPC, _ kind: HostAppItemKind, _ params: [String: Any],
    capabilities: Set<PluginCapability>? = nil, servesUser: Bool = false,
    done: @escaping ([String: Any]) -> Void
  ) {
    rpc.handleHostRequest(
      method: kind.method, params: params, pluginID: "itemstest",
      capabilities: capabilities ?? [Self.capability(kind)],
      scope: PluginHostRequestScope(isCurrent: { true }, servesUser: { servesUser }), reply: done)
  }

  private func reply(
    _ rpc: PluginHostRPC, _ kind: HostAppItemKind, _ params: [String: Any],
    capabilities: Set<PluginCapability>? = nil, servesUser: Bool = false
  ) -> NSDictionary {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: "\(kind) \(params["operation"] ?? "")")
    call(rpc, kind, params, capabilities: capabilities, servesUser: servesUser) { result in
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

  func testTheAccessAndAListAreReadOffMainInTheAppsOrder() throws {
    let stub = AppItemStub.corpus(.reminders)
    let rpc = dispatcher(.reminders, stub)
    XCTAssertEqual(
      reply(rpc, .reminders, ["operation": "access"]),
      ["ok": true, "access": "granted"] as NSDictionary)
    let listed = reply(rpc, .reminders, ["operation": "list"])
    XCTAssertEqual(listed["ok"] as? Bool, true)
    XCTAssertEqual(listed["access"] as? String, "granted")
    XCTAssertNil(listed["truncated"])
    let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
    XCTAssertEqual(
      items[0] as NSDictionary,
      [
        "id": "5F8A-R1", "title": "Buy milk", "list": "Inbox", "list_index": 0,
        "created": 1_800_000_000,
      ] as NSDictionary)
    XCTAssertEqual(
      Set(items[1].keys), ["id", "title", "list", "list_index"], "no creation time, no key")
    XCTAssertEqual(stub.lists, 1)
    XCTAssertEqual(stub.asks, 0, "a read never asks")
    XCTAssertFalse(stub.calledOnMain)

    // A note and a contact are an identifier and one line.
    for kind in [HostAppItemKind.notes, .contacts] {
      let listed = reply(dispatcher(kind, AppItemStub.corpus(kind)), kind, ["operation": "list"])
      let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
      XCTAssertEqual(items.count, 2, kind.rawValue)
      XCTAssertTrue(items.allSatisfy { Set($0.keys) == ["id", "title"] }, kind.rawValue)
    }
  }

  /// Each app answers on its own queue: a Notes script still running holds
  /// up neither Reminders nor Contacts.
  func testASlowAppHoldsUpNoOther() {
    let notes = AppItemStub.corpus(.notes)
    let gate = DispatchSemaphore(value: 0)
    notes.gate = gate
    let rpc = PluginHostRPC()
    rpc.appItems[.notes] = AppItemStub.host(.notes, notes)
    rpc.appItems[.contacts] = AppItemStub.host(.contacts, AppItemStub.corpus(.contacts))
    let listed = expectation(description: "notes listed")
    call(rpc, .notes, ["operation": "list"]) { _ in listed.fulfill() }
    waitUntilTrue("the notes listing began") { notes.lists == 1 }
    XCTAssertEqual(reply(rpc, .contacts, ["operation": "list"])["ok"] as? Bool, true)
    gate.signal()
    wait(for: [listed], timeout: 5)
  }

  func testAReplyHoldsTheFirstItemsWithinItsBounds() throws {
    func item(_ index: Int, title: String = "Item") -> HostAppItem {
      HostAppItem(id: "I\(index)", title: title)
    }
    let exact = HostAppItems.wire((0..<HostAppItems.maxItems).map { item($0) })
    XCTAssertEqual(exact.items.count, HostAppItems.maxItems)
    XCTAssertFalse(exact.truncated)
    let over = HostAppItems.wire((0...HostAppItems.maxItems).map { item($0) })
    XCTAssertEqual(over.items.count, HostAppItems.maxItems)
    XCTAssertTrue(over.truncated)
    XCTAssertEqual(over.items.first?["id"] as? String, "I0", "the app's order is kept")
    XCTAssertEqual(over.items.last?["id"] as? String, "I\(HostAppItems.maxItems - 1)")

    // Titles at their bound: the reply stops at its byte bound.
    let wide = String(repeating: "é", count: PluginProtocol.maxTitleBytes)
    let heavy = HostAppItems.wire((0..<1_200).map { item($0, title: wide) })
    XCTAssertTrue(heavy.truncated)
    XCTAssertLessThan(heavy.items.count, 1_200)
    let bytes = try JSONSerialization.data(
      withJSONObject: heavy.items, options: [.withoutEscapingSlashes]
    ).count
    XCTAssertLessThanOrEqual(bytes, HostAppItems.maxReplyBytes)
    XCTAssertGreaterThan(bytes, HostAppItems.maxReplyBytes - 2 * 4_200)
    let title = try XCTUnwrap(heavy.items.first?["title"] as? String)
    XCTAssertEqual(title.utf8.count, PluginProtocol.maxTitleBytes, "cut at a character")
    XCTAssertTrue(wide.hasPrefix(title))
    let listed = HostAppItems.wire(HostAppItem(id: "R", title: "T", list: wide, listIndex: 3))
    XCTAssertEqual((listed["list"] as? String)?.utf8.count, PluginProtocol.maxTitleBytes)
  }

  /// Five thousand contacts are one reply well inside the bounds, encoded
  /// in a few milliseconds.
  func testFiveThousandContactsAreOneReplyInsideTheBounds() throws {
    let contacts = (0..<5_000).map { index in
      HostAppItem(
        id: "410FE041-5C4E-48DA-B4DE-\(String(format: "%012d", index)):ABPerson",
        title: "Contact Number \(index) Lastname")
    }
    let started = DispatchTime.now()
    let wire = HostAppItems.wire(contacts)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    XCTAssertEqual(wire.items.count, 5_000)
    XCTAssertFalse(wire.truncated)
    let bytes = try JSONSerialization.data(
      withJSONObject: wire.items, options: [.withoutEscapingSlashes]
    ).count
    XCTAssertLessThan(bytes, HostAppItems.maxReplyBytes / 3)
    XCTAssertLessThan(elapsedMs, 250, "\(elapsedMs) ms")
  }

  func testAListWithoutTheGrantAnswersTheAccessAloneAndNeverAsks() {
    for (access, name) in [
      (GrantAccess.denied, "denied"), (.undetermined, "undetermined"),
    ] {
      let stub = AppItemStub(access: access, items: [HostAppItem(id: "N", title: "Secret")])
      XCTAssertEqual(
        reply(dispatcher(.notes, stub), .notes, ["operation": "list"], servesUser: true),
        ["ok": true, "access": name] as NSDictionary)
      XCTAssertEqual(stub.asks, 0)
      XCTAssertEqual(stub.lists, 0)
    }
  }

  func testAFailedReadIsTheReplysError() {
    let stub = AppItemStub(access: .granted)
    stub.listing = .failed("applescript status=124 timed out")
    XCTAssertEqual(
      reply(dispatcher(.notes, stub), .notes, ["operation": "list"]),
      ["ok": false, "error": "applescript status=124 timed out"] as NSDictionary)
    // Access revoked between the check and the read.
    stub.listing = .denied
    XCTAssertEqual(
      reply(dispatcher(.notes, stub), .notes, ["operation": "list"]),
      ["ok": true, "access": "denied"] as NSDictionary)
  }

  // MARK: - Asking

  /// macOS's prompt comes up only while the user is using the plugin: a
  /// query is scoped to its source, or one of its commands is running.
  func testOnlyAPluginTheUserIsUsingRaisesThePrompt() {
    for kind in HostAppItemKind.allCases {
      let stub = AppItemStub(access: .undetermined)
      let rpc = dispatcher(kind, stub)
      XCTAssertEqual(
        reply(rpc, kind, ["operation": "request_access"]),
        ["ok": false, "error": PluginProtocol.userRequestRequiredError] as NSDictionary)
      XCTAssertEqual(stub.asks, 0, "no prompt from the background")
      XCTAssertEqual(
        reply(rpc, kind, ["operation": "access"]),
        ["ok": true, "access": "undetermined"] as NSDictionary)

      XCTAssertEqual(
        reply(rpc, kind, ["operation": "request_access"], servesUser: true),
        ["ok": true, "access": "granted"] as NSDictionary)
      XCTAssertEqual(stub.asks, 1)
      // Answered once: nothing asks again, whoever requests.
      XCTAssertEqual(
        reply(rpc, kind, ["operation": "request_access"]),
        ["ok": true, "access": "granted"] as NSDictionary)
      XCTAssertEqual(stub.asks, 1)
      XCTAssertFalse(stub.calledOnMain)
    }
  }

  func testARefusalIsDeniedAndNeverAskedAgain() {
    let stub = AppItemStub(access: .undetermined, grants: false)
    let rpc = dispatcher(.contacts, stub)
    for _ in 0..<2 {
      XCTAssertEqual(
        reply(rpc, .contacts, ["operation": "request_access"], servesUser: true),
        ["ok": true, "access": "denied"] as NSDictionary)
    }
    XCTAssertEqual(stub.asks, 1)
  }

  /// The running-app gate: macOS has nobody to ask about while Notes is not
  /// running, so nothing is asked, whoever the plugin serves, and nothing
  /// is refused either.
  func testAnAppThatCannotBeAskedAboutIsNotAsked() {
    let stub = AppItemStub(access: .undetermined)
    stub.isRunning = false
    let rpc = dispatcher(.notes, stub)
    for servesUser in [false, true] {
      XCTAssertEqual(
        reply(rpc, .notes, ["operation": "request_access"], servesUser: servesUser),
        ["ok": true, "access": "undetermined"] as NSDictionary)
    }
    XCTAssertEqual(stub.asks, 0)
    stub.isRunning = true
    XCTAssertEqual(
      reply(rpc, .notes, ["operation": "request_access"], servesUser: true),
      ["ok": true, "access": "granted"] as NSDictionary)
    XCTAssertEqual(stub.asks, 1)
  }

  func testRequestsMadeWhileThePromptIsOpenShareItsAnswer() {
    let stub = AppItemStub(access: .undetermined, holdsAnswer: true)
    let rpc = dispatcher(.reminders, stub)
    let lock = NSLock()
    var replies: [String] = []
    let answered = expectation(description: "both requests")
    answered.expectedFulfillmentCount = 2
    for _ in 0..<2 {
      call(rpc, .reminders, ["operation": "request_access"], servesUser: true) { result in
        lock.lock()
        replies.append(result["access"] as? String ?? "")
        lock.unlock()
        answered.fulfill()
      }
    }
    rpc.appItems[.reminders]?.drain()
    XCTAssertEqual(stub.asks, 1, "one prompt")
    // The queue stays free while the prompt is up.
    XCTAssertEqual(
      reply(rpc, .reminders, ["operation": "access"]),
      ["ok": true, "access": "undetermined"] as NSDictionary)
    stub.answer()
    wait(for: [answered], timeout: 5)
    XCTAssertEqual(replies, ["granted", "granted"])
  }

  // MARK: - Showing

  func testShowBringsTheAppForwardOnAnItemOfAnAppFlashMayRead() {
    let stub = AppItemStub.corpus(.notes)
    let rpc = dispatcher(.notes, stub)
    let id = "x-coredata://4F1C/ICNote/p12"
    XCTAssertEqual(
      reply(rpc, .notes, ["operation": "show", "id": id]), ["ok": true] as NSDictionary)
    XCTAssertEqual(stub.shown, [id])
    stub.failure = "applescript status=1 no such note"
    XCTAssertEqual(
      reply(rpc, .notes, ["operation": "show", "id": id]),
      ["ok": false, "error": "applescript status=1 no such note"] as NSDictionary)

    // Without the grant nothing is sent to the app: a Notes script would
    // raise macOS's prompt.
    for access in [GrantAccess.undetermined, .denied] {
      let refused = AppItemStub(access: access)
      XCTAssertEqual(
        reply(
          dispatcher(.notes, refused), .notes, ["operation": "show", "id": id], servesUser: true),
        ["ok": false, "error": "host.notes show requires access"] as NSDictionary)
      XCTAssertEqual(refused.shown, [])
      XCTAssertEqual(refused.asks, 0)
    }
  }

  /// A pick never waits behind a listing in flight: Notes' script can run
  /// for seconds on the app's queue.
  func testAShowNeverWaitsBehindAListingInFlight() {
    let notes = AppItemStub.corpus(.notes)
    let gate = DispatchSemaphore(value: 0)
    notes.gate = gate
    let rpc = dispatcher(.notes, notes)
    let listed = expectation(description: "notes listed")
    call(rpc, .notes, ["operation": "list"]) { _ in listed.fulfill() }
    waitUntilTrue("the listing began") { notes.lists == 1 }
    XCTAssertEqual(
      reply(rpc, .notes, ["operation": "show", "id": "x-coredata://4F1C/ICNote/p12"]),
      ["ok": true] as NSDictionary)
    XCTAssertEqual(notes.shown, ["x-coredata://4F1C/ICNote/p12"])
    XCTAssertFalse(notes.calledOnMain)
    gate.signal()
    wait(for: [listed], timeout: 5)
  }

  /// The URL a reminder or a card opens by takes its identifier whole: one
  /// that would add a path, a query or a fragment opens nothing.
  func testAnItemsURLTakesItsIdentifierWhole() {
    XCTAssertEqual(
      LiveRemindersItems.url(id: "5F8A-91C2")?.absoluteString,
      "x-apple-reminderkit://REMCDReminder/5F8A-91C2")
    XCTAssertEqual(
      LiveContactsItems.url(id: "5F8A:ABPerson")?.absoluteString, "addressbook://5F8A:ABPerson")
    for id in ["", "5F8A/../x", "5F8A?x=1", "5F8A#x", "5F 8A", "5F8A%2F", "é", "a@b"] {
      XCTAssertNil(LiveRemindersItems.url(id: id), id)
      XCTAssertNil(LiveContactsItems.url(id: id), id)
    }
  }

  // MARK: - Notes

  /// `id<TAB>name` per line, as the list script prints them; a line without
  /// both fields is no note.
  func testTheNotesListingIsReadLineByLine() {
    XCTAssertEqual(
      LiveNotesItems.items(
        listing: "note-1\tFirst\nmalformed\nnote-2\t Second \n\tMissing ID\nnote-3\t\n\n"),
      [
        HostAppItem(id: "note-1", title: "First"), HostAppItem(id: "note-2", title: " Second"),
      ])
    XCTAssertEqual(LiveNotesItems.items(listing: ""), [])
    XCTAssertEqual(LiveNotesItems.items(listing: " \nmalformed\n"), [])
    // A name may hold a tab: only the first one separates.
    XCTAssertEqual(
      LiveNotesItems.items(listing: "n\ta\tb"), [HostAppItem(id: "n", title: "a\tb")])
  }

  func testTheNotesScriptsOutputIsItsItemsARefusalOrAFailure() {
    XCTAssertEqual(
      LiveNotesItems.listing(
        of: AppleScriptOutput(status: 0, stdout: "n\tGroceries\n", stderr: "")),
      .items([HostAppItem(id: "n", title: "Groceries")]))
    XCTAssertEqual(
      LiveNotesItems.listing(
        of: AppleScriptOutput(
          status: 1, stdout: "",
          stderr: "execution error: Not authorized to send Apple events to Notes. (-1743)\n")),
      .denied)
    XCTAssertEqual(Int(errAEEventNotPermitted), -1743)
    let timedOut = AppleScriptOutput(
      status: AppleScriptOutput.timeoutStatus, stdout: "", stderr: "timed out\n")
    XCTAssertEqual(LiveNotesItems.listing(of: timedOut), .failed(timedOut.failure ?? ""))
    XCTAssertEqual(LiveNotesItems.listTimeout, 30)
    XCTAssertEqual(LiveNotesItems.showTimeout, 10)
  }

  /// Each Apple Event is a round trip Notes answers on its main thread: a
  /// per-note loop over a few hundred notes took 10–30 s per listing (the
  /// resident logged a slow refresh at 18 s p50 and hit the 30 s timeout)
  /// and left Notes unresponsive meanwhile. The listing reads the ids and
  /// names of `every note` of an account in bulk and pairs them by index,
  /// and never asks a single note for a property.
  func testNotesListingReadsEveryNoteInBulkNotOnePerNote() {
    let script = NotesScripts.list
    XCTAssertTrue(script.contains("set ids to id of every note of acc"), script)
    XCTAssertTrue(script.contains("set names to name of every note of acc"), script)
    XCTAssertTrue(script.contains("repeat with i from 1 to count of ids"), script)
    XCTAssertFalse(script.contains("repeat with n in notes of acc"), script)
    XCTAssertFalse(script.contains("id of n"), script)
    XCTAssertFalse(script.contains("name of n"), script)
    // The output contract the reader takes is unchanged: id, tab, name.
    XCTAssertTrue(script.contains("& tab &"), script)
    XCTAssertTrue(script.contains("set AppleScript's text item delimiters to linefeed"), script)
    // A listing never launches Notes.
    XCTAssertTrue(script.hasPrefix("if application \"Notes\" is not running then return \"\""))
  }

  /// The identifier a plugin sends reaches the script as a literal.
  func testTheShowScriptQuotesItsIdentifier() {
    XCTAssertTrue(NotesScripts.show(id: "x\"y\\z").contains("show note id \"x\\\"y\\\\z\""))
    let hostile = NotesScripts.show(id: "p1\"\ndelete every note\n\"")
    XCTAssertTrue(hostile.contains(#"show note id "p1\"\ndelete every note\n\"""#), hostile)
    XCTAssertEqual(
      hostile.components(separatedBy: "\n").count,
      NotesScripts.show(id: "p1").components(separatedBy: "\n").count,
      "no line of the plugin's own")
  }

  func testAutomationConsentReadsMacOSAnswer() {
    XCTAssertEqual(AutomationConsent.access(status: noErr), .granted)
    XCTAssertEqual(AutomationConsent.access(status: OSStatus(errAEEventNotPermitted)), .denied)
    XCTAssertEqual(
      AutomationConsent.access(status: OSStatus(errAEEventWouldRequireUserConsent)),
      .undetermined)
    XCTAssertEqual(AutomationConsent.access(status: OSStatus(procNotFound)), .undetermined)
  }

  // MARK: - The contract

  func testAppItemsRefuseWhatTheirOperationDoesNotTake() {
    for kind in HostAppItemKind.allCases {
      let method = kind.method
      let rpc = dispatcher(kind, AppItemStub.corpus(kind))
      func refusal(_ params: [String: Any]) -> String? {
        let reply = reply(rpc, kind, params)
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(params)")
        return reply["error"] as? String
      }
      XCTAssertEqual(
        reply(rpc, kind, ["operation": "access"], capabilities: []),
        ["ok": false, "error": "missing \(kind.rawValue) capability"] as NSDictionary)
      // Another app's capability reads nothing of this one.
      let others = Set(HostAppItemKind.allCases.filter { $0 != kind }.map(Self.capability))
      XCTAssertEqual(
        reply(rpc, kind, ["operation": "list"], capabilities: others),
        ["ok": false, "error": "missing \(kind.rawValue) capability"] as NSDictionary)
      let operation = "\(method) requires a supported operation"
      XCTAssertEqual(refusal([:]), operation)
      XCTAssertEqual(refusal(["operation": "delete"]), operation)
      XCTAssertEqual(refusal(["operation": ["list"]]), operation)
      let id = "\(method) show requires an id of 1 to 1024 bytes without control characters"
      for value: Any in [
        "", 12, ["a"], "a\nb", "a\u{0}b", "a\u{7F}", String(repeating: "a", count: 1_025),
      ] {
        XCTAssertEqual(refusal(["operation": "show", "id": value]), id, "\(value)")
      }
      XCTAssertEqual(refusal(["operation": "show"]), id)
      let malformed = "invalid \(method) params"
      XCTAssertEqual(refusal(["operation": "access", "id": "a"]), malformed)
      XCTAssertEqual(refusal(["operation": "list", "id": "a"]), malformed)
      XCTAssertEqual(refusal(["operation": "list", "account": "iCloud"]), malformed)
      XCTAssertEqual(refusal(["operation": "show", "id": "a", "activate": true]), malformed)
    }
  }

  func testAnUnwiredHostAnswersWhy() {
    for kind in HostAppItemKind.allCases {
      XCTAssertEqual(
        reply(PluginHostRPC(), kind, ["operation": "access"]),
        ["ok": false, "error": "\(kind.rawValue) unavailable"] as NSDictionary)
    }
  }

  /// The resident's own mechanisms read nothing, ask nothing, run no script
  /// and open no app inside the test runner, whoever reaches them.
  func testTheLiveMechanismsAreInertInsideTheTestRunner() {
    XCTAssertFalse(LiveAppItems.mechanismsAllowed)
    let providers = LiveAppItems.providers()
    XCTAssertEqual(Set(providers.keys), Set(HostAppItemKind.allCases))
    for (kind, live) in providers {
      XCTAssertEqual(live.access(), .denied, kind.rawValue)
      XCTAssertEqual(live.list(), .failed(LiveAppItems.inertReason), kind.rawValue)
      let answered = expectation(description: "\(kind) no prompt")
      live.requestAccess { granted in
        XCTAssertFalse(granted)
        answered.fulfill()
      }
      let shown = expectation(description: "\(kind) nothing shown")
      live.show(id: "5F8A") { failure in
        XCTAssertEqual(failure, LiveAppItems.inertReason)
        shown.fulfill()
      }
      wait(for: [answered, shown], timeout: 5)
    }
    XCTAssertFalse(LiveNotesItems().canRequestAccess())
  }

  /// macOS kills an app that reads Contacts or Reminders without saying why
  /// (macOS 14 reads the full-access Reminders key, macOS 13 the original
  /// one), and the hardened runtime denies them without the entitlements.
  func testTheBundleExplainsAndEntitlesTheReads() throws {
    let resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources")
    func plist(_ name: String) throws -> [String: Any] {
      let data = try Data(contentsOf: resources.appendingPathComponent(name))
      return try XCTUnwrap(
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    let info = try plist("Info.plist")
    XCTAssertNotNil(info["NSContactsUsageDescription"] as? String)
    XCTAssertNotNil(info["NSRemindersFullAccessUsageDescription"] as? String)
    XCTAssertEqual(
      info["NSRemindersUsageDescription"] as? String,
      info["NSRemindersFullAccessUsageDescription"] as? String)
    XCTAssertTrue(
      (info["NSAppleEventsUsageDescription"] as? String)?.contains("Notes") == true)
    let entitlements = try plist("Flash.entitlements")
    XCTAssertEqual(
      entitlements["com.apple.security.personal-information.addressbook"] as? Bool, true)
    XCTAssertEqual(
      entitlements["com.apple.security.personal-information.calendars"] as? Bool, true)
  }

  func testAppItemsContractMatchesSpec() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json")
    let spec = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let contract = try XCTUnwrap(spec["app_items"] as? [String: Any])
    XCTAssertEqual(contract["methods"] as? [String], HostAppItemKind.allCases.map(\.method))
    XCTAssertEqual(
      contract["operations"] as? [String], PluginHostRequest.AppItems.operations.map(\.name))
    XCTAssertEqual(contract["access"] as? [String], GrantAccess.wireNames)
    XCTAssertEqual(contract["max_items"] as? Int, HostAppItems.maxItems)
    XCTAssertEqual(contract["reply_bytes"] as? Int, HostAppItems.maxReplyBytes)
    XCTAssertEqual(contract["max_id_bytes"] as? Int, HostAppItems.maxIDBytes)
    XCTAssertLessThanOrEqual(
      HostAppItems.maxItems, PluginProtocol.maxCatalogRows,
      "a listing fits the rows one search reply holds")
    let shape = try XCTUnwrap(spec["app_item"] as? [String: Any])
    XCTAssertEqual(
      Set(HostAppItems.wire(HostAppItem(id: "I", title: "T")).keys),
      Set(try XCTUnwrap(shape["required"] as? [String])))
    XCTAssertEqual(
      Set(
        HostAppItems.wire(
          HostAppItem(id: "I", title: "T", list: "L", listIndex: 0, created: Date())
        ).keys),
      Set(
        try XCTUnwrap(shape["required"] as? [String])
          + (try XCTUnwrap(shape["optional"] as? [String]))))
    let rpcs = try XCTUnwrap(
      (spec["methods"] as? [String: Any])?["plugin_to_host_rpcs"] as? [String: Any])
    for kind in HostAppItemKind.allCases {
      XCTAssertEqual(rpcs[kind.method] as? String, Self.capability(kind).rawValue)
      XCTAssertEqual(
        PluginHostRequest.Method(rawValue: kind.method)?.capability, Self.capability(kind))
    }
  }
}
