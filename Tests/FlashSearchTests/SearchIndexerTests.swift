import XCTest
import GRDB
@testable import FlashSearch

final class SearchIndexerTests: XCTestCase {
  private func makeIndexer() throws -> (SearchStore, SearchIndexer) {
    let store = try SearchStore.inMemory()
    return (store, SearchIndexer(store: store))
  }

  private func doc(_ key: String, _ title: String, kind: String = "test",
                   body: String? = nil, meta: [String: String] = [:]) -> SearchDocument
  {
    SearchDocument(
      docKey: key, title: title, kind: kind, sourceID: "core:test",
      body: body, meta: meta)
  }

  func testUpsertInserts() throws {
    let (store, indexer) = try makeIndexer()
    let written = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple"), doc("b", "Banana")])
    XCTAssertEqual(written, 2)
    let count = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document") ?? -1
    }
    XCTAssertEqual(count, 2)
  }

  func testUpsertHashGatedNoop() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    let before = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? 0
    }
    // Re-upsert with the same content. The conflict's WHERE clause must
    // skip the row, so the FTS trigger must not fire — `document_fts`'s
    // row count is unchanged. The "no fts rewrite" guarantee is also
    // verified by SearchTriggerTests for meta-only updates.
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    let after = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? 0
    }
    XCTAssertEqual(before, after)
  }

  func testUpdateRewritesFTSWhenTitleChanges() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Aardvark")])
    let appleHits = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? -1
    }
    let aardvarkHits = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'aardvark*'") ?? -1
    }
    XCTAssertEqual(appleHits, 0)
    XCTAssertEqual(aardvarkHits, 1)
  }

  func testDeleteRemovesRowAndFTS() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple"), doc("b", "Banana")])
    let removed = try indexer.deleteSync(
      collection: "core:test", owner: "core", docKeys: ["a"])
    XCTAssertEqual(removed, 1)
    let count = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document") ?? -1
    }
    XCTAssertEqual(count, 1)
    let appleHits = try store.pool.read { db -> Int in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM document_fts WHERE document_fts MATCH 'apple*'") ?? -1
    }
    XCTAssertEqual(appleHits, 0)
  }

  func testReplaceCollectionSweep() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple"), doc("b", "Banana"), doc("c", "Cherry")])
    _ = try indexer.replaceCollectionSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple"), doc("d", "Date")])
    let keys = try store.pool.read { db -> [String] in
      try String.fetchAll(db, sql: "SELECT doc_key FROM document ORDER BY doc_key")
    }
    XCTAssertEqual(keys, ["a", "d"])
  }

  func testCrossOwnerWriteIsRejected() throws {
    let (_, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    do {
      _ = try indexer.upsertSync(
        collection: "core:test", owner: "plugin:evil",
        documents: [doc("b", "Banana")])
      XCTFail("expected ownership error")
    } catch let err as SearchIndexerError {
      if case .collectionOwnedByOther = err { } else { XCTFail("\(err)") }
    }
  }

  func testHiddenCollectionStoredAndUpdatable() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "plugin:c:hidden", owner: "plugin:c",
      documents: [doc("a", "Apple")],
      hidden: true)
    let hiddenOnInsert = try store.pool.read { db -> Int64 in
      try Int64.fetchOne(
        db, sql: "SELECT hidden FROM collection WHERE name = 'plugin:c:hidden'") ?? -1
    }
    XCTAssertEqual(hiddenOnInsert, 1)

    // A subsequent write with `hidden: false` flips the collection
    // back to visible without dropping the docs — used when an owner
    // changes its mind about visibility between sessions.
    _ = try indexer.upsertSync(
      collection: "plugin:c:hidden", owner: "plugin:c",
      documents: [doc("b", "Banana")],
      hidden: false)
    let hiddenAfterFlip = try store.pool.read { db -> Int64 in
      try Int64.fetchOne(
        db, sql: "SELECT hidden FROM collection WHERE name = 'plugin:c:hidden'") ?? -1
    }
    XCTAssertEqual(hiddenAfterFlip, 0)
    let docCount = try store.pool.read { db -> Int in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM document JOIN collection ON document.collection_id = collection.id WHERE collection.name = 'plugin:c:hidden'") ?? -1
    }
    XCTAssertEqual(docCount, 2)
  }

  func testDefaultUpsertLeavesCollectionVisible() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    let hidden = try store.pool.read { db -> Int64 in
      try Int64.fetchOne(db, sql: "SELECT hidden FROM collection WHERE name = 'core:test'") ?? -1
    }
    XCTAssertEqual(hidden, 0)
  }

  func testDropCollectionsOwnedBy() throws {
    let (store, indexer) = try makeIndexer()
    _ = try indexer.upsertSync(
      collection: "plugin:p:a", owner: "plugin:p",
      documents: [doc("x", "X")])
    _ = try indexer.upsertSync(
      collection: "plugin:p:b", owner: "plugin:p",
      documents: [doc("y", "Y")])
    _ = try indexer.upsertSync(
      collection: "core:t", owner: "core",
      documents: [doc("z", "Z")])

    var result: Result<Int, Error>!
    let group = DispatchGroup()
    group.enter()
    indexer.dropCollections(ownedBy: "plugin:p") { r in
      result = r
      group.leave()
    }
    group.wait()
    XCTAssertEqual(try result.get(), 2)

    let names = try store.pool.read { db -> [String] in
      try String.fetchAll(db, sql: "SELECT name FROM collection ORDER BY name")
    }
    XCTAssertEqual(names, ["core:t"])
  }
}
