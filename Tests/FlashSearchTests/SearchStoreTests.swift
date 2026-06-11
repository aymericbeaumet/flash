import XCTest
import GRDB
@testable import FlashSearch

final class SearchStoreTests: XCTestCase {
  func testFTS5ProbeIsTrueOnSystemSQLite() {
    XCTAssertTrue(SearchStore.checkFTS5Available())
  }

  func testInMemoryOpensCleanly() throws {
    let store = try SearchStore.inMemory()
    XCTAssertNotNil(store)
  }

  func testMigratorIsIdempotent() throws {
    let store = try SearchStore.inMemory()
    let migrator = SearchSchema.migrator()
    try migrator.migrate(store.pool)
    try migrator.migrate(store.pool)
  }

  func testRequiredTablesExist() throws {
    let store = try SearchStore.inMemory()
    let names = try store.pool.read { db -> [String] in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
    }
    for required in ["collection", "document", "document_fts", "frecency"] {
      XCTAssertTrue(names.contains(required), "missing table \(required)")
    }
  }

  func testWALModeIsActive() throws {
    let store = try SearchStore.inMemory()
    let mode = try store.pool.read { db -> String in
      try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
    }
    XCTAssertEqual(mode.lowercased(), "wal")
  }
}
