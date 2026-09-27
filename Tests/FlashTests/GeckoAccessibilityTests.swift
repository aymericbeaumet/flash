import ApplicationServices
import XCTest

@testable import FlashCore

final class GeckoAccessibilityLedgerTests: XCTestCase {
  private typealias Ledger = GeckoAccessibilityLedger
  private typealias State = GeckoAccessibilityLedger.ProcessState

  private func lingering(_ pid: pid_t, in ledger: inout Ledger) {
    ledger.beginScope(pid: pid, modeWasOn: false)
    XCTAssertFalse(ledger.endScope(pid: pid))
  }

  func testAFocusedAppKeepsTheModeFlashTurnedOn() {
    var ledger = Ledger()
    XCTAssertEqual(ledger.focusChanged(to: 10), [])
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true, lingerUntilFocusLoss: true))

    // The next operation finds the mode on, and it is still Flash's.
    ledger.beginScope(pid: 10, modeWasOn: true)
    XCTAssertEqual(ledger.processes[10]?.ownedByFlash, true)
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true, lingerUntilFocusLoss: true))
  }

  func testAnAppThatIsNotFocusedIsSwitchedOffAfterEachOperation() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 20)
    ledger.beginScope(pid: 10, modeWasOn: false)
    XCTAssertTrue(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
  }

  func testWithoutFocusReportsNothingLingers() {
    var ledger = Ledger()
    ledger.beginScope(pid: 10, modeWasOn: false)
    XCTAssertTrue(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
  }

  func testAModeAnotherClientTurnedOnIsNeverSwitchedOff() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    ledger.beginScope(pid: 10, modeWasOn: true)
    XCTAssertFalse(ledger.prepareGeometry(pid: 10))
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertEqual(ledger.focusChanged(to: 20), [])
    XCTAssertEqual(ledger.spaceChanged(), [])
    XCTAssertEqual(ledger.stop(), [])
    XCTAssertFalse(ledger.takeRelease(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
  }

  func testLosingFocusMakesTheLingeringModeDueOnce() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.focusChanged(to: 20), [10])
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true))
    XCTAssertTrue(ledger.takeRelease(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
    XCTAssertFalse(ledger.takeRelease(pid: 10))
  }

  func testRegainingFocusBeforeTheReleaseRunsKeepsTheMode() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.focusChanged(to: 20), [10])
    XCTAssertEqual(ledger.focusChanged(to: 10), [])
    XCTAssertFalse(ledger.takeRelease(pid: 10))
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true, lingerUntilFocusLoss: true))
  }

  func testAGeometryWriteSwitchesALingeringModeOffUntilTheNextOperation() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)

    // A window move: its scope finds Flash's mode on, and switches it off
    // before writing, however focused the app is.
    ledger.beginScope(pid: 10, modeWasOn: true)
    XCTAssertTrue(ledger.prepareGeometry(pid: 10))
    XCTAssertFalse(ledger.prepareGeometry(pid: 10))
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)

    // The next tree operation turns it on again, and it lingers again.
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true, lingerUntilFocusLoss: true))
  }

  func testASpaceChangeMakesEveryFlashModeDueTheFocusedOneIncluded() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 30)
    lingering(30, in: &ledger)
    XCTAssertEqual(ledger.focusChanged(to: 10), [30])
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.spaceChanged(), [10, 30])
    XCTAssertTrue(ledger.takeRelease(pid: 10))
    XCTAssertTrue(ledger.takeRelease(pid: 30))
    XCTAssertTrue(ledger.processes.isEmpty)
    XCTAssertEqual(ledger.focusedPID, 10)
  }

  func testAnOperationAfterASpaceChangeReArmsTheFocusedApp() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.spaceChanged(), [10])
    ledger.beginScope(pid: 10, modeWasOn: true)
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertFalse(ledger.takeRelease(pid: 10))
    XCTAssertEqual(ledger.processes[10], State(ownedByFlash: true, lingerUntilFocusLoss: true))
  }

  func testStoppingForgetsFocusSoLaterOperationsRestoreTheMode() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)
    XCTAssertEqual(ledger.stop(), [10])
    XCTAssertNil(ledger.focusedPID)
    XCTAssertTrue(ledger.takeRelease(pid: 10))
    ledger.beginScope(pid: 10, modeWasOn: false)
    XCTAssertTrue(ledger.endScope(pid: 10))
  }

  func testTerminationForgetsTheProcessWithoutASwitchOff() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    lingering(10, in: &ledger)
    ledger.terminated(pid: 10)
    XCTAssertNil(ledger.focusedPID)
    XCTAssertTrue(ledger.processes.isEmpty)
    XCTAssertFalse(ledger.takeRelease(pid: 10))
  }

  func testTerminationDuringAnOperationLeavesNothingToSwitchOff() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    ledger.beginScope(pid: 10, modeWasOn: false)
    ledger.terminated(pid: 10)
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
  }

  func testNestedOperationsDecideOnlyAtTheOutermostEnd() {
    var ledger = Ledger()
    ledger.beginScope(pid: 10, modeWasOn: false)
    ledger.beginScope(pid: 10, modeWasOn: true)
    XCTAssertFalse(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.endScope(pid: 10))
    XCTAssertFalse(ledger.endScope(pid: 10))
  }

  func testAReleaseLeavesAnOperationInProgressToItsOwnEnd() {
    var ledger = Ledger()
    _ = ledger.focusChanged(to: 10)
    ledger.beginScope(pid: 10, modeWasOn: false)
    XCTAssertEqual(ledger.focusChanged(to: 20), [10])
    XCTAssertFalse(ledger.takeRelease(pid: 10))
    XCTAssertTrue(ledger.endScope(pid: 10))
    XCTAssertTrue(ledger.processes.isEmpty)
  }
}

final class GeckoAccessibilityCoordinatorTests: XCTestCase {
  /// Gecko as the coordinator sees it: a mode per process that a role read
  /// turns on and the setter turns off, and a log of every AX call.
  private final class FakeGecko {
    var modes: [pid_t: Bool] = [:]
    var events: [String] = []
    var pending: [() -> Void] = []
    let geckoPIDs: Set<pid_t> = [10, 20]
    let runsReleasesImmediately: Bool

    init(runsReleasesImmediately: Bool = false) {
      self.runsReleasesImmediately = runsReleasesImmediately
    }

    lazy var coordinator = GeckoAccessibilityCoordinator(
      driver: GeckoAccessibilityDriver(
        isGecko: { [unowned self] _, pid in self.geckoPIDs.contains(pid) },
        makeApp: { AXApp.make(pid: $0) },
        readMode: { [unowned self] app in
          let pid = Self.pid(of: app)
          self.events.append("read \(pid)")
          return self.modes[pid]
        },
        wake: { [unowned self] app in
          let pid = Self.pid(of: app)
          self.events.append("wake \(pid)")
          self.modes[pid] = true
        },
        switchOff: { [unowned self] app in
          let pid = Self.pid(of: app)
          self.events.append("off \(pid)")
          self.modes[pid] = false
        },
        schedule: { [unowned self] job in
          if self.runsReleasesImmediately { job() } else { self.pending.append(job) }
        }))

    func walk(_ pid: pid_t) {
      coordinator.withTree(pid: pid, bundleIdentifier: nil, app: nil) { _ in
        events.append("walk \(pid)")
      }
    }

    func runPendingReleases() {
      let jobs = pending
      pending.removeAll()
      for job in jobs { job() }
    }

    func takeEvents() -> [String] {
      defer { events.removeAll() }
      return events
    }

    static func pid(of app: AXUIElement) -> pid_t {
      var pid: pid_t = 0
      _ = AXUIElementGetPid(app, &pid)
      return pid
    }
  }

  func testAppsOutsideGeckoPassThroughUntouched() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 99)
    gecko.walk(99)
    let moved = gecko.coordinator.withWindowManagement(
      pid: 99, bundleIdentifier: nil, app: nil
    ) { _, prepareGeometry in
      prepareGeometry()
      return true
    }
    XCTAssertTrue(moved)
    XCTAssertEqual(gecko.takeEvents(), ["walk 99"])
    XCTAssertTrue(gecko.coordinator.snapshot.processes.isEmpty)
  }

  func testAnUnfocusedGeckoAppIsRestoredAfterEveryOperation() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 20)
    gecko.walk(10)
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "walk 10", "off 10"])
    XCTAssertEqual(gecko.modes[10], false)
  }

  func testAFocusedGeckoAppKeepsItsTreeBetweenWalks() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    gecko.walk(10)
    XCTAssertEqual(
      gecko.takeEvents(), ["read 10", "wake 10", "walk 10", "read 10", "wake 10", "walk 10"])
    XCTAssertEqual(gecko.modes[10], true)
  }

  func testLosingFocusSwitchesTheModeOffOffTheReportingThread() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.focusChanged(to: 20)
    XCTAssertEqual(gecko.takeEvents(), [])
    gecko.runPendingReleases()
    XCTAssertEqual(gecko.takeEvents(), ["off 10"])
    XCTAssertEqual(gecko.modes[10], false)
    XCTAssertTrue(gecko.coordinator.snapshot.processes.isEmpty)
  }

  func testFocusReturningBeforeTheReleaseRunsKeepsTheTree() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.focusChanged(to: 20)
    gecko.coordinator.focusChanged(to: 10)
    gecko.runPendingReleases()
    XCTAssertEqual(gecko.takeEvents(), [])
    XCTAssertEqual(gecko.modes[10], true)
  }

  func testAWindowMoveSwitchesTheModeOffBeforeItsGeometryWrite() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.withWindowManagement(pid: 10, bundleIdentifier: nil, app: nil) {
      _, prepareGeometry in
      gecko.events.append("read frame")
      prepareGeometry()
      gecko.events.append("write frame")
    }
    XCTAssertEqual(
      gecko.takeEvents(), ["read 10", "wake 10", "read frame", "off 10", "write frame"])
    XCTAssertEqual(gecko.modes[10], false)

    // The next walk turns the mode on again, and it lingers again.
    gecko.walk(10)
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "walk 10"])
    XCTAssertEqual(gecko.modes[10], true)
  }

  func testAWindowScopeThatWritesNothingStillEndsWithTheModeOff() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.coordinator.withWindowManagement(pid: 10, bundleIdentifier: nil, app: nil) { _, _ in }
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "off 10"])
  }

  func testAnotherClientsModeIsNeverSwitchedOff() {
    let gecko = FakeGecko()
    gecko.modes[10] = true
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    gecko.coordinator.withWindowManagement(pid: 10, bundleIdentifier: nil, app: nil) {
      _, prepareGeometry in prepareGeometry()
    }
    gecko.coordinator.focusChanged(to: 20)
    gecko.coordinator.spaceChanged()
    gecko.runPendingReleases()
    gecko.walk(10)
    XCTAssertFalse(gecko.takeEvents().contains("off 10"))
    XCTAssertEqual(gecko.modes[10], true)
  }

  func testASpaceChangeSwitchesTheModeOffAndTheNextWalkRebuildsIt() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.spaceChanged()
    gecko.runPendingReleases()
    XCTAssertEqual(gecko.takeEvents(), ["off 10"])
    gecko.walk(10)
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "walk 10"])
    XCTAssertEqual(gecko.modes[10], true)
  }

  func testReleasingAllSwitchesEveryModeOffAndEndsLingering() {
    let gecko = FakeGecko(runsReleasesImmediately: true)
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.releaseAll(waitingAtMost: .seconds(1))
    XCTAssertEqual(gecko.takeEvents(), ["off 10"])
    XCTAssertNil(gecko.coordinator.snapshot.focusedPID)
    gecko.walk(10)
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "walk 10", "off 10"])
  }

  func testTerminationForgetsTheProcessWithoutTouchingIt() {
    let gecko = FakeGecko()
    gecko.coordinator.focusChanged(to: 10)
    gecko.walk(10)
    _ = gecko.takeEvents()
    gecko.coordinator.appTerminated(pid: 10)
    gecko.coordinator.focusChanged(to: 20)
    gecko.runPendingReleases()
    XCTAssertEqual(gecko.takeEvents(), [])
    XCTAssertTrue(gecko.coordinator.snapshot.processes.isEmpty)
  }

  func testAReleaseDuringAWalkLeavesTheSwitchOffToTheWalksEnd() {
    let gecko = FakeGecko(runsReleasesImmediately: true)
    gecko.coordinator.focusChanged(to: 10)
    gecko.coordinator.withTree(pid: 10, bundleIdentifier: nil, app: nil) { _ in
      // Runs the release on this thread, inside the walk's process lock.
      gecko.coordinator.focusChanged(to: 20)
      gecko.events.append("walk 10")
    }
    XCTAssertEqual(gecko.takeEvents(), ["read 10", "wake 10", "walk 10", "off 10"])
  }
}
