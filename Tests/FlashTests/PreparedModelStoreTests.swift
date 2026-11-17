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
        now: now,
        occlusion: Self.walkedOcclusion))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 8,
        configRevision: 3,
        now: now,
        occlusion: Self.walkedOcclusion))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 4,
        now: now,
        occlusion: Self.walkedOcclusion))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 3,
        now: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 1_600_000_000),
        occlusion: Self.walkedOcclusion))
  }

  /// A model is served only under the cover its walk saw. Another app's
  /// window moving over or off the window since is a miss, and a model whose
  /// walk had no window list is never served.
  func testLookupRequiresTheWalksVisibleRegion() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    store.store(model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "a")]))
    XCTAssertNotNil(
      store.lookup(
        pid: 42, dirtyToken: 7, configRevision: 3, now: now, occlusion: Self.walkedOcclusion))
    let covered = WindowSnapshot.OcclusionSignature(
      frame: CGRect(x: 0, y: 0, width: 100, height: 100),
      fragments: [CGRect(x: 0, y: 0, width: 100, height: 50)])
    XCTAssertNil(
      store.lookup(pid: 42, dirtyToken: 7, configRevision: 3, now: now, occlusion: covered),
      "a window partly covered since the walk is walked again")
    XCTAssertNil(
      store.lookup(pid: 42, dirtyToken: 7, configRevision: 3, now: now, occlusion: nil),
      "no window list now is a miss")
    store.store(
      model(
        pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "a")],
        occlusion: nil))
    XCTAssertNil(
      store.lookup(
        pid: 42, dirtyToken: 7, configRevision: 3, now: now, occlusion: Self.walkedOcclusion),
      "a walk that had no window list is never served")
  }

  func testLookupHonoursTheModelsOwnFreshnessCeiling() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    var extended = model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [])
    extended.freshnessMs = 6_000
    store.store(extended)
    let later = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 5_000_000_000)
    XCTAssertNotNil(
      store.lookup(
        pid: 42, dirtyToken: 7, configRevision: 3, now: later,
        occlusion: Self.walkedOcclusion))
    let tooLate = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 6_100_000_000)
    XCTAssertNil(
      store.lookup(
        pid: 42, dirtyToken: 7, configRevision: 3, now: tooLate,
        occlusion: Self.walkedOcclusion))
  }

  /// Only a maintenance walk that reproduces the model unchanged — same
  /// dirty token, configuration revision and target digest — counts as a
  /// static app; the interval it grows is `nextModelIntervalMs`'s.
  func testFreshnessDoublesOnlyForUnchangedMaintenanceWalks() {
    let now = DispatchTime(uptimeNanoseconds: 1_000)
    let previous = model(
      pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "one")])
    let same = model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "one")])
    XCTAssertTrue(AppMonitor.modelReproducedUnchanged(previous: previous, built: same))
    let moved = model(
      pid: 42, token: 7, revision: 3, computedAt: now,
      targets: [target(id: "one", frame: CGRect(x: 5, y: 5, width: 10, height: 10))])
    XCTAssertFalse(AppMonitor.modelReproducedUnchanged(previous: previous, built: moved))
    XCTAssertFalse(
      AppMonitor.modelReproducedUnchanged(
        previous: previous,
        built: model(pid: 42, token: 8, revision: 3, computedAt: now, targets: [target(id: "one")])
      ))
    XCTAssertFalse(AppMonitor.modelReproducedUnchanged(previous: nil, built: same))

    let floor = AppMonitor.modelFreshnessMs
    XCTAssertEqual(
      AppMonitor.nextModelIntervalMs(
        current: floor, elapsedMs: 10, unchanged: true, degenerate: false),
      floor * 2)
    XCTAssertEqual(
      AppMonitor.nextModelIntervalMs(
        current: AppMonitor.modelFreshnessMaxMs, elapsedMs: 10, unchanged: true,
        degenerate: false),
      AppMonitor.modelFreshnessMaxMs)
    XCTAssertEqual(
      AppMonitor.nextModelIntervalMs(
        current: floor, elapsedMs: 10, unchanged: false, degenerate: false),
      floor)
    // A changed model walked cheaply shrinks a grown interval; a slow walk
    // grows it even when the model changed.
    XCTAssertEqual(
      AppMonitor.nextModelIntervalMs(
        current: 6000, elapsedMs: 10, unchanged: false, degenerate: false),
      floor)
    XCTAssertEqual(
      AppMonitor.nextModelIntervalMs(
        current: floor, elapsedMs: 200, unchanged: false, degenerate: false),
      floor * 2)
  }

  /// The store says why it has nothing to serve, so a miss can be told apart
  /// in `[latency] hints_visible`: never walked, discarded by a focus change
  /// or an AX event, a configuration change, a window-list change, or age.
  func testTheStoreRemembersWhyItHasNoModel() {
    let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
    var store = PreparedModelStore()
    func miss(
      token: UInt64 = 7, revision: UInt64 = 3, at: DispatchTime = now,
      occlusion: WindowSnapshot.OcclusionSignature? = PreparedModelStoreTests.walkedOcclusion
    ) -> PreparedModelMiss? {
      store.resolve(
        pid: 42, dirtyToken: token, configRevision: revision, now: at, occlusion: occlusion
      ).miss
    }
    XCTAssertEqual(miss(), .absent, "never walked")
    store.store(model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "a")]))
    XCTAssertNil(miss())
    XCTAssertEqual(miss(token: 8), .invalidated)
    XCTAssertEqual(miss(revision: 4), .config)
    XCTAssertEqual(miss(occlusion: nil), .occluded)
    XCTAssertEqual(
      miss(at: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 1_600_000_000)), .expired)
    store.discardModel(pid: 42, because: .focus)
    XCTAssertEqual(miss(), .focus)
    store.discardModel(pid: 42, because: .invalidated)
    XCTAssertEqual(miss(), .invalidated)
    store.store(
      model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [], occluded: true))
    XCTAssertEqual(miss(), .occluded, "an occluded walk evicts the model and says so")
    store.store(model(pid: 42, token: 7, revision: 3, computedAt: now, targets: [target(id: "a")]))
    XCTAssertNil(miss())
    store.remove(pid: 42)
    XCTAssertEqual(miss(), .absent)
  }

  func testEmptyReadyModelIsDistinctFromMissingModel() {
    let now = DispatchTime(uptimeNanoseconds: 1_000)
    var store = PreparedModelStore()
    store.store(model(pid: 7, token: 1, revision: 1, computedAt: now, targets: []))

    let found = store.lookup(
      pid: 7,
      dirtyToken: 1,
      configRevision: 1,
      now: now,
      occlusion: Self.walkedOcclusion)
    XCTAssertNotNil(found)
    XCTAssertTrue(found?.isEmptyReady ?? false)
    XCTAssertNil(
      store.lookup(
        pid: 8,
        dirtyToken: 1,
        configRevision: 1,
        now: now,
        occlusion: Self.walkedOcclusion))
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
    XCTAssertNil(
      store.lookup(
        pid: 42, dirtyToken: 7, configRevision: 3, now: now,
        occlusion: Self.walkedOcclusion))
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

  func testDiscardModelKeepsRebuildGuard() throws {
    var store = PreparedModelStore()
    let ticket = try XCTUnwrap(store.beginRebuild(pid: 3))
    store.discardModel(pid: 3, because: .invalidated)
    XCTAssertNil(store.beginRebuild(pid: 3))
    XCTAssertEqual(store.finishRebuild(ticket), true)
  }

  func testRebuildQueueCollapsesConcurrentRequests() throws {
    var store = PreparedModelStore()
    let ticket = try XCTUnwrap(store.beginRebuild(pid: 11))
    XCTAssertNil(store.beginRebuild(pid: 11))
    XCTAssertNil(store.beginRebuild(pid: 11))
    XCTAssertTrue(store.isRebuilding(pid: 11))
    XCTAssertEqual(store.finishRebuild(ticket), true)
    XCTAssertFalse(store.isRebuilding(pid: 11))
    let next = try XCTUnwrap(store.beginRebuild(pid: 11))
    XCTAssertEqual(store.finishRebuild(next), false)
  }

  func testCancelledRebuildCannotFinishItsReplacement() throws {
    var store = PreparedModelStore()
    let cancelled = try XCTUnwrap(store.beginRebuild(pid: 11))
    store.removeAll()
    let replacement = try XCTUnwrap(store.beginRebuild(pid: 11))
    XCTAssertNil(store.beginRebuild(pid: 11))

    XCTAssertNil(store.finishRebuild(cancelled), "the cancelled completion owns no queued work")
    XCTAssertTrue(store.isRebuilding(pid: 11), "the replacement must keep its rebuild guard")
    XCTAssertEqual(
      store.finishRebuild(replacement), true, "the replacement owns its queued refresh")
  }

  func testRemovedAppRevokesItsWalkWithoutRevokingOtherApps() throws {
    var store = PreparedModelStore()
    let removed = try XCTUnwrap(store.beginRebuild(pid: 11))
    let other = try XCTUnwrap(store.beginRebuild(pid: 12))
    store.remove(pid: 11)
    let replacement = try XCTUnwrap(store.beginRebuild(pid: 11))

    XCTAssertNil(store.finishRebuild(removed))
    XCTAssertTrue(store.isRebuilding(pid: 11))
    XCTAssertEqual(store.finishRebuild(other), false)
    XCTAssertEqual(store.finishRebuild(replacement), false)
    XCTAssertNil(store.finishRebuild(replacement), "a completion may consume its ticket only once")
  }

  private func model(
    pid: pid_t,
    token: UInt64,
    revision: UInt64,
    computedAt: DispatchTime,
    targets: [JumpTarget],
    occluded: Bool = false,
    occlusion: WindowSnapshot.OcclusionSignature? = PreparedModelStoreTests.walkedOcclusion
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
      occluded: occluded,
      occlusion: occlusion)
  }

  /// The cover a walk saw: the whole window visible.
  static let walkedOcclusion = WindowSnapshot.OcclusionSignature(
    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
    fragments: [CGRect(x: 0, y: 0, width: 100, height: 100)])

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
