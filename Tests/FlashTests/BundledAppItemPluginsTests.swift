import AppKit
import FlashCore
import XCTest

@testable import flash

/// The built `notes`, `reminders` and `contacts` plugins, spawned under
/// their sandbox profiles by a real `PluginManager`. They hold no grant and
/// reach no app: each asks the host (`host.notes`, `host.reminders`,
/// `host.contacts`), whose readers here are stubs, so no test reads the
/// Mac's notes, reminders or contacts, runs a script or shows macOS's
/// prompt. An app is opened through `host.open`, whose opener is this
/// suite's.
final class BundledAppItemPluginsTests: XCTestCase {
  private static let ids = ["notes", "reminders", "contacts"]
  private static let bundleIDs: [HostAppItemKind: String] = [
    .notes: "com.apple.Notes", .reminders: "com.apple.reminders",
    .contacts: "com.apple.AddressBook",
  ]

  private var manager: PluginManager!
  private var registry: SourceRegistry!
  private var dataDir: URL!
  private var stubs: [HostAppItemKind: AppItemStub] = [:]
  private var originalAppOpener: ((String, @escaping (String?) -> Void) -> Void)!
  private var opened: [String] = []

  override func setUp() {
    originalAppOpener = PluginHostRPC.appOpener
    PluginHostRPC.appOpener = { [weak self] bundleID, done in
      self?.opened.append(bundleID)
      done(nil)
    }
  }

  override func tearDown() {
    manager?.stop()
    PluginHostRPC.appOpener = originalAppOpener
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private static func config() throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    for id in ids {
      let root = try XCTUnwrap(roots.first { $0.lastPathComponent == id })
      let binary = root.appendingPathComponent("flash-plugin-\(id)").path
      guard FileManager.default.isExecutableFile(atPath: binary) else {
        if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
          XCTFail("the \(id) plugin must be built")
        }
        throw XCTSkip("\(id) is not built: run `mise run build:plugins`")
      }
    }
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(ids)
    config.plugins.watchingEnabled = false
    return config
  }

  /// Start the three plugins over `stubs`, wired before any plugin starts,
  /// with the apps of `running` in the snapshot a new child gets.
  private func start(
    _ stubs: [HostAppItemKind: AppItemStub],
    running: Set<HostAppItemKind> = [.notes, .reminders, .contacts]
  ) throws {
    let config = try Self.config()
    self.stubs = stubs
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-app-items-\(UUID().uuidString)")
    let manager = PluginManager(baseDataDir: dataDir)
    self.manager = manager
    for (kind, stub) in stubs {
      manager.hostRPC.appItems[kind] = AppItemStub.host(kind, stub)
    }
    manager.cacheRunningApplicationsSnapshot(
      running.sorted { $0.rawValue < $1.rawValue }.enumerated().map { index, kind in
        [
          "bundle_id": Self.bundleIDs[kind] ?? "", "pid": 700 + index,
          "localized_name": kind.grant,
        ]
      })
    manager.start(config: config)
    waitUntilTrue("the plugins loaded") { Self.ids.allSatisfy { self.status($0) != nil } }
    registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
  }

  private func status(_ id: String) -> PluginStatus? {
    manager.pluginStatuses().first { $0.id == id }
  }

  /// The rows one `@<type>` scope pulls, and how long the pull took.
  private func pull(_ type: String) throws -> (rows: [Candidate], ms: Double) {
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type(type)).first)
    XCTAssertFalse(source.liveCandidatesDependOnText, "per_scope: pulled once per scope")
    let listed = expectation(description: "@\(type)")
    var rows: [Candidate] = []
    let started = DispatchTime.now()
    var ms = 0.0
    source.liveCandidates(matching: "", in: registry.environment, scope: .all) {
      ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
      rows = CandidateFinder.prepare($0)
      listed.fulfill()
    }
    wait(for: [listed], timeout: 15)
    return (rows, ms)
  }

  private func run(_ command: String, _ subcommand: String, _ args: [String] = [])
    -> PluginCommandResult
  {
    let answered = expectation(description: "\(command) \(subcommand)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: command, subcommand: subcommand, args: args) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  private func resolve(_ row: Candidate) -> CandidateResolution {
    let resolved = expectation(description: "resolve \(row.title)")
    var resolution = CandidateResolution.unresolved
    registry.resolveCandidate(row) {
      resolution = $0
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 15)
    return resolution
  }

  private static func note(_ index: Int, _ title: String) -> HostAppItem {
    HostAppItem(id: "x-coredata://4F1C/ICNote/p\(index)", title: title)
  }

  // MARK: - Declarations

  /// Each catalog is its own plugin, so each can be disabled on its own:
  /// one live source of the type its command word names, the one capability
  /// that reads its app beside `open`, in the default sandbox.
  func testEachManifestDeclaresOneLiveSourceItsCommandsAndItsCapability() throws {
    let sources = [
      "notes": "notes.notes", "reminders": "reminders.tasks", "contacts": "contacts.cards",
    ]
    let capabilities: [String: PluginCapability] = [
      "notes": .notes, "reminders": .reminders, "contacts": .contacts,
    ]
    for id in Self.ids {
      let root = try XCTUnwrap(
        PluginRepository.officialPluginRoots().first { $0.lastPathComponent == id })
      let manifest = try PluginManifest.load(from: root)
      XCTAssertEqual(manifest.liveSources, .perScope, id)
      XCTAssertEqual(manifest.sources.map(\.name), [sources[id]], id)
      XCTAssertEqual(manifest.sources.map(\.type), [id], id)
      XCTAssertEqual(manifest.candidateSourceDescriptors.map(\.priority), [.normal], id)
      XCTAssertEqual(ResourceTypes.byName[id]?.owner, .shared, id)
      XCTAssertEqual(manifest.capabilities, [try XCTUnwrap(capabilities[id]), .open], id)
      XCTAssertEqual(manifest.sandboxSpec, PluginSandboxSpec(), "\(id): no allowance")
      XCTAssertEqual(manifest.appleEventsTargets, [], "\(id) sends no Apple Event")
      XCTAssertEqual(
        manifest.pluginCommands.map { "\($0.command) \($0.subcommand)" },
        ["\(id) open", "\(id) refresh"])
      XCTAssertEqual(
        Set(manifest.listen),
        [
          "core:apps.launched", "core:apps.terminated", "core:focus.changed",
          "core:session.opened",
        ], id)
      XCTAssertTrue(manifest.isLiveBound, id)
      XCTAssertEqual(manifest.activation, .onDemand, "\(id): its events keep no process")
      // The command word is the plugin's: no core topic shadows it.
      XCTAssertFalse(URLEventHandler.isTopic(id), id)
      XCTAssertTrue(PluginRepository.declaresCommand(id), id)
    }
  }

  // MARK: - The plugins

  /// Three plugins that listen to events and nothing runs: no process, no
  /// read and no prompt until a query or a command uses one.
  func testThePluginsCostNothingUntilOneIsUsed() throws {
    let notes = AppItemStub(access: .undetermined, items: [Self.note(1, "Groceries")])
    try start([
      .notes: notes, .reminders: AppItemStub(access: .granted),
      .contacts: AppItemStub(access: .granted),
    ])
    for id in Self.ids {
      XCTAssertEqual(status(id)?.activation, "on_demand", id)
      XCTAssertNil(status(id)?.pid, "\(id): nothing runs at launch")
    }
    manager.emit(PluginEvent(.sessionOpened))
    manager.emit(
      PluginEvent(
        .focusChanged, payload: ["bundle_id": "com.apple.Notes", "pid": 700],
        bundleID: "com.apple.Notes"))
    settleRunLoop(0.3)
    XCTAssertTrue(Self.ids.allSatisfy { status($0)?.pid == nil }, "events spawn nothing")
    XCTAssertEqual(stubs.values.map(\.lists), [0, 0, 0])
    XCTAssertEqual(stubs.values.map(\.asks), [0, 0, 0])

    // A refused argument spawns the one plugin it names, and reads nothing.
    XCTAssertEqual(
      run("notes", "open", ["--now"]),
      PluginCommandResult(ok: false, error: "usage: notes open"))
    XCTAssertNotNil(status("notes")?.pid)
    XCTAssertNil(status("contacts")?.pid)
    XCTAssertEqual(notes.asks, 0)
  }

  /// The sandbox proof: under the plugin's own profile, the first query
  /// scoped to `@notes` has the host ask macOS, the listing that follows
  /// the grant is read through the host, and a picked row is shown by it.
  func testAScopedQueryAsksThenListsAndAPickShowsTheNote() throws {
    let notes = AppItemStub(
      access: .undetermined,
      items: [Self.note(1, "Groceries"), Self.note(2, " Taxes 2026 "), Self.note(1, "Renamed")])
    try start([.notes: notes])
    XCTAssertEqual(
      try pull("notes").rows.map(\.title), [], "macOS's prompt is open while the query answers")
    XCTAssertEqual(notes.asks, 1, "a query scoped to the catalog is the user using it")
    waitUntilTrue("listed once granted") { notes.lists == 1 }

    var rows: [Candidate] = []
    waitUntilTrue("the next scope has the rows") {
      rows = (try? self.pull("notes").rows) ?? []
      return rows.count == 2
    }
    XCTAssertEqual(rows.map(\.title), ["Groceries", "Taxes 2026"])
    XCTAssertEqual(rows.map(\.subtitle), ["Note", "Note"])
    XCTAssertEqual(rows.map(\.source), ["notes.notes", "notes.notes"])
    XCTAssertEqual(rows.map(\.kind), [.plugin("note"), .plugin("note")])
    XCTAssertEqual(rows[0].sourcePayload, "x-coredata://4F1C/ICNote/p1")
    XCTAssertEqual(rows[0].sourceID, "plugin:notes")
    XCTAssertFalse(rows[0].sortKey.isEmpty)
    XCTAssertEqual(notes.asks, 1)
    XCTAssertEqual(notes.lists, 1, "a query reads the plugin's memory once access is settled")
    XCTAssertFalse(notes.calledOnMain)
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [], "live rows are never stored")

    XCTAssertTrue(resolve(rows[1]).didResolve)
    XCTAssertEqual(notes.shown, ["x-coredata://4F1C/ICNote/p2"])
    // A note that will not show says so.
    notes.failure = "applescript status=1 no such note"
    let failed = resolve(rows[0])
    XCTAssertFalse(failed.didResolve)
    XCTAssertEqual(failed.failureReason, "the item could not be shown")
  }

  /// Reminders are listed list by list in Reminders' order, then oldest
  /// first, under their list's title.
  func testRemindersAreOrderedByListThenAge() throws {
    func reminder(_ id: String, _ title: String, _ list: String, _ index: Int?, _ created: Double?)
      -> HostAppItem
    {
      HostAppItem(
        id: id, title: title, list: list, listIndex: index,
        created: created.map(Date.init(timeIntervalSince1970:)))
    }
    let reminders = AppItemStub(
      access: .granted,
      items: [
        reminder("c", "Ship release", "Work", 1, 2_000),
        reminder("x", "Archive", "Gone", nil, 1_000),
        reminder("b", "Call back", "Inbox", 0, 2_000),
        reminder("a", "Buy milk", "Inbox", 0, 1_000),
        reminder("d", "Review", "Work", 1, nil),
      ])
    try start([.reminders: reminders])
    let rows = try pull("reminders").rows
    XCTAssertEqual(rows.map(\.sourcePayload), ["a", "b", "c", "d", "x"])
    XCTAssertEqual(
      rows.map(\.subtitle),
      [
        "Reminder — Inbox", "Reminder — Inbox", "Reminder — Work", "Reminder — Work",
        "Reminder — Gone",
      ])
    XCTAssertEqual(rows.first?.title, "Buy milk")
    XCTAssertEqual(rows.first?.source, "reminders.tasks")
    XCTAssertEqual(rows.first?.kind, .plugin("reminder"))
    XCTAssertEqual(reminders.asks, 0)
    XCTAssertTrue(resolve(rows[0]).didResolve)
    XCTAssertEqual(reminders.shown, ["a"])
  }

  /// A catalog lists only while its app runs: a stopped app is not read,
  /// its launch lists it and its quitting empties it at once.
  func testACatalogFollowsItsApp() throws {
    let contacts = AppItemStub(
      access: .granted,
      items: [
        HostAppItem(id: "1:ABPerson", title: "Ada Lovelace"),
        HostAppItem(id: "2:ABPerson", title: "Ada Lovelace"),
        HostAppItem(id: "3:ABPerson", title: " Grace Hopper "),
      ])
    try start([.contacts: contacts], running: [])
    XCTAssertEqual(try pull("contacts").rows.map(\.title), [])
    XCTAssertEqual(contacts.lists, 0, "Contacts is not running")
    XCTAssertEqual(run("contacts", "refresh").message, "contacts refreshed")
    XCTAssertEqual(contacts.lists, 0)

    let app: [String: Any] = [
      "bundle_id": "com.apple.AddressBook", "pid": 702, "localized_name": "Contacts",
    ]
    manager.emit(PluginEvent(.appsLaunched, payload: app, bundleID: "com.apple.AddressBook"))
    waitUntilTrue("its launch lists it") { contacts.lists == 1 }
    var rows: [Candidate] = []
    waitUntilTrue("the cards are served") {
      rows = (try? self.pull("contacts").rows) ?? []
      return !rows.isEmpty
    }
    XCTAssertEqual(rows.map(\.title), ["Ada Lovelace", "Grace Hopper"], "one row per name")
    XCTAssertEqual(rows.map(\.sourcePayload), ["1:ABPerson", "3:ABPerson"])
    XCTAssertEqual(rows.map(\.subtitle), ["Contact", "Contact"])
    XCTAssertEqual(rows.first?.source, "contacts.cards")
    XCTAssertEqual(rows.first?.kind, .plugin("contact"))

    // Focus leaving the app relists it: the user may have just edited it.
    // One focus change at a time, as they happen: an unsent one is
    // superseded by the next.
    for bundleID in ["com.apple.AddressBook", "com.apple.Terminal"] {
      manager.emit(
        PluginEvent(
          .focusChanged, payload: ["bundle_id": bundleID, "pid": 702], bundleID: bundleID))
      settleRunLoop(0.2)
    }
    waitUntilTrue("focus left Contacts") { contacts.lists == 2 }

    manager.emit(PluginEvent(.appsTerminated, payload: app, bundleID: "com.apple.AddressBook"))
    waitUntilTrue("quitting empties it") {
      ((try? self.pull("contacts").rows) ?? [Candidate(title: "")]).isEmpty
    }
    XCTAssertEqual(contacts.lists, 2)
  }

  /// `open` launches the app through the host; `refresh` relists, asking
  /// macOS first when Flash never asked, and a refusal says nothing.
  func testTheCommandsOpenTheAppAndRelist() throws {
    let reminders = AppItemStub(
      access: .undetermined,
      items: [HostAppItem(id: "a", title: "Buy milk", list: "Inbox", listIndex: 0)])
    let contacts = AppItemStub(access: .undetermined, grants: false)
    try start([.reminders: reminders, .contacts: contacts, .notes: AppItemStub(access: .granted)])
    for id in Self.ids {
      XCTAssertNil(manager.ownCommandConfirmation(command: id, subcommand: "refresh"))
      XCTAssertEqual(run(id, "open"), PluginCommandResult(ok: true))
    }
    XCTAssertEqual(opened, ["com.apple.Notes", "com.apple.reminders", "com.apple.AddressBook"])

    XCTAssertEqual(
      run("reminders", "refresh"), PluginCommandResult(ok: true, message: "reminders refreshed"))
    XCTAssertEqual(reminders.asks, 1, "a command is the user's own use: it may ask")
    XCTAssertEqual(reminders.lists, 1)
    XCTAssertEqual(try pull("reminders").rows.map(\.title), ["Buy milk"])

    XCTAssertEqual(run("contacts", "refresh"), PluginCommandResult(ok: true))
    XCTAssertEqual(run("contacts", "refresh"), PluginCommandResult(ok: true))
    XCTAssertEqual(contacts.asks, 1, "refused once, never asked again")
    XCTAssertEqual(contacts.lists, 0)

    stubs[.notes]?.listing = .failed("applescript status=124 timed out")
    let failed = run("notes", "refresh")
    XCTAssertEqual(failed, PluginCommandResult(ok: false, error: "notes refresh failed"))
    XCTAssertEqual(failed.failureAlert, failed.error, "short enough to show")
  }

  /// Five thousand contacts are one listing and one search reply, inside
  /// the wire quotas and the 1 s `search` deadline, cold and warm.
  func testFiveThousandContactsListInsideTheSearchDeadline() throws {
    let contacts = AppItemStub(
      access: .granted,
      items: (0..<5_000).map { index in
        HostAppItem(
          id: "410FE041-5C4E-48DA-B4DE-\(String(format: "%012d", index)):ABPerson",
          title: "Contact Number \(index) Lastname")
      })
    try start([.contacts: contacts])
    let cold = try pull("contacts")
    XCTAssertEqual(cold.rows.count, 5_000, "the cold query spawned, listed and answered")
    XCTAssertEqual(cold.rows.first?.title, "Contact Number 0 Lastname")
    XCTAssertEqual(cold.rows.last?.title, "Contact Number 4999 Lastname")
    var warm: [Double] = []
    for _ in 0..<5 {
      let pulled = try pull("contacts")
      XCTAssertEqual(pulled.rows.count, 5_000)
      warm.append(pulled.ms)
    }
    XCTAssertEqual(contacts.lists, 1, "warm queries read the plugin's memory")
    let median = warm.sorted()[warm.count / 2]
    print(
      "app-items 5000 contacts: cold \(Int(cold.ms)) ms, warm median \(Int(median)) ms "
        + "(\(warm.map { Int($0) }))")
    XCTAssertLessThan(cold.ms, Double(PluginProtocol.searchDeadlineMs) + 5_000)
    XCTAssertLessThan(median, Double(PluginProtocol.searchDeadlineMs))
  }
}
