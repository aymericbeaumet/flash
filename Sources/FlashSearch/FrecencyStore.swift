import Foundation
import GRDB

/// Persistent decayed-open accumulator. One row per stable item key.
/// Reads are O(1) (single keyed SELECT); writes are O(1) (single UPSERT).
/// The boost the live ranker adds to a match is a pure function of the
/// stored score so it never crosses match-quality tiers in the existing
/// scorer.
public final class FrecencyStore {
  /// Tunable knobs. Half-life is 14d by default — recency dominates over
  /// raw frequency. `maxBoost` is deliberately below the smallest
  /// adjacent scoring-tier gap in `CandidateFinder.fieldScoreNormalized`
  /// (700) so frecency reorders **within** match-quality tiers and never
  /// crosses one.
  public struct Configuration: Sendable {
    public var halfLifeDays: Double
    public var maxBoost: Int
    public var coefficient: Double

    public init(
      halfLifeDays: Double = 14.0,
      maxBoost: Int = 600,
      coefficient: Double = 220.0
    ) {
      self.halfLifeDays = halfLifeDays
      self.maxBoost = maxBoost
      self.coefficient = coefficient
    }

    /// Per-second decay rate.
    var lambda: Double {
      let seconds = halfLifeDays * 86_400.0
      return seconds > 0 ? log(2.0) / seconds : 0
    }
  }

  private let store: SearchStore
  private let queue: DispatchQueue
  public let configuration: Configuration

  public init(store: SearchStore, configuration: Configuration = Configuration()) {
    self.store = store
    self.queue = DispatchQueue(label: "flash.search.frecency", qos: .utility)
    self.configuration = configuration
  }

  /// Record one open of `itemKey`. Decayed score becomes `decayed + 1`
  /// and `open_count` increments. Async (off the caller's thread) — the
  /// keystroke path never blocks on this.
  public func recordOpen(itemKey: String) {
    let now = Int64(Date().timeIntervalSince1970)
    let lambda = configuration.lambda
    queue.async { [weak self] in
      guard let self else { return }
      do {
        try self.store.pool.write { db in
          let existing = try Row.fetchOne(
            db, sql: "SELECT score, last_at FROM frecency WHERE item_key = ?",
            arguments: [itemKey])
          let newScore: Double
          let newCount: Int
          if let existing {
            let prevScore: Double = existing["score"]
            let prevAt: Int64 = existing["last_at"]
            let dt = max(0, Double(now - prevAt))
            let decayed = prevScore * exp(-lambda * dt)
            newScore = decayed + 1.0
            newCount = (try? Int.fetchOne(
              db, sql: "SELECT open_count FROM frecency WHERE item_key = ?",
              arguments: [itemKey])) ?? 0
            try db.execute(sql: """
              UPDATE frecency SET score = ?, last_at = ?, open_count = ?
              WHERE item_key = ?
              """, arguments: [newScore, now, newCount + 1, itemKey])
          } else {
            newScore = 1.0
            try db.execute(sql: """
              INSERT INTO frecency(item_key, score, last_at, open_count)
              VALUES (?, ?, ?, 1)
              """, arguments: [itemKey, newScore, now])
          }
        }
      } catch {
        self.store.log.warn(
          "frecency record failed",
          fields: ["key": itemKey, "error": "\(error)"])
      }
    }
  }

  /// Return a fully-decayed snapshot keyed by `itemKey`. Used by the
  /// live ranker to look up an O(1) boost without a DB round-trip per
  /// keystroke. `topN` caps the row count so a long-running install
  /// can't bloat the dict.
  public func snapshotBoosts(topN: Int = 4096) throws -> [String: Int] {
    let lambda = configuration.lambda
    let coefficient = configuration.coefficient
    let maxBoost = configuration.maxBoost
    let now = Int64(Date().timeIntervalSince1970)
    return try store.pool.read { db in
      let rows = try Row.fetchAll(
        db, sql: """
        SELECT item_key, score, last_at FROM frecency
        ORDER BY score DESC, last_at DESC LIMIT ?
        """, arguments: [topN])
      var out: [String: Int] = [:]
      out.reserveCapacity(rows.count)
      for row in rows {
        let key: String = row["item_key"]
        let score: Double = row["score"]
        let last: Int64 = row["last_at"]
        let dt = max(0, Double(now - last))
        let decayed = score * exp(-lambda * dt)
        out[key] = Self.boost(decayed: decayed, coefficient: coefficient, max: maxBoost)
      }
      return out
    }
  }

  /// Decayed-score → integer boost. Capped so a heavily-used item can
  /// never out-rank a stronger field-quality tier in the live ranker.
  public static func boost(
    decayed score: Double,
    coefficient: Double = 220.0,
    max maxBoost: Int = 600
  ) -> Int {
    if score <= 0 { return 0 }
    let raw = coefficient * log(1.0 + score)
    return min(maxBoost, Int(raw))
  }

  /// Block until every queued `recordOpen` has committed. Tests and the
  /// shutdown path want this; the hot path does not.
  public func drain() {
    let group = DispatchGroup()
    group.enter()
    queue.async { group.leave() }
    group.wait()
  }

  /// Drop a stale entry — used by callers that learn a key is no longer
  /// resolvable (e.g. uninstalled app).
  public func forget(itemKey: String) {
    queue.async { [weak self] in
      try? self?.store.pool.write { db in
        try db.execute(sql: "DELETE FROM frecency WHERE item_key = ?",
                       arguments: [itemKey])
      }
    }
  }
}

/// Stable item-key derivation. Mirrors the host's `appMovementIdentity`
/// so the same row produced by the in-memory pool and an FTS hit
/// resolves to the same frecency entry.
public enum FrecencyKey {
  /// Bundle id is the most durable handle for an app candidate.
  public static func app(bundleID: String) -> String { "app.bundle:\(bundleID)" }
  /// Path is the fallback when the bundle id is missing (e.g.
  /// `flash-native-fixture.app` — unsigned dev builds).
  public static func appPath(_ path: String) -> String { "app.path:\(path)" }
  /// Canonicalized URL for browser-tab / web-history rows. Callers
  /// should already have lower-cased the host and stripped the trailing
  /// `/` of paths so two captures of the same logical page match.
  public static func url(_ canonical: String) -> String { "url:\(canonical)" }
  /// Catch-all for plugin-indexed docs.
  public static func document(collection: String, docKey: String) -> String {
    "doc:\(collection):\(docKey)"
  }
  /// Command-line completion entries (`:flashlight`, `:help`, …). Boost
  /// surfaces frequently-typed commands at the top of the empty `:`
  /// prompt without changing what shows once the user starts typing a
  /// query (fuzzy score dominates from the first character).
  public static func command(label: String) -> String {
    "command:\(label.lowercased())"
  }
}
