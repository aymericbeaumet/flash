import FlashCore
import XCTest

@testable import flash

/// The Notes, Reminders and Contacts catalogs: row shaping, when they relist,
/// when macOS is asked for access, and their verbs. Readers are stubs: no test
/// touches the Mac's notes, reminders or contacts, or shows a prompt.
final class AppleCatalogTests: XCTestCase {
  private final class StubReader: AppleCatalogReading {
    private let lock = NSLock()
    private var currentAccess: AppleCatalogAccess
    private var nextListing: AppleCatalogListing
    private let grants: Bool
    private var listCount = 0
    private var askCount = 0
    private var shownIDs: [String] = []
    private var mainReads = false
    private var listingGate: DispatchSemaphore?

    var lists: Int { locked { listCount } }
    var asks: Int { locked { askCount } }
    var shown: [String] { locked { shownIDs } }
    var readOnMain: Bool { locked { mainReads } }
    /// Holds a listing in flight until signalled.
    var gate: DispatchSemaphore? {
      get { locked { listingGate } }
      set { locked { listingGate = newValue } }
    }

    init(
      access: AppleCatalogAccess, listing: AppleCatalogListing = .rows([]), grants: Bool = true
    ) {
      currentAccess = access
      nextListing = listing
      self.grants = grants
    }

    var listing: AppleCatalogListing {
      get { locked { nextListing } }
      set { locked { nextListing = newValue } }
    }

    func access() -> AppleCatalogAccess {
      locked {
        mainReads = mainReads || Thread.isMainThread
        return currentAccess
      }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
      let granted = locked {
        askCount += 1
        currentAccess = grants ? .granted : .denied
        return grants
      }
      DispatchQueue.global().async { done(granted) }
    }

    func list() -> AppleCatalogListing {
      let (listing, gate) = locked {
        listCount += 1
        mainReads = mainReads || Thread.isMainThread
        return (nextListing, listingGate)
      }
      gate?.wait()
      return listing
    }

    func show(id: String, done: @escaping (String?) -> Void) {
      locked { shownIDs.append(id) }
      done(nil)
    }

    private func locked<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }
  }

  private let note = AppleCatalogRow(id: "note-1", title: "Groceries", subtitle: "Note")

  private func catalogs(
    _ readers: [AppleCatalog: StubReader], now: @escaping () -> Int = { 0 }
  ) -> AppleCatalogs {
    AppleCatalogs(readers: readers, nowMs: now)
  }

  private func settle(_ catalogs: AppleCatalogs, _ catalog: AppleCatalog) {
    let settled = expectation(description: "\(catalog) settled")
    catalogs.afterQueuedWork(catalog) { settled.fulfill() }
    wait(for: [settled], timeout: 10)
  }

  private func refresh(_ catalogs: AppleCatalogs, _ catalog: AppleCatalog) -> AppleCatalogOutcome? {
    var outcome: AppleCatalogOutcome?
    let done = expectation(description: "refresh \(catalog)")
    catalogs.refresh(catalog) {
      outcome = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return outcome
  }

  // MARK: - Rows

  func testNoteListingRejectsMalformedRowsAndDeduplicatesIDs() {
    let rows = AppleCatalogRows.notes(
      listing: "note-1\tFirst\nmalformed\nnote-2\t Second \nnote-1\tRenamed\n\tMissing ID\n")
    let candidates = AppleCatalogRows.candidates(rows, of: .notes)
    XCTAssertEqual(candidates.map(\.title), ["First", "Second"])
    let first = candidates[0]
    XCTAssertEqual(first.source, "notes.notes")
    XCTAssertEqual(first.sourceID, "core.notes")
    XCTAssertEqual(first.kind, .plugin("note"))
    XCTAssertEqual(first.subtitle, "Note")
    XCTAssertEqual(first.sourcePayload, "note-1")
    XCTAssertEqual(first.searchAliases, "")
  }

  func testReminderRowsTrimTheirFieldsAndKeepTheirOrder() {
    let rows = AppleCatalogRows.reminders([
      .init(id: "rem-1", list: "Inbox", title: "Buy milk"),
      .init(id: "rem-2", list: " Work ", title: " Ship release "),
      .init(id: "rem-1", list: "Inbox", title: "Duplicate"),
      .init(id: "", list: "Inbox", title: "Missing id"),
      .init(id: "rem-3", list: "Inbox", title: "  "),
    ])
    let candidates = AppleCatalogRows.candidates(rows, of: .reminders)
    XCTAssertEqual(candidates.map(\.title), ["Buy milk", "Ship release"])
    XCTAssertEqual(candidates.map(\.subtitle), ["Reminder — Inbox", "Reminder — Work"])
    XCTAssertEqual(candidates[0].source, "reminders.tasks")
    XCTAssertEqual(candidates[0].kind, .plugin("reminder"))
    XCTAssertEqual(candidates[0].sourcePayload, "rem-1")
  }

  /// List by list in Reminders' order, then oldest first; a list Reminders
  /// no longer names goes last.
  func testRemindersAreOrderedByListThenAge() {
    let early = Date(timeIntervalSince1970: 1_000)
    let late = Date(timeIntervalSince1970: 2_000)
    let ordered = RemindersCatalogReader.ordered(
      [
        .init(id: "c", listID: "work", list: "Work", title: "C", created: late),
        .init(id: "x", listID: "gone", list: "Gone", title: "X", created: early),
        .init(id: "b", listID: "inbox", list: "Inbox", title: "B", created: late),
        .init(id: "a", listID: "inbox", list: "Inbox", title: "A", created: early),
        .init(id: "d", listID: "work", list: "Work", title: "D", created: nil),
      ], lists: ["inbox", "work"])
    XCTAssertEqual(ordered.map(\.id), ["a", "b", "c", "d", "x"])
  }

  /// Two cards with one name read as one row: the first, in Contacts' order.
  func testContactRowsAreOnePerName() {
    let rows = AppleCatalogRows.contacts([
      .init(id: "1:ABPerson", name: "Ada Lovelace"),
      .init(id: "2:ABPerson", name: " Grace Hopper "),
      .init(id: "3:ABPerson", name: "Ada Lovelace"),
      .init(id: "4:ABPerson", name: ""),
    ])
    let candidates = AppleCatalogRows.candidates(rows, of: .contacts)
    XCTAssertEqual(candidates.map(\.title), ["Ada Lovelace", "Grace Hopper"])
    XCTAssertEqual(candidates.map(\.sourcePayload), ["1:ABPerson", "2:ABPerson"])
    XCTAssertEqual(candidates[0].subtitle, "Contact")
    XCTAssertEqual(candidates[0].source, "contacts.cards")
    XCTAssertEqual(candidates[0].kind, .plugin("contact"))
  }

  func testEmptyListingsAreAnAuthoritativeEmptyCatalog() {
    XCTAssertTrue(AppleCatalogRows.notes(listing: "").isEmpty)
    XCTAssertTrue(
      AppleCatalogRows.candidates(AppleCatalogRows.notes(listing: " \nmalformed\n"), of: .notes)
        .isEmpty)
    XCTAssertTrue(AppleCatalogRows.candidates([], of: .contacts).isEmpty)
  }

  func testCatalogsAreKeyedByBundleIDSourceAndVerb() {
    for (catalog, bundleID, label) in [
      (AppleCatalog.notes, "com.apple.Notes", "notes.notes"),
      (.reminders, "com.apple.reminders", "reminders.tasks"),
      (.contacts, "com.apple.AddressBook", "contacts.cards"),
    ] {
      XCTAssertEqual(catalog.bundleID, bundleID)
      XCTAssertEqual(catalog.sourceLabel, label)
      XCTAssertEqual(AppleCatalog.owning(bundleID: bundleID), catalog)
      XCTAssertEqual(catalog.sourceID, "core.\(catalog.rawValue)")
    }
    XCTAssertNil(AppleCatalog.owning(bundleID: "com.apple.TextEdit"))
    XCTAssertNil(AppleCatalog.owning(bundleID: nil))
  }

  /// Each Apple Event is a round trip Notes answers on its main thread: a
  /// per-note loop over a few hundred notes took 10–30 s per listing (the
  /// resident logged `[apple] refresh slow` at 18 s p50 and hit the 30 s
  /// timeout) and left Notes unresponsive meanwhile. The listing reads the
  /// ids and names of `every note` of an account in bulk and pairs them by
  /// index, and never asks a single note for a property.
  func testNotesListingReadsEveryNoteInBulkNotOnePerNote() {
    let script = NotesScripts.list
    XCTAssertTrue(script.contains("set ids to id of every note of acc"), script)
    XCTAssertTrue(script.contains("set names to name of every note of acc"), script)
    XCTAssertTrue(script.contains("repeat with i from 1 to count of ids"), script)
    XCTAssertFalse(script.contains("repeat with n in notes of acc"), script)
    XCTAssertFalse(script.contains("id of n"), script)
    XCTAssertFalse(script.contains("name of n"), script)
    // The output contract the parser reads is unchanged: id, tab, name.
    XCTAssertTrue(script.contains("& tab &"), script)
    XCTAssertTrue(script.contains("set AppleScript's text item delimiters to linefeed"), script)
  }

  func testScriptsQuoteTheirIdentifier() {
    XCTAssertTrue(NotesScripts.show(id: "x\"y\\z").contains("show note id \"x\\\"y\\\\z\""))
    XCTAssertTrue(NotesScripts.list.contains("if application \"Notes\" is not running"))
    XCTAssertEqual(
      RemindersCatalogReader.url(id: "5F8A")?.absoluteString,
      "x-apple-reminderkit://REMCDReminder/5F8A")
    XCTAssertEqual(
      ContactsCatalogReader.url(id: "5F8A:ABPerson")?.absoluteString,
      "addressbook://5F8A:ABPerson")
  }

  // MARK: - When they relist

  func testLeavingACatalogsAppNamesItForARelist() {
    var schedule = AppleCatalogSchedule()
    XCTAssertNil(schedule.focus("com.apple.Notes"))
    XCTAssertNil(schedule.focus("com.apple.Notes"), "no move")
    XCTAssertEqual(schedule.focus("com.apple.reminders"), .notes)
    XCTAssertEqual(schedule.focus("com.apple.Terminal"), .reminders)
    XCTAssertNil(schedule.focus(nil))
  }

  func testAFlashlightOpenRelistsTheFocusedCatalogAndStaleOnes() {
    let all: Set<AppleCatalog> = [.notes, .reminders, .contacts]
    var schedule = AppleCatalogSchedule()
    // Never listed: every running catalog is due; a stopped one never is.
    XCTAssertEqual(
      schedule.claimOnOpen(running: [.notes, .reminders], nowMs: 0), [.notes, .reminders])
    // Just listed: nothing is due, unless its app is focused.
    XCTAssertEqual(schedule.claimOnOpen(running: [.notes, .reminders], nowMs: 0), [])
    _ = schedule.focus("com.apple.reminders")
    XCTAssertEqual(schedule.claimOnOpen(running: all, nowMs: 1), [.reminders, .contacts])
    _ = schedule.focus("com.apple.Terminal")
    XCTAssertEqual(
      schedule.claimOnOpen(running: all, nowMs: AppleCatalogSchedule.sessionTTLMs - 1), [])
    XCTAssertEqual(
      schedule.claimOnOpen(running: all, nowMs: AppleCatalogSchedule.sessionTTLMs + 1),
      [.notes, .reminders, .contacts])
  }

  /// Only the user's own use of a catalog may ask macOS; a stopped app or a
  /// refusal is an empty catalog.
  func testStepsAskOnlyWhenTheUserUsesTheCatalog() {
    let accesses: [AppleCatalogAccess] = [.granted, .undetermined, .denied]
    for request in [AppleCatalogRequest.event, .query, .command] {
      for access in accesses {
        XCTAssertEqual(AppleCatalogStep.of(request, running: false, access: access), .clear)
      }
      XCTAssertEqual(AppleCatalogStep.of(request, running: true, access: .denied), .clear)
    }
    XCTAssertEqual(AppleCatalogStep.of(.event, running: true, access: .granted), .list)
    XCTAssertEqual(AppleCatalogStep.of(.event, running: true, access: .undetermined), .keep)
    XCTAssertEqual(AppleCatalogStep.of(.query, running: true, access: .granted), .keep)
    XCTAssertEqual(AppleCatalogStep.of(.query, running: true, access: .undetermined), .ask)
    XCTAssertEqual(AppleCatalogStep.of(.command, running: true, access: .granted), .list)
    XCTAssertEqual(AppleCatalogStep.of(.command, running: true, access: .undetermined), .ask)
    XCTAssertEqual(AppleCatalogRequest.event.merged(with: .query), .command)
    XCTAssertEqual(AppleCatalogRequest.event.merged(with: .event), .event)
  }

  func testAutomationConsentReadsMacOSAnswer() {
    XCTAssertEqual(AutomationConsent.access(status: noErr), .granted)
    XCTAssertEqual(AutomationConsent.access(status: OSStatus(errAEEventNotPermitted)), .denied)
    XCTAssertEqual(
      AutomationConsent.access(status: OSStatus(errAEEventWouldRequireUserConsent)),
      .undetermined)
    XCTAssertEqual(AutomationConsent.access(status: OSStatus(procNotFound)), .undetermined)
  }

  // MARK: - The catalogs

  /// Launch lists the running catalogs Flash may read; one never granted
  /// waits, unasked, and a stopped app is not read at all.
  func testStartListsOnlyRunningCatalogsWithAccess() {
    let notes = StubReader(access: .granted, listing: .rows([note]))
    let reminders = StubReader(access: .undetermined)
    let contacts = StubReader(access: .granted)
    let catalogs = catalogs([.notes: notes, .reminders: reminders, .contacts: contacts])
    catalogs.start(runningBundleIDs: ["com.apple.Notes", "com.apple.reminders"])
    for catalog in AppleCatalog.allCases { settle(catalogs, catalog) }
    XCTAssertEqual(catalogs.rows(.notes).map(\.title), ["Groceries"])
    XCTAssertEqual(notes.lists, 1)
    XCTAssertEqual(reminders.lists, 0)
    XCTAssertEqual(reminders.asks, 0, "launch never asks")
    XCTAssertEqual(contacts.lists, 0, "Contacts is not running")
    XCTAssertFalse(notes.readOnMain || reminders.readOnMain)
  }

  /// The first query naming a catalog asks once, then lists; later queries
  /// cost nothing.
  func testTheFirstScopedQueryAsksThenLists() {
    let reminders = StubReader(
      access: .undetermined,
      listing: .rows([.init(id: "rem-1", title: "Buy milk", subtitle: "Reminder — Inbox")]))
    let catalogs = catalogs([.reminders: reminders])
    var changes: [AppleCatalog] = []
    let changed = expectation(description: "rows changed")
    catalogs.onChange = {
      changes.append($0)
      changed.fulfill()
    }
    catalogs.appLaunched(bundleID: "com.apple.reminders")
    settle(catalogs, .reminders)
    XCTAssertEqual(reminders.asks, 0)
    catalogs.queried(.reminders)
    catalogs.queried(.reminders)
    wait(for: [changed], timeout: 10)
    XCTAssertEqual(reminders.asks, 1)
    XCTAssertEqual(reminders.lists, 1)
    XCTAssertEqual(changes, [.reminders])
    XCTAssertEqual(catalogs.rows(.reminders).map(\.title), ["Buy milk"])
    catalogs.queried(.reminders)
    settle(catalogs, .reminders)
    XCTAssertEqual(reminders.asks, 1)
    XCTAssertEqual(reminders.lists, 1, "a query reads memory once access is settled")
  }

  /// A refusal leaves the catalog empty and is never asked again.
  func testARefusedCatalogStaysEmptyAndQuiet() {
    let contacts = StubReader(access: .undetermined, listing: .rows([note]), grants: false)
    let catalogs = catalogs([.contacts: contacts])
    catalogs.appLaunched(bundleID: "com.apple.AddressBook")
    XCTAssertEqual(refresh(catalogs, .contacts), .denied)
    catalogs.queried(.contacts)
    settle(catalogs, .contacts)
    XCTAssertEqual(contacts.asks, 1)
    XCTAssertEqual(contacts.lists, 0)
    XCTAssertTrue(catalogs.rows(.contacts).isEmpty)
  }

  func testQueriesOfAStoppedAppReadNothing() {
    let notes = StubReader(access: .undetermined)
    let catalogs = catalogs([.notes: notes])
    catalogs.queried(.notes)
    settle(catalogs, .notes)
    XCTAssertEqual(notes.asks, 0)
    XCTAssertEqual(notes.lists, 0)
  }

  func testRefreshOutcomes() {
    let notes = StubReader(access: .granted, listing: .rows([note]))
    let catalogs = catalogs([.notes: notes])
    XCTAssertEqual(refresh(catalogs, .notes), .cleared, "Notes is not running")
    XCTAssertEqual(notes.lists, 0)
    catalogs.appLaunched(bundleID: "com.apple.Notes")
    XCTAssertEqual(refresh(catalogs, .notes), .listed(1))
    // A failed listing keeps the last good rows.
    notes.listing = .failed("applescript status=124 timed out")
    XCTAssertEqual(refresh(catalogs, .notes), .failed("applescript status=124 timed out"))
    XCTAssertEqual(catalogs.rows(.notes).map(\.title), ["Groceries"])
    // Access revoked since: the catalog empties.
    notes.listing = .denied
    XCTAssertEqual(refresh(catalogs, .notes), .denied)
    XCTAssertTrue(catalogs.rows(.notes).isEmpty)
  }

  /// Termination clears at once, and a listing that began before it is
  /// dropped when it lands.
  func testTerminationDropsTheRowsAndTheListingInFlight() {
    let notes = StubReader(access: .granted, listing: .rows([note]))
    let catalogs = catalogs([.notes: notes])
    catalogs.appLaunched(bundleID: "com.apple.Notes")
    settle(catalogs, .notes)
    XCTAssertEqual(catalogs.rows(.notes).count, 1)

    let gate = DispatchSemaphore(value: 0)
    notes.gate = gate
    var outcome: AppleCatalogOutcome?
    let refreshed = expectation(description: "refresh")
    catalogs.refresh(.notes) {
      outcome = $0
      refreshed.fulfill()
    }
    while notes.lists < 2 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    catalogs.appTerminated(bundleID: "com.apple.Notes")
    XCTAssertTrue(catalogs.rows(.notes).isEmpty)
    gate.signal()
    wait(for: [refreshed], timeout: 10)
    XCTAssertEqual(outcome, .cleared)
    XCTAssertTrue(catalogs.rows(.notes).isEmpty)
  }

  func testFocusLeavingAndFlashlightOpensRelist() {
    var now = 0
    let notes = StubReader(access: .granted, listing: .rows([note]))
    let catalogs = catalogs([.notes: notes], now: { now })
    catalogs.start(runningBundleIDs: ["com.apple.Notes"])
    settle(catalogs, .notes)
    XCTAssertEqual(notes.lists, 1)
    catalogs.sessionOpened()
    settle(catalogs, .notes)
    XCTAssertEqual(notes.lists, 1, "listed under a minute ago")
    catalogs.focusChanged(bundleID: "com.apple.Notes")
    catalogs.focusChanged(bundleID: "com.apple.Terminal")
    settle(catalogs, .notes)
    XCTAssertEqual(notes.lists, 2, "focus left Notes")
    now = AppleCatalogSchedule.sessionTTLMs
    catalogs.sessionOpened()
    settle(catalogs, .notes)
    XCTAssertEqual(notes.lists, 3, "a minute later")
  }

  // MARK: - The sources

  func testSourcesServeTheirRowsAndShowThePickedOne() throws {
    let notes = StubReader(access: .granted, listing: .rows([note]))
    let catalogs = catalogs([.notes: notes])
    catalogs.appLaunched(bundleID: "com.apple.Notes")
    settle(catalogs, .notes)
    let registry = SourceRegistry(
      descriptors: [], isTerminalEmulator: { _ in false }, runningApplications: [],
      appleCatalogs: catalogs)
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("notes")).first)
    XCTAssertEqual(source.identifier, "core.notes")
    XCTAssertEqual(
      registry.liveCandidateSources(matching: .type("contacts")).map(\.identifier),
      ["core.contacts"])
    XCTAssertTrue(registry.registeredResourceTypeProviders().contains { $0.type == "reminders" })

    var rows: [Candidate] = []
    let served = expectation(description: "rows")
    source.liveCandidates(
      matching: "groc", in: registry.environment, scope: .all
    ) {
      rows = $0
      served.fulfill()
    }
    wait(for: [served], timeout: 5)
    XCTAssertEqual(rows.map(\.title), ["Groceries"])
    XCTAssertFalse(rows[0].sortKey.isEmpty, "rows arrive prepared")

    var resolution: CandidateResolution?
    let resolved = expectation(description: "resolved")
    registry.resolveCandidate(rows[0]) {
      resolution = $0
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 5)
    XCTAssertEqual(resolution?.didResolve, true)
    XCTAssertEqual(notes.shown, ["note-1"])
  }

  // MARK: - Commands

  func testCommandsParseAndRoundTrip() {
    let cases: [(String, AppleCatalogCommand)] = [
      ("notes open", .open(.notes)), ("notes refresh", .refresh(.notes)),
      ("reminders open", .open(.reminders)), ("reminders refresh", .refresh(.reminders)),
      ("contacts open", .open(.contacts)), ("contacts refresh", .refresh(.contacts)),
    ]
    XCTAssertEqual(cases.map(\.1), AppleCatalogCommand.all)
    for (text, command) in cases {
      let words = text.split(separator: " ").map(String.init)
      XCTAssertEqual(command.name.description, text)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + words), .flashCommand(.appleCatalog(command)))
      XCTAssertEqual(URLCommand.appleCatalog(command).diagnosticDescription, "flash " + text)
      XCTAssertEqual(
        NormalModeDispatcher.commandLineCoreCommand(":" + text), .appleCatalog(command))
      XCTAssertNil(parseMappingCommand(argv: ["flash"] + words + ["--now"]), text)
      XCTAssertFalse(URLCommand.appleCatalog(command).explanation.isEmpty)
    }
    XCTAssertEqual(URLCommand.appleCatalog(.open(.notes)).explanation, "Opens Notes.")
    XCTAssertEqual(
      URLCommand.appleCatalog(.refresh(.reminders)).explanation,
      "Relists your open reminders for the flashlight.")
  }

  /// No plugin owns the catalogs' topics.
  func testNoPluginDeclaresTheCatalogTopics() {
    for catalog in AppleCatalog.allCases {
      XCTAssertFalse(PluginRepository.declaresCommand(catalog.rawValue))
      XCTAssertTrue(URLEventHandler.isTopic(catalog.rawValue))
    }
  }

  func testCommandLineCompletesTheCommands() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":notes ", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(context.items.map(\.label), ["open", "refresh"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
    let catalog = NormalModeDispatcher.coreCommandCatalog().compactMap { $0["name"] as? String }
    XCTAssertTrue(catalog.contains(":contacts refresh"))
  }

  // MARK: - Bundle

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
}
