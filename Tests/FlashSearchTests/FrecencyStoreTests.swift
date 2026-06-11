import XCTest
import GRDB
@testable import FlashSearch

final class FrecencyStoreTests: XCTestCase {
  private func makeStore() throws -> (SearchStore, FrecencyStore) {
    let store = try SearchStore.inMemory()
    return (store, FrecencyStore(store: store))
  }

  func testFreshEntryGetsScoreOne() throws {
    let (store, freq) = try makeStore()
    freq.recordOpen(itemKey: "app.bundle:com.apple.Safari")
    // The record path is async via the frecency queue; wait for it to
    // drain by issuing a barrier-style sync write to the same queue.
    drainQueue(freq)
    let row = try store.pool.read { db -> Row? in
      try Row.fetchOne(
        db, sql: "SELECT score, open_count FROM frecency WHERE item_key = ?",
        arguments: ["app.bundle:com.apple.Safari"])
    }
    XCTAssertNotNil(row)
    XCTAssertEqual(row!["score"] as Double, 1.0, accuracy: 0.001)
    XCTAssertEqual(row!["open_count"] as Int, 1)
  }

  func testRepeatedOpensAccumulate() throws {
    let (store, freq) = try makeStore()
    for _ in 0..<3 {
      freq.recordOpen(itemKey: "url:https://x.example/")
    }
    drainQueue(freq)
    let row = try store.pool.read { db -> Row? in
      try Row.fetchOne(
        db, sql: "SELECT score, open_count FROM frecency WHERE item_key = ?",
        arguments: ["url:https://x.example/"])
    }
    XCTAssertEqual(row!["open_count"] as Int, 3)
    // Each open adds 1 (after decay); within a few ms the decay is
    // negligible, so the score should be ~3.0.
    XCTAssertGreaterThan(row!["score"] as Double, 2.9)
  }

  func testBoostCapAndMonotone() {
    XCTAssertEqual(FrecencyStore.boost(decayed: 0), 0)
    XCTAssertLessThan(
      FrecencyStore.boost(decayed: 1),
      FrecencyStore.boost(decayed: 10))
    XCTAssertEqual(FrecencyStore.boost(decayed: 1e9), 600)
  }

  func testItemKeyHelpers() {
    XCTAssertEqual(FrecencyKey.app(bundleID: "com.apple.Safari"), "app.bundle:com.apple.Safari")
    XCTAssertEqual(FrecencyKey.url("https://x.example/"), "url:https://x.example/")
    XCTAssertEqual(FrecencyKey.document(collection: "c", docKey: "k"), "doc:c:k")
  }

  func testSnapshotIncludesRecentEntries() throws {
    let (_, freq) = try makeStore()
    freq.recordOpen(itemKey: "app.bundle:a")
    freq.recordOpen(itemKey: "app.bundle:b")
    drainQueue(freq)
    let snapshot = try freq.snapshotBoosts()
    XCTAssertNotNil(snapshot["app.bundle:a"])
    XCTAssertNotNil(snapshot["app.bundle:b"])
  }

  private func drainQueue(_ freq: FrecencyStore) {
    freq.drain()
  }
}
