import FlashCore
import XCTest

@testable import flash

/// `desktop`, `missioncontrol`, `appwindows`, `launchpad`,
/// `notificationcenter` and `controlcenter`: the commands, the pure plan
/// that makes `show` and `hide` idempotent, and the controller sequencing
/// Dock requests on the Dock's own reports, against a fake backend so no
/// test opens anything on screen.
final class SystemSurfaceTests: XCTestCase {
  // MARK: - Commands

  func testEverySurfaceHasShowHideAndToggleCommands() throws {
    for surface in SystemSurface.allCases {
      for visibility in SurfaceVisibility.allCases {
        let command = SystemSurfaceCommand(surface, visibility)
        let words = [surface.rawValue, visibility.rawValue]
        XCTAssertEqual(URLEventHandler.parse(words: words), .systemSurface(command), "\(words)")
        XCTAssertEqual(
          URLCommand.systemSurface(command).argv, ["flash"] + words, "argv round-trips")
        XCTAssertEqual(URLEventHandler.summary(of: command.name), command.summary)
        XCTAssertNil(
          URLEventHandler.parse(words: words + ["--force"]), "\(words) takes no arguments")
      }
    }
    XCTAssertEqual(
      Set(SystemSurface.allCases.map(\.rawValue)),
      [
        "desktop", "missioncontrol", "appwindows", "launchpad", "notificationcenter",
        "controlcenter",
      ])
  }

  func testTheDockNotificationsAreTheOnesTheDockTakes() {
    XCTAssertEqual(SystemSurface.desktop.dockNotification, "com.apple.showdesktop.awake")
    XCTAssertEqual(SystemSurface.missionControl.dockNotification, "com.apple.expose.awake")
    XCTAssertEqual(SystemSurface.appWindows.dockNotification, "com.apple.expose.front.awake")
    XCTAssertEqual(SystemSurface.launchpad.dockNotification, "com.apple.launchpad.toggle")
    XCTAssertNil(SystemSurface.notificationCenter.dockNotification)
    XCTAssertNil(SystemSurface.controlCenter.dockNotification)
  }

  /// A system surface belongs to a macOS agent, not to an app Flash
  /// follows: no forced recapture, which would fight a panel that is key.
  func testSurfacesDoNotChangeKeyboardFocus() {
    for surface in SystemSurface.allCases {
      XCTAssertFalse(
        AppDelegate.normalModeCommandMayChangeKeyboardFocus(
          .systemSurface(SystemSurfaceCommand(surface, .show))), surface.rawValue)
    }
  }

  /// The trackpad gestures for these surfaces toggle them through the same
  /// owner as the commands.
  func testGesturesToggleTheSurfaces() {
    XCTAssertEqual(
      TrackpadGesture.action(fingers: 3, motion: .swipeUp), .surface(.missionControl))
    XCTAssertEqual(TrackpadGesture.action(fingers: 3, motion: .swipeDown), .surface(.appWindows))
    XCTAssertEqual(TrackpadGesture.action(fingers: 4, motion: .pinch), .surface(.launchpad))
    XCTAssertEqual(TrackpadGesture.action(fingers: 5, motion: .spread), .surface(.desktop))
  }

  // MARK: - The Dock's reports

  func testTheTrackerFollowsTheDocksReports() {
    var tracker = DockViewTracker()
    tracker.reset(pid: 7)
    XCTAssertEqual(tracker.view, .none)
    XCTAssertTrue(tracker.observe("AXExposeShowAllWindows"))
    XCTAssertEqual(tracker.view, .missionControl)
    XCTAssertFalse(tracker.observe("AXExposeShowAllWindows"), "no change")
    XCTAssertTrue(tracker.observe("AXExposeExit"))
    XCTAssertEqual(tracker.view, .none)
    XCTAssertTrue(tracker.observe("AXExposeShowFrontWindows"))
    XCTAssertEqual(tracker.view, .appWindows)
    XCTAssertTrue(tracker.observe("AXExposeShowDesktop"))
    XCTAssertEqual(tracker.view, .desktop)
    XCTAssertFalse(tracker.observe("AXUIElementDestroyed"), "not a view report")
    XCTAssertEqual(tracker.view, .desktop)
    tracker.timedOut()
    XCTAssertNil(tracker.knownView, "a silent Dock's view is unknown")
    XCTAssertTrue(tracker.observe("AXExposeExit"), "a report ends the silence")
    XCTAssertEqual(tracker.knownView, DockView.none)
    tracker.reset(pid: 8)
    XCTAssertEqual(tracker.view, .none, "a relaunched Dock starts with no view")
    XCTAssertEqual(tracker.pid, 8)
    tracker.reset(pid: nil)
    XCTAssertNil(tracker.knownView, "no Dock observed")
  }

  // MARK: - Plans

  private func plan(
    _ surface: SystemSurface, _ visibility: SurfaceVisibility, dock: DockView? = DockView.none,
    shown: Bool? = nil
  ) -> SurfacePlan {
    SystemSurfacePlanner.plan(
      SystemSurfaceCommand(surface, visibility), dockView: dock, shown: shown)
  }

  func testShowAndHideAreIdempotent() {
    XCTAssertEqual(
      plan(.missionControl, .show),
      .steps([.dock(.missionControl, awaiting: .missionControl)]))
    XCTAssertEqual(plan(.missionControl, .show, dock: .missionControl), .steps([]))
    XCTAssertEqual(plan(.missionControl, .hide), .steps([]))
    XCTAssertEqual(
      plan(.missionControl, .hide, dock: .missionControl),
      .steps([.dock(.missionControl, awaiting: .none)]))
    XCTAssertEqual(
      plan(.missionControl, .toggle, dock: .missionControl),
      .steps([.dock(.missionControl, awaiting: .none)]))
    XCTAssertEqual(
      plan(.desktop, .toggle), .steps([.dock(.desktop, awaiting: .desktop)]))
    XCTAssertEqual(
      plan(.appWindows, .show), .steps([.dock(.appWindows, awaiting: .appWindows)]))
  }

  /// From any Dock view a Dock request returns to the windows rather than
  /// switching views, so showing another one leaves the current view first.
  func testShowingAnotherDockViewLeavesTheCurrentOneFirst() {
    XCTAssertEqual(
      plan(.missionControl, .show, dock: .desktop),
      .steps([.dock(.desktop, awaiting: .none), .dock(.missionControl, awaiting: .missionControl)]))
    XCTAssertEqual(
      plan(.desktop, .toggle, dock: .appWindows),
      .steps([.dock(.appWindows, awaiting: .none), .dock(.desktop, awaiting: .desktop)]))
    XCTAssertEqual(
      plan(.appWindows, .hide, dock: .missionControl), .steps([]),
      "hiding a view that is not showing leaves the other alone")
  }

  /// Without the Dock's reports (no Accessibility, no Dock) only `toggle`
  /// can run: it asks the Dock blind.
  func testAnUnobservedDockOnlyToggles() {
    XCTAssertEqual(
      plan(.missionControl, .toggle, dock: nil),
      .steps([.dockUnobserved(.missionControl, shows: nil)]))
    guard case .refused(let reason) = plan(.missionControl, .show, dock: nil) else {
      return XCTFail("show needs the Dock's reports")
    }
    XCTAssertTrue(reason.contains("missioncontrol toggle"), reason)
  }

  func testLaunchpadReadsItsPanelAndLeavesADockViewFirst() {
    XCTAssertEqual(
      plan(.launchpad, .show, shown: false), .steps([.dockUnobserved(.launchpad, shows: true)]))
    XCTAssertEqual(plan(.launchpad, .show, shown: true), .steps([]))
    XCTAssertEqual(
      plan(.launchpad, .hide, shown: true), .steps([.dockUnobserved(.launchpad, shows: false)]))
    XCTAssertEqual(plan(.launchpad, .hide, shown: false), .steps([]))
    XCTAssertEqual(
      plan(.launchpad, .show, dock: .missionControl, shown: false),
      .steps([
        .dock(.missionControl, awaiting: .none), .dockUnobserved(.launchpad, shows: true),
      ]))
    XCTAssertEqual(
      plan(.launchpad, .toggle, shown: nil), .steps([.dockUnobserved(.launchpad, shows: nil)]),
      "before macOS 26 nothing reports Launchpad, so it can only be toggled")
    guard case .refused(let reason) = plan(.launchpad, .show, shown: nil) else {
      return XCTFail("show needs to know whether it is open")
    }
    XCTAssertTrue(reason.contains("launchpad toggle"), reason)
  }

  func testPanelsArePressedOnlyWhenTheyAreNotAsAsked() {
    XCTAssertEqual(
      plan(.notificationCenter, .show, shown: false),
      .steps([.press(.notificationCenter, shows: true)]))
    XCTAssertEqual(plan(.notificationCenter, .show, shown: true), .steps([]))
    XCTAssertEqual(
      plan(.controlCenter, .hide, shown: true), .steps([.press(.controlCenter, shows: false)]))
    XCTAssertEqual(plan(.controlCenter, .hide, shown: false), .steps([]))
    XCTAssertEqual(
      plan(.controlCenter, .toggle, shown: nil), .steps([.press(.controlCenter, shows: nil)]))
    guard case .refused = plan(.controlCenter, .hide, shown: nil) else {
      return XCTFail("hide needs to know whether it is open")
    }
  }

  // MARK: - Controller

  private final class FakeBackend: SystemSurfaceBackend {
    var dockReports: ((pid_t, String) -> Void)?
    var dockPID: pid_t? = 42
    var posted: [SystemSurface] = []
    var postAccepted = true
    var shown: [SystemSurface: Bool] = [:]
    var pressed: [SystemSurface] = []
    var timers: [(ms: Int, body: () -> Void)] = []
    var nowMs: UInt64 = 1_000

    func postDockNotification(for surface: SystemSurface) -> Bool {
      posted.append(surface)
      return postAccepted
    }
    func readShown(_ surface: SystemSurface) -> Bool? { shown[surface] }
    func press(_ surface: SystemSurface) -> String? {
      pressed.append(surface)
      return nil
    }
    func observeDock() -> pid_t? { dockPID }
    func after(_ ms: Int, _ body: @escaping () -> Void) { timers.append((ms, body)) }
    var rechecks: [(ms: Int, body: () -> Void)] = []
    func recheck(after ms: Int, _ body: @escaping () -> Void) { rechecks.append((ms, body)) }
  }

  /// Runs the panel confirmation read scheduled last, on the queue.
  private func fireRecheck() {
    guard let check = backend.rechecks.popLast() else { return XCTFail("no pending recheck") }
    queue.sync { check.body() }
    flush()
  }

  /// Runs the confirmation ladder to its end without the panel ever reaching
  /// the pressed state.
  private func exhaustRechecks() {
    while !backend.rechecks.isEmpty { fireRecheck() }
  }

  private let queue = DispatchQueue(label: "flash.tests.system_surfaces")
  private var backend: FakeBackend!
  private var controller: SystemSurfaceController!
  private var results: [String?] = []
  /// Every Dock view the controller published, in order (nil: unknown).
  private var views: [DockView?] = []

  override func setUp() {
    super.setUp()
    backend = FakeBackend()
    views = []
    controller = SystemSurfaceController(
      queue: queue, completionQueue: queue, backend: backend,
      dockViewChanged: { [unowned self] in self.views.append($0) })
    results = []
    controller.start()
    flush()
  }

  /// Runs everything queued, including completions queued by it.
  private func flush() {
    for _ in 0..<3 { queue.sync {} }
  }

  private func perform(_ surface: SystemSurface, _ visibility: SurfaceVisibility) {
    controller.perform(SystemSurfaceCommand(surface, visibility)) { [unowned self] in
      self.results.append($0)
    }
    flush()
  }

  private func report(_ notification: String, pid: pid_t = 42) {
    backend.dockReports?(pid, notification)
    flush()
  }

  func testShowWaitsForTheDocksReport() {
    perform(.missionControl, .show)
    XCTAssertEqual(backend.posted, [.missionControl])
    XCTAssertTrue(results.isEmpty, "show completes once the Dock reports the view")
    report("AXExposeShowAllWindows")
    XCTAssertEqual(results, [nil])
    perform(.missionControl, .show)
    XCTAssertEqual(backend.posted, [.missionControl], "already showing: nothing is sent")
    XCTAssertEqual(results, [nil, nil])
  }

  /// `missioncontrol show` over Show Desktop: one request leaves Show
  /// Desktop, the Dock reports the exit, then the second shows Mission
  /// Control.
  func testShowFromAnotherViewLeavesItThenShows() {
    report("AXExposeShowDesktop")
    perform(.missionControl, .show)
    XCTAssertEqual(backend.posted, [.desktop])
    report("AXExposeExit")
    XCTAssertEqual(backend.posted, [.desktop, .missionControl])
    XCTAssertTrue(results.isEmpty)
    report("AXExposeShowAllWindows")
    XCTAssertEqual(results, [nil])
  }

  /// A request waits behind the one in flight, and plans from the view the
  /// Dock reported when its turn comes: two toggles open, then close.
  func testRequestsRunOneAtATime() {
    perform(.missionControl, .toggle)
    perform(.missionControl, .toggle)
    XCTAssertEqual(backend.posted, [.missionControl])
    report("AXExposeShowAllWindows")
    XCTAssertEqual(backend.posted, [.missionControl, .missionControl])
    report("AXExposeExit")
    XCTAssertEqual(results, [nil, nil])
  }

  /// A Dock that leaves a request unconfirmed fails it and is silent from
  /// then on: `show` and `hide` refuse, `toggle` asks blind, and its next
  /// report makes it trusted again.
  func testASilentDockFailsTheRequestAndFreesTheQueue() throws {
    perform(.desktop, .show)
    perform(.desktop, .hide)
    let timeout = try XCTUnwrap(backend.timers.last)
    XCTAssertEqual(timeout.ms, SystemSurfaceController.dockReportTimeoutMs)
    queue.sync { timeout.body() }
    flush()
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results[0]?.contains("Show Desktop opening") ?? false, "\(results)")
    XCTAssertTrue(results[1]?.contains("desktop toggle") ?? false, "\(results)")
    perform(.desktop, .toggle)
    XCTAssertEqual(backend.posted, [.desktop, .desktop], "toggle asks the silent Dock blind")
    XCTAssertEqual(results.count, 3)
    XCTAssertNil(results[2])
    report("AXExposeShowDesktop")
    perform(.desktop, .hide)
    XCTAssertEqual(backend.posted, [.desktop, .desktop, .desktop], "trusted again")
    queue.sync { timeout.body() }
    flush()
    XCTAssertEqual(results.count, 3, "a timeout that lost its request does nothing")
  }

  /// A toggle's request went out: unconfirmed, it still ran as asked.
  func testAnUnconfirmedToggleStillRan() throws {
    perform(.missionControl, .toggle)
    let timeout = try XCTUnwrap(backend.timers.last)
    queue.sync { timeout.body() }
    flush()
    XCTAssertEqual(results, [nil])
  }

  /// Reports from a Dock that relaunched are dropped, and the new Dock
  /// starts with no view.
  func testARelaunchedDockStartsOver() {
    report("AXExposeShowAllWindows")
    backend.dockPID = 43
    perform(.missionControl, .hide)
    XCTAssertEqual(backend.posted, [], "the new Dock shows no view")
    XCTAssertEqual(results, [nil])
    perform(.missionControl, .show)
    report("AXExposeShowAllWindows", pid: 42)
    XCTAssertEqual(results, [nil], "the old Dock's report does not count")
    report("AXExposeShowAllWindows", pid: 43)
    XCTAssertEqual(results, [nil, nil])
  }

  /// `f` reads the Dock's view as the Dock reports it, however the view was
  /// opened: each change is published once, a silent Dock's view is unknown,
  /// and a relaunched Dock starts with none.
  func testTheDocksViewIsPublishedAsItChanges() throws {
    XCTAssertEqual(views, [DockView.none], "observing a Dock: no view shows")
    report("AXExposeShowAllWindows")
    report("AXExposeShowAllWindows")
    report("AXExposeShowFrontWindows")
    report("AXExposeExit")
    XCTAssertEqual(views, [DockView.none, .missionControl, .appWindows, DockView.none])
    perform(.missionControl, .show)
    let timeout = try XCTUnwrap(backend.timers.last)
    queue.sync { timeout.body() }
    flush()
    XCTAssertEqual(views.last, .some(nil), "a Dock that left a request unconfirmed is unknown")
    report("AXExposeShowAllWindows")
    XCTAssertEqual(views.last, .missionControl)
    backend.dockPID = 43
    perform(.desktop, .toggle)
    XCTAssertEqual(views.last, DockView.none, "a relaunched Dock shows no view")
  }

  func testAMissingDockEntryPointFails() {
    backend.postAccepted = false
    perform(.missionControl, .toggle)
    XCTAssertEqual(results.count, 1)
    XCTAssertNotNil(results[0])
  }

  /// A panel press waits for the panel before the next request plans: the
  /// next one reads what the panel really did.
  func testAPanelPressWaitsForThePanelBeforeTheNextRequest() {
    backend.shown[.notificationCenter] = false
    perform(.notificationCenter, .toggle)
    XCTAssertEqual(backend.pressed, [.notificationCenter])
    XCTAssertEqual(results, [], "not done until the panel shows")
    XCTAssertEqual(backend.rechecks.first?.ms, SystemSurfaceController.panelConfirmDelaysMs[0])
    fireRecheck()
    XCTAssertEqual(results, [], "still closed: the ladder goes on")
    backend.shown[.notificationCenter] = true
    fireRecheck()
    XCTAssertEqual(results, [nil])
    perform(.notificationCenter, .toggle)
    XCTAssertEqual(
      backend.pressed, [.notificationCenter, .notificationCenter], "the read (open) decides")
  }

  /// The regression: a burst of toggles pressed the clock faster than the
  /// panel follows, so presses were lost and the state drifted. Requests
  /// queued behind a press fold into their net effect.
  func testABurstOfTogglesEndsAsItsCountSays() {
    backend.shown[.notificationCenter] = false
    for _ in 0..<5 { perform(.notificationCenter, .toggle) }
    XCTAssertEqual(backend.pressed, [.notificationCenter], "one press while it opens")
    backend.shown[.notificationCenter] = true
    fireRecheck()
    XCTAssertEqual(backend.pressed, [.notificationCenter], "four more toggles cancel out")
    XCTAssertEqual(results, [nil, nil, nil, nil, nil])

    results = []
    for _ in 0..<4 { perform(.notificationCenter, .toggle) }
    XCTAssertEqual(backend.pressed.count, 2, "the first of four closes it")
    backend.shown[.notificationCenter] = false
    fireRecheck()
    XCTAssertEqual(backend.pressed.count, 3, "three more net one toggle: open again")
    backend.shown[.notificationCenter] = true
    fireRecheck()
    XCTAssertEqual(results, [nil, nil, nil, nil])
    XCTAssertEqual(backend.shown[.notificationCenter], true, "an even burst ends where it began")
  }

  /// A `show` or `hide` decides whatever was queued before it.
  func testAShowOrHideDecidesTheBurst() {
    XCTAssertEqual(SurfaceEffect(.toggle).then(.toggle), .unchanged)
    XCTAssertEqual(SurfaceEffect(.toggle).then(.hide), .hide)
    XCTAssertEqual(SurfaceEffect(.show).then(.toggle), .hide)
    XCTAssertEqual(SurfaceEffect(.hide).then(.toggle).then(.toggle), .hide)
    XCTAssertNil(SurfaceEffect.unchanged.visibility)
  }

  /// A panel that never confirms frees the queue at the end of the ladder;
  /// the press is then trusted until it settles, so a `hide` queued behind
  /// an unconfirmed `show` plans against "open" and presses again.
  func testAnUnconfirmedPressFreesTheQueue() {
    backend.shown[.notificationCenter] = false
    perform(.notificationCenter, .show)
    perform(.notificationCenter, .hide)
    XCTAssertEqual(backend.pressed, [.notificationCenter])
    exhaustRechecks()
    XCTAssertEqual(results, [nil, nil])
    XCTAssertEqual(backend.pressed, [.notificationCenter, .notificationCenter])
  }
}
