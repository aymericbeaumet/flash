import ApplicationServices
import FlashCore
import XCTest

@testable import flash

/// The catalog against a fake Accessibility: no real app is read, and the
/// window elements are application elements of pids nothing runs as.
final class WindowSwitcherCatalogTests: XCTestCase {
  private let queue = DispatchQueue(label: "test.window-switcher-catalog")

  /// What the fake apps answer, and how often each was read.
  private final class FakeApps: @unchecked Sendable {
    private let lock = NSLock()
    /// What `kAXWindows` lists per app.
    private var listed: [pid_t: [AXUIElement]] = [:]
    /// Every live window's title, listed or not (another Space).
    private var alive: [AXUIElement: String] = [:]
    private var owned: [pid_t: [AXUIElement]] = [:]
    private var counts: [pid_t: Int] = [:]
    /// A read of this app waits until the test signals it.
    var gate: (pid: pid_t, semaphore: DispatchSemaphore)?

    /// `pid` lists `windows`; with `offSpace`, more windows stay alive
    /// unlisted. Every other window of the app is closed.
    func set(
      _ pid: pid_t, _ windows: [(AXUIElement, String)], offSpace: [(AXUIElement, String)] = []
    ) {
      lock.lock()
      for element in owned[pid] ?? [] { alive.removeValue(forKey: element) }
      listed[pid] = windows.map(\.0)
      owned[pid] = (windows + offSpace).map(\.0)
      for (element, title) in windows + offSpace { alive[element] = title }
      lock.unlock()
    }

    func reads(_ pid: pid_t) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return counts[pid] ?? 0
    }

    func read(_ pid: pid_t, remembered: [AXUIElement]) -> [WindowSwitcherCatalog.Window]? {
      if let gate, gate.pid == pid { gate.semaphore.wait() }
      lock.lock()
      counts[pid, default: 0] += 1
      let windows = listed[pid] ?? []
      let titles = alive
      lock.unlock()
      return WindowSwitcherCatalog.windows(
        pid: pid, listed: windows, remembered: remembered,
        read: { element in
          titles[element].map { .window(.init(title: $0, minimized: false, switchable: true)) }
            ?? .gone
        })
    }
  }

  private func element(_ index: Int32) -> AXUIElement { AXApp.make(pid: 80_000 + index) }

  private func makeCatalog(_ apps: FakeApps) -> WindowSwitcherCatalog {
    WindowSwitcherCatalog(
      queue: queue, scheduler: PollScheduler(), coalescingMs: 1,
      reader: { apps.read($0, remembered: $1) },
      appInfoLoader: { .init(name: "App \($0)", icon: nil) })
  }

  /// Every read queued so far has landed on main, and every read those
  /// installs queued too.
  private func settle(_ passes: Int = 2) {
    for _ in 0..<passes {
      let landed = expectation(description: "reads landed")
      queue.async { DispatchQueue.main.async { landed.fulfill() } }
      wait(for: [landed], timeout: 5)
    }
  }

  /// Long enough for a coalesced event read to be planned and land.
  private func settleEvents() {
    let planned = expectation(description: "coalescing elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { planned.fulfill() }
    wait(for: [planned], timeout: 5)
    settle()
  }

  private func titles(_ catalog: WindowSwitcherCatalog) -> [String] {
    catalog.rows.map(\.title)
  }

  func testRefreshListsEveryAppAndFocusReordersThem() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1"), (element(2), "a2")])
    apps.set(2, [(element(3), "b1")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1, 2], order: [2, 1])
    settle()
    XCTAssertEqual(titles(catalog), ["b1", "a1", "a2"], "nothing focused yet: stacking order")
    XCTAssertEqual(catalog.appName(for: 1), "App 1")

    catalog.appActivated(pid: 1)
    catalog.focusResolved(pid: 1, window: element(2))
    XCTAssertEqual(titles(catalog), ["a2", "a1", "b1"])
    XCTAssertEqual(catalog.current, WindowSwitcherKey(pid: 1, element: element(2)))
    settle()
    XCTAssertEqual(apps.reads(1), 1, "a window the catalog has is not read again")
  }

  func testAWindowFocusedBeforeItsAppWasReadAgainIsReadAndListed() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1], order: [1])
    settle()
    apps.set(1, [(element(1), "a1"), (element(2), "new")])
    catalog.appActivated(pid: 1)
    catalog.focusResolved(pid: 1, window: element(2))
    XCTAssertEqual(titles(catalog), ["a1"], "listed once its app is read")
    settle()
    XCTAssertEqual(titles(catalog), ["new", "a1"])
  }

  func testAClosedWindowLeavesTheListAndTheRecency() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1"), (element(2), "a2")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1], order: [1])
    settle()
    catalog.appActivated(pid: 1)
    catalog.focusResolved(pid: 1, window: element(2))
    catalog.focusResolved(pid: 1, window: element(1))
    apps.set(1, [(element(1), "a1")])
    catalog.windowsMayHaveChanged(pid: 1)
    settleEvents()
    XCTAssertEqual(titles(catalog), ["a1"])
    XCTAssertEqual(
      catalog.recency.windows, [WindowSwitcherKey(pid: 1, element: element(1))])
  }

  func testAWindowItsAppStopsListingButStillReadsIsOnAnotherSpace() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "here"), (element(2), "there")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1], order: [1])
    settle()
    XCTAssertEqual(catalog.rows.map(\.onActiveSpace), [true, true])
    // Another Space became active: Accessibility lists only `here`, and
    // `there` still answers.
    apps.set(1, [(element(1), "here")], offSpace: [(element(2), "there")])
    catalog.refresh(pids: [1], order: [1])
    settle()
    XCTAssertEqual(titles(catalog), ["here", "there"])
    XCTAssertEqual(catalog.rows.map(\.onActiveSpace), [true, false])
    // It closed there.
    apps.set(1, [(element(1), "here")])
    catalog.refresh(pids: [1], order: [1])
    settle()
    XCTAssertEqual(titles(catalog), ["here"])
  }

  func testBurstsOfWindowEventsCoalesceIntoOneReadPerApp() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1")])
    apps.set(2, [(element(2), "b1")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1, 2], order: [1, 2])
    settle()
    for _ in 0..<50 { catalog.windowsMayHaveChanged(pid: 1) }
    for _ in 0..<10 { catalog.windowsMayHaveChanged(pid: 2) }
    settleEvents()
    XCTAssertEqual(apps.reads(1), 2)
    XCTAssertEqual(apps.reads(2), 2)
  }

  func testAReadRequestedWhileOneIsInFlightRunsOnceAfterIt() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1")])
    let gate = DispatchSemaphore(value: 0)
    apps.gate = (1, gate)
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1], order: [1])
    catalog.refresh(pids: [1], order: [1])
    catalog.refresh(pids: [1], order: [1])
    apps.gate = nil
    gate.signal()
    settle(3)
    XCTAssertEqual(apps.reads(1), 2, "the in-flight read, then one for everything after it")
    XCTAssertEqual(titles(catalog), ["a1"])
  }

  func testAReadInFlightForAnAppThatQuitInstallsNothing() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1")])
    let gate = DispatchSemaphore(value: 0)
    apps.gate = (1, gate)
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1], order: [1])
    catalog.appActivated(pid: 1)
    catalog.focusResolved(pid: 1, window: element(1))
    catalog.appTerminated(pid: 1)
    apps.gate = nil
    gate.signal()
    settle()
    XCTAssertEqual(titles(catalog), [])
    XCTAssertEqual(catalog.recency.windows, [])
    XCTAssertNil(catalog.current)
  }

  func testOnlyListedAppsAreRead() {
    let apps = FakeApps()
    apps.set(9, [(element(9), "agent panel")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [], order: [])
    catalog.focusResolved(pid: 9, window: element(9))
    catalog.windowsMayHaveChanged(pid: 9)
    settleEvents()
    XCTAssertEqual(apps.reads(9), 0)
    XCTAssertEqual(titles(catalog), [])
    catalog.appLaunched(pid: 9)
    settleEvents()
    XCTAssertEqual(titles(catalog), ["agent panel"])
  }

  func testAppsNoLongerRunningAtARefreshAreForgotten() {
    let apps = FakeApps()
    apps.set(1, [(element(1), "a1")])
    apps.set(2, [(element(2), "b1")])
    let catalog = makeCatalog(apps)
    catalog.refresh(pids: [1, 2], order: [1, 2])
    settle()
    catalog.refresh(pids: [2], order: [2])
    settle()
    XCTAssertEqual(titles(catalog), ["b1"])
  }
}
