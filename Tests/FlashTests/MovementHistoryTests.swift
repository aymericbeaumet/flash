import AppKit
import FlashCore
import XCTest

@testable import flash

final class MovementHistoryTests: XCTestCase {
  private func delegate() -> AppDelegate {
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(
      descriptors: [], runningApplications: [],
      pluginSourcesProvider: { [NavigationSource()] })
    return delegate
  }

  private func location(_ name: String, pid: pid_t = 10) -> Candidate {
    Candidate(
      kind: .plugin("tab"), sourceID: "test.navigation", source: "test.tabs", pid: pid,
      title: name, navigationURL: URL(string: "test-navigation://tab/\(name)")!,
      isLocation: true, isCurrentLocation: true)
  }

  private func application(pid: pid_t) -> Candidate {
    Candidate(
      kind: .app, sourceID: "core.apps", source: "apps", pid: pid, title: "App \(pid)",
      bundleIdentifier: "test.app.\(pid)", isLocation: true)
  }

  func testAmbientTabLocationsJoinTheCrossApplicationHistory() {
    let app = delegate()
    let firefox = location("firefox-one", pid: 10)
    let tmux = location("tmux-one", pid: 20)
    let next = location("tmux-two", pid: 20)
    for candidate in [firefox, tmux, next] {
      app.recordAmbientLocation(candidate, processID: candidate.pid!, source: "catalog")
    }

    XCTAssertEqual(
      app.movementBackStack.compactMap { $0.candidate?.title }, ["firefox-one", "tmux-one"])
    XCTAssertEqual(app.movementCurrent?.candidate?.title, "tmux-two")
  }

  func testAppFallbackIsUpgradedWithoutAnExtraHistoryStop() {
    let app = delegate()
    app.recordAmbientLocation(application(pid: 10), processID: 10, source: "activation")
    app.recordAmbientLocation(location("firefox-one"), processID: 10, source: "catalog")
    app.recordAmbientLocation(application(pid: 10), processID: 10, source: "activation")

    XCTAssertTrue(app.movementBackStack.isEmpty)
    XCTAssertEqual(app.movementCurrent?.candidate?.title, "firefox-one")
  }

  func testRevisitingALocationPreservesChronologicalStops() {
    let app = delegate()
    for name in ["one", "two", "one", "three"] {
      app.recordMovement(.candidate(location(name)), source: "source_open")
    }

    XCTAssertEqual(app.movementBackStack.compactMap { $0.candidate?.title }, ["one", "two", "one"])
  }

  func testLateAmbientObservationCannotBranchAnInFlightRestore() {
    let app = delegate()
    let target = location("one")
    let previous = location("two", pid: 20)
    app.movementCurrent = .candidate(target)
    app.movementForwardStack = [.candidate(previous)]
    app.movementNavigationTargetKey = "route:\(target.navigationURL!.absoluteString)"

    app.recordAmbientLocation(previous, processID: 20, source: "catalog")

    XCTAssertEqual(app.movementCurrent?.candidate?.title, "one")
    XCTAssertTrue(app.movementBackStack.isEmpty)
    XCTAssertEqual(app.movementForwardStack.compactMap { $0.candidate?.title }, ["two"])
    XCTAssertNotNil(app.movementNavigationTargetKey)

    app.recordAmbientLocation(target, processID: 10, source: "catalog")
    XCTAssertNil(app.movementNavigationTargetKey)
    XCTAssertEqual(app.movementForwardStack.compactMap { $0.candidate?.title }, ["two"])
  }

  func testExplicitNavigationBranchesAndDiscardsTheForwardStack() {
    let app = delegate()
    let previous = location("one")
    app.movementCurrent = .candidate(previous)
    app.movementForwardStack = [.candidate(location("two"))]
    app.movementNavigationTargetKey = "route:\(previous.navigationURL!.absoluteString)"

    app.recordMovement(.candidate(location("three")), source: "source_open")

    XCTAssertEqual(app.movementCurrent?.candidate?.title, "three")
    XCTAssertEqual(app.movementBackStack.compactMap { $0.candidate?.title }, ["one"])
    XCTAssertTrue(app.movementForwardStack.isEmpty)
    XCTAssertNil(app.movementNavigationTargetKey)
  }

  func testMultipleSelectedWindowsUseTheFocusedDocumentToResolveTheCurrentTab() {
    let source = NavigationSource()
    source.focusedDocument = "https://example.com/front"
    let registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { [source] })
    var background = location("background")
    background.url = URL(string: "https://example.com/background")
    var front = location("front")
    front.url = URL(string: source.focusedDocument!)
    let context = AppContext(
      bundleIdentifier: "test.browser", processID: 10, runningApp: .current,
      frontWindowFrame: .zero, allScreensFrame: .zero)

    XCTAssertEqual(
      registry.currentLocation(in: context, candidates: [background, front])?.title, "front")
  }

  func testChangedTabSelectionIsRecordedAmongSeveralTerminalWindows() {
    let app = delegate()
    let first = location("first-window-tab-one")
    let background = location("background-window-tab")
    XCTAssertFalse(app.recordPublishedLocations([first, background], processID: 10))
    app.recordAmbientLocation(first, processID: 10, source: "window_focus")

    let next = location("first-window-tab-two")
    XCTAssertTrue(app.recordPublishedLocations([next, background], processID: 10))

    XCTAssertEqual(app.movementCurrent?.candidate?.title, "first-window-tab-two")
    XCTAssertEqual(
      app.movementBackStack.compactMap { $0.candidate?.title }, ["first-window-tab-one"])
  }

  func testUnchangedCatalogDoesNotReplayThePreviousTabAfterADirectJump() {
    let app = delegate()
    let first = location("one")
    let next = location("two")
    app.recordPublishedLocations([first], processID: 10)
    app.recordMovement(.candidate(next), source: "source_open")
    app.recordPublishedLocations([first], processID: 10)
    app.recordPublishedLocations([next], processID: 10)

    XCTAssertEqual(app.movementCurrent?.candidate?.title, "two")
    XCTAssertEqual(app.movementBackStack.compactMap { $0.candidate?.title }, ["one"])
  }

  func testBackAndForwardTraverseTheSameCrossApplicationStops() {
    let app = delegate()
    let first = location("firefox", pid: 10)
    let second = location("tmux", pid: 20)
    let third = application(pid: 30)
    for candidate in [first, second, third] {
      app.recordMovement(.candidate(candidate), source: "source_open")
    }

    XCTAssertEqual(
      app.takeMovementHistoryTarget(direction: .back, current: .candidate(third))?.candidate?.title,
      "tmux")
    XCTAssertEqual(
      app.takeMovementHistoryTarget(direction: .back, current: .candidate(second))?.candidate?
        .title,
      "firefox")
    XCTAssertEqual(
      app.takeMovementHistoryTarget(direction: .forward, current: .candidate(first))?.candidate?
        .title,
      "tmux")
    XCTAssertEqual(
      app.takeMovementHistoryTarget(direction: .forward, current: .candidate(second))?.candidate?
        .title,
      "App 30")
  }

  func testCurrentLocationThatArrivesBeforeItsCatalogTickStillHasAPreviousStop() {
    let app = delegate()
    for name in ["one", "two"] {
      app.recordMovement(.candidate(location(name)), source: "source_open")
    }

    let target = app.takeMovementHistoryTarget(
      direction: .back, current: .candidate(location("three")))

    XCTAssertEqual(target?.candidate?.title, "two")
    XCTAssertEqual(app.movementBackStack.compactMap { $0.candidate?.title }, ["one"])
    XCTAssertEqual(app.movementForwardStack.compactMap { $0.candidate?.title }, ["three"])
  }

  func testHistoryRemainsBounded() {
    let app = delegate()
    for index in 0...25 {
      app.recordMovement(.candidate(location("tab-\(index)")), source: "source_open")
    }
    XCTAssertEqual(app.movementBackStack.count, 20)
    XCTAssertEqual(app.movementBackStack.first?.candidate?.title, "tab-5")
  }
}

private final class NavigationSource: FlashSource {
  let identifier = "test.navigation"
  let priority = 0
  let capabilities: FlashSourceCapabilities = [
    .jumpTargets, .candidates, .navigationRoutes, .documentURL,
  ]
  let navigationSchemes: Set<String> = ["test-navigation"]
  var focusedDocument: String?
  func supports(_ context: AppContext) -> Bool { true }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }
  func documentURL(in context: AppContext) -> String? { focusedDocument }
}
