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
        freshnessMs: 1500))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 8,
        configRevision: 3,
        now: now,
        freshnessMs: 1500))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 4,
        now: now,
        freshnessMs: 1500))
    XCTAssertNil(
      store.lookup(
        pid: 42,
        dirtyToken: 7,
        configRevision: 3,
        now: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 1_600_000_000),
        freshnessMs: 1500))
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
      freshnessMs: 1500)
    XCTAssertNotNil(found)
    XCTAssertTrue(found?.isEmptyReady ?? false)
    XCTAssertNil(
      store.lookup(
        pid: 8,
        dirtyToken: 1,
        configRevision: 1,
        now: now,
        freshnessMs: 1500))
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
    targets: [JumpTarget]
  ) -> PreparedModel {
    let hints = targets.map { AssignedHint(target: $0, label: "a") }
    return PreparedModel(
      pid: pid,
      bundleID: "test.bundle",
      targets: targets,
      hints: hints,
      computedAt: computedAt,
      dirtyToken: token,
      configRevision: revision)
  }

  private func target(id: String) -> JumpTarget {
    JumpTarget(
      id: id,
      frame: CGRect(x: 0, y: 0, width: 10, height: 10),
      pid: 42,
      providerID: "test")
  }
}
