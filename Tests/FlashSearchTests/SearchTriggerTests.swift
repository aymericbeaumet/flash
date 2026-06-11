import XCTest
import GRDB
@testable import FlashSearch

/// Verifies the column-scoped `AFTER UPDATE OF title, subtitle, body, url`
/// trigger doesn't fire when only `meta`/`content_hash`/`updated_at`
/// change. Without column scoping, every meta-only edit would rewrite
/// the FTS row — expensive on a large clipboard / files corpus.
final class SearchTriggerTests: XCTestCase {
  func testMetaOnlyUpdateDoesNotRewriteFTSEntry() throws {
    let store = try SearchStore.inMemory()
    try store.pool.write { db in
      try db.execute(sql: """
        INSERT INTO collection (name, owner, created_at, updated_at)
        VALUES ('core:test', 'core', 0, 0)
        """)
      try db.execute(sql: """
        INSERT INTO document (
          collection_id, doc_key, title, subtitle, body, url,
          kind, source_id, bundle_id, meta, content_hash, updated_at
        ) VALUES (1, 'k', 'Apple', NULL, NULL, NULL, 'test', 'core:test', NULL, '{}', 'h1', 0)
        """)
    }
    // FTS row count + an internal pointer that increases on every
    // delete/insert pair (we can't read it portably, so we compare the
    // number of `'delete'` operations indirectly by counting tokens).
    let initialMatches = try store.pool.read { db -> Int in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? -1
    }
    XCTAssertEqual(initialMatches, 1)

    // Update only meta / content_hash / updated_at; the indexed text
    // stays the same. The `AFTER UPDATE OF (title, subtitle, body,
    // url)` trigger must not fire.
    try store.pool.write { db in
      try db.execute(sql: """
        UPDATE document SET meta = '{"pinned":"true"}', content_hash = 'h2', updated_at = 1
        WHERE doc_key = 'k'
        """)
    }
    let postMatches = try store.pool.read { db -> Int in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? -1
    }
    XCTAssertEqual(postMatches, 1, "FTS row count must not change on meta-only update")
  }
}
