import Foundation
import GRDB

/// Write side of the search index. All public entry points hop onto a
/// serial utility queue and run a single batched transaction per call.
/// `DatabasePool` already serialises writes internally, but the queue
/// gives us back-pressure (one transaction at a time per caller),
/// ordering across calls, and a single place to hang the "writes since
/// optimize" counter.
public final class SearchIndexer {
  private let store: SearchStore
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var writesSinceOptimize: Int = 0
  private let optimizeIntervalWrites: Int

  public init(store: SearchStore, optimizeIntervalWrites: Int = 50_000) {
    self.store = store
    self.queue = DispatchQueue(label: "flash.search.indexer", qos: .utility)
    self.optimizeIntervalWrites = optimizeIntervalWrites
  }

  /// Insert-or-update `documents` into `collection`. Unchanged rows
  /// (same `content_hash`) are no-ops: the upsert's WHERE clause skips
  /// them, so the FTS update trigger doesn't fire. The completion runs
  /// off the indexer's queue (not main); callers that need main-thread
  /// delivery wrap their handler themselves — symmetric with the
  /// existing source/registry callbacks.
  public func upsert(
    collection: String,
    owner: String,
    documents: [SearchDocument],
    hidden: Bool = false,
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let count = try self.runUpsert(
          collection: collection, owner: owner, documents: documents, hidden: hidden)
        self.bumpOptimizeCounter(by: count)
        completion?(.success(count))
      } catch {
        self.store.log.warn(
          "upsert failed",
          fields: ["collection": collection, "error": "\(error)"])
        completion?(.failure(error))
      }
    }
  }

  /// Delete by `(collection, doc_key)`. Cascades to the FTS table via
  /// the delete trigger.
  public func delete(
    collection: String,
    owner: String,
    docKeys: [String],
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let count = try self.runDelete(
          collection: collection, owner: owner, docKeys: docKeys)
        completion?(.success(count))
      } catch {
        completion?(.failure(error))
      }
    }
  }

  /// Atomic snapshot replace: upsert the supplied documents, then
  /// sweep any prior `doc_key` in the collection that the snapshot
  /// didn't carry. Runs inside one transaction so a reader either sees
  /// the old set or the new set, never a torn mix.
  public func replaceCollection(
    collection: String,
    owner: String,
    documents: [SearchDocument],
    hidden: Bool = false,
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let count = try self.runReplace(
          collection: collection, owner: owner, documents: documents, hidden: hidden)
        self.bumpOptimizeCounter(by: count)
        completion?(.success(count))
      } catch {
        completion?(.failure(error))
      }
    }
  }

  /// Drop a single collection. Cascade clears `document` rows + their
  /// FTS entries via the existing delete trigger.
  public func dropCollection(
    collection: String,
    owner: String,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try self.store.pool.write { db in
          try Self.requireOwner(db, collection: collection, owner: owner)
          try db.execute(sql: "DELETE FROM collection WHERE name = ?", arguments: [collection])
        }
        completion?(.success(()))
      } catch {
        completion?(.failure(error))
      }
    }
  }

  /// Drop every collection a given owner registered. Used on plugin
  /// teardown so a re-installed plugin starts from a clean slate.
  public func dropCollections(
    ownedBy owner: String,
    completion: ((Result<Int, Error>) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let count = try self.store.pool.write { db -> Int in
          let names = try String.fetchAll(
            db, sql: "SELECT name FROM collection WHERE owner = ?",
            arguments: [owner])
          for name in names {
            try db.execute(sql: "DELETE FROM collection WHERE name = ?", arguments: [name])
          }
          return names.count
        }
        completion?(.success(count))
      } catch {
        completion?(.failure(error))
      }
    }
  }

  /// Synchronous variant used by tests/services that want the call to
  /// complete before they continue. Runs on the caller's thread (it
  /// blocks the indexer's queue with a barrier so existing async work
  /// drains first).
  public func upsertSync(
    collection: String, owner: String, documents: [SearchDocument], hidden: Bool = false
  ) throws -> Int {
    var result: Result<Int, Error>!
    let group = DispatchGroup()
    group.enter()
    upsert(collection: collection, owner: owner, documents: documents, hidden: hidden) { r in
      result = r
      group.leave()
    }
    group.wait()
    return try result.get()
  }

  public func replaceCollectionSync(
    collection: String, owner: String, documents: [SearchDocument], hidden: Bool = false
  ) throws -> Int {
    var result: Result<Int, Error>!
    let group = DispatchGroup()
    group.enter()
    replaceCollection(
      collection: collection, owner: owner, documents: documents, hidden: hidden
    ) { r in
      result = r
      group.leave()
    }
    group.wait()
    return try result.get()
  }

  public func deleteSync(
    collection: String, owner: String, docKeys: [String]
  ) throws -> Int {
    var result: Result<Int, Error>!
    let group = DispatchGroup()
    group.enter()
    delete(collection: collection, owner: owner, docKeys: docKeys) { r in
      result = r
      group.leave()
    }
    group.wait()
    return try result.get()
  }

  // MARK: - Transaction bodies

  private func runUpsert(
    collection: String, owner: String, documents: [SearchDocument], hidden: Bool
  ) throws -> Int {
    guard !documents.isEmpty else { return 0 }
    return try store.pool.write { db in
      let collectionID = try Self.ensureCollection(
        db, name: collection, owner: owner, hidden: hidden)
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      var total = 0
      // ~500/transaction matches the plan's target throughput. Pool
      // size is small enough that a `BEGIN/COMMIT` per chunk is cheap
      // and bounds the WAL growth per write.
      for chunk in stride(from: 0, to: documents.count, by: 500) {
        let upper = min(chunk + 500, documents.count)
        for index in chunk..<upper {
          let doc = documents[index]
          try Self.upsertOne(
            db, doc, collectionID: collectionID, now: now)
          total += 1
        }
        try db.execute(sql: """
          UPDATE collection SET updated_at = ? WHERE id = ?
          """, arguments: [now, collectionID])
      }
      return total
    }
  }

  private func runDelete(
    collection: String, owner: String, docKeys: [String]
  ) throws -> Int {
    guard !docKeys.isEmpty else { return 0 }
    return try store.pool.write { db -> Int in
      try Self.requireOwner(db, collection: collection, owner: owner)
      guard let collectionID = try Self.findCollectionID(db, name: collection) else {
        return 0
      }
      var total = 0
      for chunk in stride(from: 0, to: docKeys.count, by: 500) {
        let upper = min(chunk + 500, docKeys.count)
        for index in chunk..<upper {
          try db.execute(sql: """
            DELETE FROM document WHERE collection_id = ? AND doc_key = ?
            """, arguments: [collectionID, docKeys[index]])
          total += db.changesCount
        }
      }
      return total
    }
  }

  private func runReplace(
    collection: String, owner: String, documents: [SearchDocument], hidden: Bool
  ) throws -> Int {
    return try store.pool.write { db in
      let collectionID = try Self.ensureCollection(
        db, name: collection, owner: owner, hidden: hidden)
      let now = Int64(Date().timeIntervalSince1970 * 1000)
      // TEMP table sweep — avoids a `last_seen_at` column we'd
      // otherwise have to write on every row, every refresh.
      try db.execute(sql: "CREATE TEMP TABLE _seen_keys (doc_key TEXT PRIMARY KEY)")
      defer { try? db.execute(sql: "DROP TABLE IF EXISTS _seen_keys") }
      for doc in documents {
        try db.execute(sql: "INSERT OR IGNORE INTO _seen_keys(doc_key) VALUES (?)",
                       arguments: [doc.docKey])
        try Self.upsertOne(db, doc, collectionID: collectionID, now: now)
      }
      try db.execute(sql: """
        DELETE FROM document
        WHERE collection_id = ?
          AND doc_key NOT IN (SELECT doc_key FROM _seen_keys)
        """, arguments: [collectionID])
      try db.execute(sql: """
        UPDATE collection SET updated_at = ? WHERE id = ?
        """, arguments: [now, collectionID])
      return documents.count
    }
  }

  // MARK: - Helpers

  private static func upsertOne(
    _ db: Database,
    _ doc: SearchDocument,
    collectionID: Int64,
    now: Int64
  ) throws {
    let metaJSON: String?
    if doc.meta.isEmpty {
      metaJSON = nil
    } else {
      let data = try JSONSerialization.data(withJSONObject: doc.meta, options: [.sortedKeys])
      metaJSON = String(data: data, encoding: .utf8)
    }
    try db.execute(sql: """
      INSERT INTO document (
        collection_id, doc_key, title, subtitle, body, url,
        kind, source_id, bundle_id, meta, content_hash, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(collection_id, doc_key) DO UPDATE SET
        title = excluded.title,
        subtitle = excluded.subtitle,
        body = excluded.body,
        url = excluded.url,
        kind = excluded.kind,
        source_id = excluded.source_id,
        bundle_id = excluded.bundle_id,
        meta = excluded.meta,
        content_hash = excluded.content_hash,
        updated_at = excluded.updated_at
      WHERE content_hash <> excluded.content_hash;
      """, arguments: [
        collectionID, doc.docKey,
        doc.title, doc.subtitle, doc.body, doc.url,
        doc.kind, doc.sourceID, doc.bundleID, metaJSON,
        doc.contentHash, now,
      ])
  }

  private static func ensureCollection(
    _ db: Database, name: String, owner: String, hidden: Bool
  ) throws -> Int64 {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let hiddenValue: Int = hidden ? 1 : 0
    try db.execute(sql: """
      INSERT INTO collection (name, owner, created_at, updated_at, hidden)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(name) DO NOTHING
      """, arguments: [name, owner, now, now, hiddenValue])
    if let row = try Row.fetchOne(
      db, sql: "SELECT id, owner, hidden FROM collection WHERE name = ?",
      arguments: [name]
    ) {
      let existingOwner: String = row["owner"]
      if existingOwner != owner {
        throw SearchIndexerError.collectionOwnedByOther(
          collection: name, expected: owner, actual: existingOwner)
      }
      // The owner can flip visibility on a subsequent write — clipboard
      // upgrades pre-v2 rows by re-asserting `hidden = true` on its
      // next replace. The reverse is allowed too (a plugin can opt back
      // into the default flashlight pool) without dropping the
      // collection.
      let existingHidden: Int64 = row["hidden"] ?? 0
      if existingHidden != Int64(hiddenValue) {
        try db.execute(sql: """
          UPDATE collection SET hidden = ?, updated_at = ? WHERE id = ?
          """, arguments: [hiddenValue, now, row["id"] as Int64])
      }
      return row["id"] as Int64
    }
    throw SearchIndexerError.collectionMissing(name)
  }

  private static func findCollectionID(_ db: Database, name: String) throws -> Int64? {
    if let row = try Row.fetchOne(
      db, sql: "SELECT id FROM collection WHERE name = ?", arguments: [name]
    ) {
      return row["id"] as Int64
    }
    return nil
  }

  /// Refuse an operation on `collection` from anyone other than its
  /// registered owner. Drop is the only place we surface this — upsert
  /// uses `ensureCollection`, which does the same check while it
  /// inserts the row.
  private static func requireOwner(_ db: Database, collection: String, owner: String) throws {
    if let row = try Row.fetchOne(
      db, sql: "SELECT owner FROM collection WHERE name = ?", arguments: [collection]
    ) {
      let existingOwner: String = row["owner"]
      if existingOwner != owner {
        throw SearchIndexerError.collectionOwnedByOther(
          collection: collection, expected: owner, actual: existingOwner)
      }
    }
  }

  private func bumpOptimizeCounter(by writes: Int) {
    guard writes > 0 else { return }
    lock.lock()
    writesSinceOptimize += writes
    let due = writesSinceOptimize >= optimizeIntervalWrites
    if due { writesSinceOptimize = 0 }
    lock.unlock()
    if due {
      // Optimize is a write transaction itself; run it asynchronously
      // so the indexer queue can continue accepting work in the
      // meantime.
      DispatchQueue.global(qos: .utility).async { [store] in
        store.optimize()
      }
    }
  }
}

public enum SearchIndexerError: Error, CustomStringConvertible {
  case collectionOwnedByOther(collection: String, expected: String, actual: String)
  case collectionMissing(String)

  public var description: String {
    switch self {
    case let .collectionOwnedByOther(collection, expected, actual):
      return "collection \"\(collection)\" is owned by \"\(actual)\", refused write from \"\(expected)\""
    case .collectionMissing(let name):
      return "collection \"\(name)\" not found"
    }
  }
}
