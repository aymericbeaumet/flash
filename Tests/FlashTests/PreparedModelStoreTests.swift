import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class PreparedModelStoreTests: XCTestCase {
  func testLookupRequiresMatchingTokenRevisionAndFreshness() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    store.store(
      model(
        pid: 42,
        token: 7,
        revision: 3,
        computedAt: now,
        targets: [target(id: "one")]))

    XCTAssertNotNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 3,
        now: now))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 8,
        configRevision: 3,
        now: now))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 4,
        now: now))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 3,
        now: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 1_600_000_000)))
  }

  func testLookupHonoursTheModelsOwnFreshnessCeiling() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    var extended = model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [])
    extended.freshnessMs = 6_000
    store.store(extended)
    let later = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 5_000_000_000)
    XCTAssertNotNil(store.lookup(pid: 42, dirtyToken: 7, configRevision: 3, now: later))
    let tooLate = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 6_100_000_000)
    XCTAssertNil(store.lookup(pid: 42, dirtyToken: 7, configRevision: 3, now: tooLate))
  }

  func testFreshnessDoublesOnlyForUnchangedMaintenanceWalks() {
    let now = DispatchTime(uptimeNanoseconds: 1_000)
    let previous = model(
      pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "one")])
    let same = model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "one")])
    XCTAssertEqual(
      AppMonitor.nextFreshnessMs(previous: previous, built: same, reason: .maintenance),
      AppMonitor.modelFreshnessMs * 2)
    var grown = previous
    grown.freshnessMs = AppMonitor.modelFreshnessMaxMs
    XCTAssertEqual(
      AppMonitor.nextFreshnessMs(previous: grown, built: same, reason: .maintenance),
      AppMonitor.modelFreshnessMaxMs)
    XCTAssertEqual(
      AppMonitor.nextFreshnessMs(previous: previous, built: same, reason: .focus),
      AppMonitor.modelFreshnessMs)
    let moved = model(
      pid: 42, token: 7, revision: 3, computedAt: now,
      targets: [target(id: "one", frame: CGRect(x: 5, y: 5, width: 10, height: 10))])
    XCTAssertEqual(
      AppMonitor.nextFreshnessMs(previous: previous, built: moved, reason: .maintenance),
      AppMonitor.modelFreshnessMs)
    XCTAssertEqual(
      AppMonitor.nextFreshnessMs(previous: nil, built: same, reason: .maintenance),
      AppMonitor.modelFreshnessMs)
  }

  func testEmptyReadyModelIsDistinctFromMissingModel() {
    let now = DispatchTime(uptimeNanoseconds: 1_000)
    var store = PreparedModelStore()
    store.store(model(pid: 7, token: 1, revision: 1, computedAt: now, targets: []))

    let found = store.lookup(
      pid: 7,
      dirtyToken: 1,
      configRevision: 1,
      now: now)
    XCTAssertNotNil(found)
    XCTAssertTrue(found?.isEmptyReady ?? false)
    XCTAssertNil(
      store.lookup(
        pid: 8,
        dirtyToken: 1,
        configRevision: 1,
        now: now))
  }

  /// The logged Firefox case: a test run's floating window covered the
  /// focused window, the walk found no visible region and stored an empty
  /// model that no AX event would ever invalidate once the window left. An
  /// occluded walk is never cached, and the model it found is not served
  /// either: what was walked before the window was covered no longer
  /// describes the screen.
  func testAWalkOfAFullyCoveredWindowIsNeverCachedAndEvictsTheCurrentModel() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    XCTAssertTrue(
      store.store(
        model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "one")])))

    XCTAssertFalse(
      store.store(
        model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [], occluded: true)))
    XCTAssertNil(store.current(pid: 42))
    XCTAssertNil(store.lookup(pid: 42, dirtyToken: 7, configRevision: 3, now: now))
  }

  /// The snapshot side of the same case: a floating window of another
  /// process over the whole focused window leaves it no visible region, so
  /// the walk is occluded. A fully transparent window covers nothing.
  func testAFloatingWindowOverTheFocusedWindowLeavesItNoVisibleRegion() {
    let window = CGRect(x: 0, y: 0, width: 2_048, height: 1_122)
    let screen = CGRect(x: 0, y: 0, width: 2_048, height: 1_152)
    func regions(coverAlpha: Double) -> [CGRect] {
      let snapshot = WindowSnapshot.build(
        entries: [
          WindowSnapshot.Entry(pid: 64_238, layer: 3, nsBounds: screen, alpha: coverAlpha),
          WindowSnapshot.Entry(pid: 42, layer: 0, nsBounds: window),
        ],
        focusedPid: 42)
      return AppMonitor.discoveryVisibleRegions(
        of: 42, in: snapshot, whenWindowListUnavailable: window)
    }
    XCTAssertEqual(regions(coverAlpha: 1), [])
    XCTAssertEqual(regions(coverAlpha: 0), [window])
  }

  func testDiscardModelKeepsRebuildGuard() {
    var store = PreparedModelStore()
    XCTAssertTrue(store.beginRebuild(pid: 3))
    store.discardModel(pid: 3)
    XCTAssertFalse(store.beginRebuild(pid: 3))
    XCTAssertTrue(store.finishRebuild(pid: 3))
  }

  func testRebuildQueueCollapsesConcurrentRequests() {
    var store = PreparedModelStore()
    XCTAssertTrue(store.beginRebuild(pid: 11))
    XCTAssertFalse(store.beginRebuild(pid: 11))
    XCTAssertFalse(store.beginRebuild(pid: 11))
    XCTAssertTrue(store.isRebuilding(pid: 11))
    XCTAssertTrue(store.finishRebuild(pid: 11))
    XCTAssertFalse(store.isRebuilding(pid: 11))
    XCTAssertTrue(store.beginRebuild(pid: 11))
    XCTAssertFalse(store.finishRebuild(pid: 11))
  }

  private func model(
    pid: pid_t,
    token: UInt64,
    revision: UInt64,
    computedAt: DispatchTime,
    targets: [JumpTarget],
    occluded: Bool = false
  ) -> PreparedModel {
    let hints = targets.map { AssignedHint(target: $0, label: "a") }
    return PreparedModel(
      pid: pid,
      targets: targets,
      hints: hints,
      computedAt: computedAt,
      dirtyToken: token,
      configRevision: revision,
      fingerprint: AppMonitor.targetsFingerprint(targets),
      freshnessMs: AppMonitor.modelFreshnessMs,
      occluded: occluded)
  }

  private func target(
    id: String, frame: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10)
  ) -> JumpTarget {
    JumpTarget(id: id, frame: frame, pid: 42, providerID: "test")
  }

  func testDegenerateDiscoveryIsEmptyOrACollapseOfALargeApp() {
    XCTAssertTrue(AppMonitor.discoveryLooksDegenerate(targets: 0, lastHealthy: nil))
    XCTAssertTrue(AppMonitor.discoveryLooksDegenerate(targets: 0, lastHealthy: 3))
    // The logged Firefox collapse: 1 target where the same view had 98.
    XCTAssertTrue(AppMonitor.discoveryLooksDegenerate(targets: 1, lastHealthy: 98))
    XCTAssertFalse(AppMonitor.discoveryLooksDegenerate(targets: 12, lastHealthy: 98))
    // A small app is never judged by ratio, and a first walk has nothing to compare.
    XCTAssertFalse(AppMonitor.discoveryLooksDegenerate(targets: 1, lastHealthy: 12))
    XCTAssertFalse(AppMonitor.discoveryLooksDegenerate(targets: 1, lastHealthy: nil))
  }
}
