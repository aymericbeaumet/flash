import ApplicationServices
import FlashCore
import XCTest

@testable import flash

/// The built `menus` plugin, spawned under its sandbox profile by a real
/// `PluginManager`: an `@menus` query crosses the wire, reaches the host's
/// Accessibility broker and comes back as rows, and a picked row presses
/// its item through the broker. The broker's trees are a fixture
/// (`MenuBarFixture`), wired before any plugin starts: no test here reads or
/// presses a menu of a real app.
final class BundledMenusPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var registry: SourceRegistry!
  private var dataDir: URL!
  private let fixture = MenuBarFixture()

  private static func config(disabling extra: Set<String> = []) throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "menus" })
    let binary = root.appendingPathComponent("flash-plugin-menus").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the menus plugin must be built")
      }
      throw XCTSkip("menus is not built: run `mise run build:plugins`")
    }
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["menus"]).union(extra)
    config.plugins.watchingEnabled = false
    return config
  }

  override func setUpWithError() throws {
    let config = try Self.config()
    // Apple, File (New Tab, a disabled item, Export with a submenu) and
    // View, which opens nothing.
    fixture.set(fixture.bar, "AXMenuBar", nil, enabled: nil, [900_001, 900_002, 900_003])
    fixture.set(900_001, "AXMenuBarItem", "Apple", [900_010])
    fixture.set(900_002, "AXMenuBarItem", "File", [900_020])
    fixture.set(900_003, "AXMenuBarItem", "View")
    fixture.set(900_010, "AXMenu", nil, [900_011])
    fixture.set(900_011, "AXMenuItem", "About This Mac")
    fixture.set(900_020, "AXMenu", nil, [900_021, 900_022, 900_023])
    fixture.set(900_021, "AXMenuItem", "New Tab")
    fixture.set(900_022, "AXMenuItem", "Close All", enabled: false)
    fixture.set(900_023, "AXMenuItem", " Export ", [900_030])
    fixture.set(900_030, "AXMenu", nil, [900_031, 900_032])
    fixture.set(900_031, "AXMenuItem", "PDF…")
    fixture.set(900_032, "AXMenuItem", "PNG…")

    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-menus-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    // The seam, before anything can call through it.
    manager.hostRPC.axBroker = fixture.broker()
    manager.start(config: config)
    waitUntilTrue("menus loaded") { self.status != nil }
    let manager = try XCTUnwrap(self.manager)
    registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
  }

  override func tearDown() {
    manager?.stop()
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private var status: PluginStatus? {
    manager.pluginStatuses().first { $0.id == "menus" }
  }

  /// The rows one `@menus` scope pulls.
  private func pull() throws -> [Candidate] {
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("menus")).first)
    let listed = expectation(description: "rows")
    var rows: [Candidate] = []
    source.liveCandidates(matching: "exp", in: registry.environment, scope: .all) {
      rows = CandidateFinder.prepare($0)
      listed.fulfill()
    }
    wait(for: [listed], timeout: 15)
    return rows
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

  /// The menu-bar items are the plugin's: one live source of the shared
  /// `menus` type, behind the one capability the broker asks for, in the
  /// default sandbox, with no command, event or status to keep it running.
  func testTheManifestDeclaresOneLiveSourceBehindTheAccessibilityCapability() throws {
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "menus" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.liveSources, .perScope)
    XCTAssertEqual(manifest.sources.map(\.name), ["menus.items"])
    XCTAssertEqual(manifest.sources.map(\.type), ["menus"])
    XCTAssertEqual(manifest.candidateSourceDescriptors.map(\.priority), [.high])
    XCTAssertEqual(ResourceTypes.byName["menus"]?.owner, .shared)
    XCTAssertEqual(manifest.capabilities, [.accessibility])
    XCTAssertEqual(manifest.sandboxSpec, PluginSandboxSpec(), "the default sandbox, no allowance")
    XCTAssertEqual(manifest.pluginCommands.count, 0)
    XCTAssertEqual(manifest.sourceCommands, [], "it performs no core command")
    XCTAssertEqual(manifest.listen, [])
    XCTAssertEqual(manifest.status, [])
    XCTAssertEqual(manifest.activation, .onDemand, "no process until a query names it")
  }

  /// `@menus` is a live source of a plugin with nothing else: no process
  /// until a query names it, one snapshot per scope, and rows that never
  /// enter the catalog.
  func testMenuRowsArePulledLiveFromTheAppThatOwnsTheMenuBar() throws {
    XCTAssertEqual(status?.activation, "on_demand")
    let source = try XCTUnwrap(registry.liveCandidateSources(matching: .type("menus")).first)
    XCTAssertFalse(source.liveCandidatesDependOnText, "pulled once per scope")
    XCTAssertNil(status?.pid, "listing the type starts nothing")
    XCTAssertEqual(fixture.reads, [], "and reads no menu")

    let rows = try pull()
    XCTAssertNotNil(status?.pid, "the first scoped query spawned it")
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [], "live rows are never stored")
    XCTAssertEqual(
      rows.map(\.title), ["File › New Tab", "File › Export › PDF…", "File › Export › PNG…"],
      "in menu order: the Apple menu, the disabled item and the bar item without a menu are "
        + "left out")
    XCTAssertEqual(rows.map(\.displayTitle).first, "[menus.items] File › New Tab")
    XCTAssertTrue(
      rows.allSatisfy {
        $0.source == "menus.items" && $0.sourceID == "plugin:menus" && $0.pid == fixture.owner
          && $0.effect == nil && $0.confirm == nil && $0.finishesCommand
      })
    XCTAssertEqual(registry.resourceTypesBySource()["menus.items"], "menus")
    XCTAssertEqual(
      fixture.reads.sorted(),
      [
        fixture.bar, 900_001, 900_002, 900_003, 900_010, 900_011, 900_020, 900_021, 900_022,
        900_023, 900_030, 900_031, 900_032,
      ], "one round trip per element, the query's text aside")
  }

  /// Picking a row presses the element its snapshot read, and raises the
  /// app the menu belongs to.
  func testPickingARowPressesItsMenuItem() throws {
    let rows = try pull()
    let export = try XCTUnwrap(rows.first { $0.title == "File › Export › PNG…" })
    let resolution = resolve(export)
    XCTAssertTrue(resolution.didResolve)
    XCTAssertEqual(resolution.targetPID, fixture.owner)
    XCTAssertEqual(fixture.presses.map(\.element), [900_032])
    XCTAssertEqual(fixture.presses.map(\.action), ["AXPress"])
  }

  /// A row outlived by a newer snapshot fails in the plugin's words and
  /// presses nothing: no other element, no key, no pointer.
  func testARowOfAnEarlierSnapshotFailsAndPressesNothing() throws {
    let earlier = try pull()
    let later = try pull()
    XCTAssertEqual(earlier.map(\.title), later.map(\.title))
    XCTAssertNotEqual(
      earlier.map(\.sourcePayload), later.map(\.sourcePayload), "handles are never reused")

    let stale = resolve(try XCTUnwrap(earlier.first))
    XCTAssertFalse(stale.didResolve)
    XCTAssertEqual(stale.failureReason, "menu item is gone: search @menus again")
    XCTAssertNil(stale.targetPID)
    XCTAssertEqual(fixture.presses.count, 0)

    XCTAssertTrue(resolve(try XCTUnwrap(later.first)).didResolve)
    XCTAssertEqual(fixture.presses.map(\.element), [900_021])
  }

  /// An item that opens a modal dialog is pressed, but the app answers the
  /// press only when the dialog closes: no failure is shown for it.
  func testAPressTheAppDoesNotConfirmIsNoFailure() throws {
    let rows = try pull()
    fixture.answerPresses(with: .cannotComplete)
    let resolution = resolve(try XCTUnwrap(rows.first))
    XCTAssertFalse(resolution.didResolve)
    XCTAssertNil(resolution.failureReason, "nothing to tell the user")
    XCTAssertNil(resolution.targetPID)
    XCTAssertEqual(fixture.presses.map(\.element), [900_021], "pressed once")
  }

  /// With no app but Flash owning the menu bar there is nothing to list.
  func testNoOwnerListsNothing() throws {
    manager.stop()
    manager = PluginManager(baseDataDir: dataDir)
    manager.hostRPC.axBroker = fixture.broker(owner: { getpid() })
    manager.start(config: try Self.config())
    waitUntilTrue("menus loaded") { self.status != nil }
    let manager = try XCTUnwrap(self.manager)
    registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    XCTAssertEqual(try pull().map(\.title), [])
    XCTAssertEqual(fixture.reads, [], "Flash's own menus are never read")
  }

  /// `[plugins] disabled = ["menus"]` leaves `@menus` with no source.
  func testDisabledThePluginServesNoMenus() throws {
    manager.stop()
    manager = PluginManager(baseDataDir: dataDir)
    manager.hostRPC.axBroker = fixture.broker()
    manager.start(config: try Self.config(disabling: ["menus"]))
    let manager = try XCTUnwrap(self.manager)
    registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    XCTAssertTrue(registry.liveCandidateSources(matching: .type("menus")).isEmpty)
    XCTAssertEqual(fixture.reads, [])
  }
}
