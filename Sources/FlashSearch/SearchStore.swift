import Foundation
import GRDB

/// Errors callers can surface to the user.
public enum SearchStoreError: Error, CustomStringConvertible {
  case fts5Unavailable
  case openFailed(String)
  case migrationFailed(String)

  public var description: String {
    switch self {
    case .fts5Unavailable:
      return "SQLite FTS5 extension is not available in the linked sqlite3"
    case .openFailed(let detail):
      return "failed to open search database: \(detail)"
    case .migrationFailed(let detail):
      return "failed to migrate search database: \(detail)"
    }
  }
}

/// Connection-pool wrapper. Owns the `DatabasePool` plus its
/// configuration (pragmas / mmap / cache) and applies the migrator.
/// Thread-safe by virtue of `DatabasePool`'s own concurrency model
/// (multiple readers + one writer, all backed by WAL).
public final class SearchStore {
  /// Tunable knobs. Defaults match the plan: 128 MB mmap, 64 MB page
  /// cache, WAL `synchronous=NORMAL`, 5s busy timeout. The retrieval
  /// limit is enforced by the query engine, not by SQLite, but lives
  /// here because it's the connection-shaped policy.
  public struct Configuration {
    public var mmapSize: Int64
    public var cacheSizeKB: Int
    public var busyTimeoutSeconds: Double
    public var retrievalLimit: Int

    public init(
      mmapSize: Int64 = 128 * 1024 * 1024,
      cacheSizeKB: Int = 64 * 1024,
      busyTimeoutSeconds: Double = 5.0,
      retrievalLimit: Int = 512
    ) {
      self.mmapSize = mmapSize
      self.cacheSizeKB = cacheSizeKB
      self.busyTimeoutSeconds = busyTimeoutSeconds
      self.retrievalLimit = retrievalLimit
    }
  }

  public let url: URL
  public let configuration: Configuration
  let pool: DatabasePool
  let log: SearchLogging

  public init(
    url: URL,
    configuration: Configuration = Configuration(),
    log: SearchLogging = SearchSilentLog()
  ) throws {
    self.url = url
    self.configuration = configuration
    self.log = log
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if !Self.checkFTS5Available() {
      throw SearchStoreError.fts5Unavailable
    }
    do {
      self.pool = try Self.makePool(url: url, configuration: configuration)
    } catch {
      throw SearchStoreError.openFailed("\(error)")
    }
    do {
      try SearchSchema.migrator().migrate(pool)
    } catch {
      throw SearchStoreError.migrationFailed("\(error)")
    }
    log.info("FlashSearch opened", fields: ["path": url.path])
  }

  /// Probe — succeeds when SQLite can create an FTS5 virtual table.
  /// FTS5 has shipped in Apple's bundled sqlite3 for years; this is a
  /// belt-and-braces check so a stripped runtime degrades to "search
  /// disabled" instead of hard-crashing at first write.
  public static func checkFTS5Available() -> Bool {
    do {
      let q = try DatabaseQueue()
      try q.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE __fts5_probe USING fts5(x)")
      }
      return true
    } catch {
      return false
    }
  }

  /// Best-effort `wal_checkpoint(TRUNCATE)` on shutdown so the WAL file
  /// doesn't grow unbounded between sessions.
  public func checkpointTruncate() {
    do {
      try pool.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
      }
    } catch {
      log.warn("wal_checkpoint(TRUNCATE) failed", fields: ["error": "\(error)"])
    }
  }

  /// Run FTS5 `optimize` plus a fresh ANALYZE. Callers throttle this by
  /// write-count; the indexer triggers it once the running upsert total
  /// crosses `optimizeIntervalWrites`.
  public func optimize() {
    do {
      try pool.write { db in
        try db.execute(sql: "INSERT INTO document_fts(document_fts) VALUES('optimize')")
        try db.execute(sql: "ANALYZE")
      }
    } catch {
      log.warn("FTS optimize failed", fields: ["error": "\(error)"])
    }
  }

  /// Hand a fresh in-memory store to tests. Skips FileManager + path
  /// configuration; reuses the production migrator and pragmas.
  public static func inMemory(
    configuration: Configuration = Configuration(),
    log: SearchLogging = SearchSilentLog()
  ) throws -> SearchStore {
    return try SearchStore(
      url: URL(fileURLWithPath: "/private/tmp/_flash_search_inmem_\(UUID().uuidString).db"),
      configuration: configuration, log: log)
  }

  private static func makePool(url: URL, configuration: Configuration) throws -> DatabasePool {
    var config = GRDB.Configuration()
    config.busyMode = .timeout(configuration.busyTimeoutSeconds)
    let mmap = configuration.mmapSize
    let cacheKB = configuration.cacheSizeKB
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA mmap_size = \(mmap)")
      // GRDB's `cache_size` syntax — negative numbers are KB, positive
      // numbers are pages. We want a stable byte budget regardless of
      // page size, so negative.
      try db.execute(sql: "PRAGMA cache_size = -\(cacheKB)")
    }
    return try DatabasePool(path: url.path, configuration: config)
  }
}
