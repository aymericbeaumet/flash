import Foundation

/// Flat-file frecency: one row per stable item key (`app.bundle:…`,
/// `url:…`, `command:…`). Persisted as JSON at
/// `~/Library/Application Support/Flash/frecency.json` so the boost
/// survives restarts. Reads are O(1) (in-memory dict, refreshed
/// async); writes coalesce on a background queue. Decay is
/// exponential with a configurable half-life; the integer boost the
/// ranker adds caps at `maxBoost` so a heavily-used item can't
/// out-rank a stronger match-quality tier in `CandidateFinder`.
final class FrecencyStore {
  struct Entry: Codable {
    var score: Double
    var lastAt: TimeInterval
    var openCount: Int
  }

  struct Configuration {
    /// Half-life of the decayed score in days. Recency dominates
    /// frequency; older opens fade out without the user having to
    /// curate the list. 14d matches the prior GRDB store.
    var halfLifeDays: Double = 14.0
    /// Cap on the integer boost added to the live ranker's score.
    /// Stays below the smallest adjacent scoring-tier gap in
    /// `CandidateFinder.fieldScoreNormalized` (700) so frecency
    /// reorders **within** match-quality tiers and never crosses one.
    var maxBoost: Int = 600
    /// Multiplier on `log(1 + decayedScore)` before the cap. Tuned
    /// so ~6 opens within the half-life saturates the boost.
    var coefficient: Double = 220.0
    /// Boost-snapshot cap. Once the persisted dict grows past this
    /// we trim the cheapest entries on load — frecency only matters
    /// for the user's hot set; the long tail rounds to zero.
    var maxEntries: Int = 4096

    /// Per-second decay rate derived from `halfLifeDays`.
    var lambda: Double {
      let seconds = halfLifeDays * 86_400.0
      return seconds > 0 ? log(2.0) / seconds : 0
    }
  }

  private let configuration: Configuration
  private let fileURL: URL
  private let queue = DispatchQueue(label: "flash.frecency.io", qos: .utility)
  private let lock = NSLock()
  private var entries: [String: Entry]
  /// Decayed integer-boost snapshot consumed by the live ranker.
  /// Re-derived after every write so each `recordOpen` immediately
  /// reflects in subsequent `boost(forKey:)` reads, without paying
  /// the `exp()` cost per keystroke.
  private var boostSnapshot: [String: Int]
  /// Pending in-memory deltas that the next flush will commit.
  /// `recordOpen` updates `entries` synchronously inside the lock,
  /// then schedules an async write; `flushIfNeeded` consolidates
  /// rapid bursts (`recordOpen` of 20 candidates from a script) into
  /// one disk write.
  private var dirty = false

  init?(configuration: Configuration = Configuration(), fileURL: URL? = nil) {
    self.configuration = configuration
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let appSupport =
        FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
      self.fileURL =
        appSupport
        .appendingPathComponent("Flash")
        .appendingPathComponent("frecency.json")
    }
    do {
      try FileManager.default.createDirectory(
        at: self.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    } catch {
      FlashLog.warn(
        "[frecency] cannot create directory: \(error)",
        fields: ["path": self.fileURL.deletingLastPathComponent().path])
      return nil
    }
    self.entries = FrecencyStore.loadEntries(from: self.fileURL)
    self.boostSnapshot = FrecencyStore.deriveBoosts(
      entries: self.entries, configuration: configuration, now: Date().timeIntervalSince1970)
    FlashLog.info(
      "[frecency] loaded",
      fields: ["path": self.fileURL.path, "rows": "\(self.entries.count)"])
  }

  /// Record one open of `itemKey`. Updates the in-memory entry +
  /// snapshot inside the lock so subsequent reads see it; the write
  /// to disk is coalesced on the background queue.
  func recordOpen(itemKey: String) {
    guard !itemKey.isEmpty else { return }
    let now = Date().timeIntervalSince1970
    let lambda = configuration.lambda
    lock.lock()
    if var existing = entries[itemKey] {
      let dt = max(0, now - existing.lastAt)
      let decayed = existing.score * exp(-lambda * dt)
      existing.score = decayed + 1.0
      existing.lastAt = now
      existing.openCount += 1
      entries[itemKey] = existing
    } else {
      entries[itemKey] = Entry(score: 1.0, lastAt: now, openCount: 1)
    }
    boostSnapshot = FrecencyStore.deriveBoosts(
      entries: entries, configuration: configuration, now: now)
    dirty = true
    lock.unlock()
    scheduleFlush()
  }

  /// O(1) lookup. Returns 0 when the key isn't tracked. Called from
  /// the live ranker — never blocks on the queue.
  func boost(forKey key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return boostSnapshot[key] ?? 0
  }

  /// `true` when the boost snapshot has no entries — every `boost(forKey:)`
  /// would return 0. The live ranker checks this once per keystroke to
  /// skip the per-candidate `FrecencyMapper.itemKey` allocation that
  /// would otherwise run on the full scored set for no effect.
  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return boostSnapshot.isEmpty
  }

  /// Block until any pending write has hit disk. Tests + shutdown.
  func drain() {
    let group = DispatchGroup()
    group.enter()
    queue.async { group.leave() }
    group.wait()
  }

  // MARK: - Private

  private func scheduleFlush() {
    queue.async { [weak self] in
      self?.flushIfNeeded()
    }
  }

  private func flushIfNeeded() {
    lock.lock()
    guard dirty else {
      lock.unlock()
      return
    }
    // Trim before persisting so the file size stays bounded across
    // long-running installs. Sort by decayed boost descending and
    // keep the top `maxEntries`; everything else has rounded to a
    // negligible boost anyway.
    if entries.count > configuration.maxEntries {
      let now = Date().timeIntervalSince1970
      let lambda = configuration.lambda
      let scored = entries.map { (key, entry) -> (String, Entry, Double) in
        let dt = max(0, now - entry.lastAt)
        let decayed = entry.score * exp(-lambda * dt)
        return (key, entry, decayed)
      }
      let trimmed =
        scored
        .sorted { $0.2 > $1.2 }
        .prefix(configuration.maxEntries)
      var next: [String: Entry] = [:]
      next.reserveCapacity(trimmed.count)
      for (key, entry, _) in trimmed { next[key] = entry }
      entries = next
      boostSnapshot = FrecencyStore.deriveBoosts(
        entries: entries, configuration: configuration, now: now)
    }
    let snapshot = entries
    dirty = false
    lock.unlock()
    persist(snapshot)
  }

  private func persist(_ snapshot: [String: Entry]) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(snapshot)
      // Atomic write so a crash mid-write can't leave us with a
      // half-flushed dict — readers either see the prior state or
      // the new one.
      let tmp = fileURL.appendingPathExtension("tmp")
      try data.write(to: tmp, options: [.atomic])
      _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    } catch {
      FlashLog.warn(
        "[frecency] persist failed: \(error)",
        fields: ["path": fileURL.path])
    }
  }

  private static func loadEntries(from url: URL) -> [String: Entry] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode([String: Entry].self, from: data)
    } catch {
      FlashLog.warn(
        "[frecency] load failed: \(error)",
        fields: ["path": url.path])
      return [:]
    }
  }

  private static func deriveBoosts(
    entries: [String: Entry],
    configuration: Configuration,
    now: TimeInterval
  ) -> [String: Int] {
    let lambda = configuration.lambda
    let coefficient = configuration.coefficient
    let maxBoost = configuration.maxBoost
    var out: [String: Int] = [:]
    out.reserveCapacity(entries.count)
    for (key, entry) in entries {
      let dt = max(0, now - entry.lastAt)
      let decayed = entry.score * exp(-lambda * dt)
      if decayed <= 0 { continue }
      let raw = coefficient * log(1.0 + decayed)
      let boost = min(maxBoost, Int(raw))
      if boost > 0 { out[key] = boost }
    }
    return out
  }
}

/// Stable item-key derivation. Mirrors the prior GRDB store's
/// `FrecencyKey` so persisted entries from past sessions decode under
/// the same identifiers.
enum FrecencyKey {
  static func app(bundleID: String) -> String { "app.bundle:\(bundleID)" }
  static func appPath(_ path: String) -> String { "app.path:\(path)" }
  static func url(_ canonical: String) -> String { "url:\(canonical)" }
  /// Command-line completion entries (`:flashlight`, `:help`, …) so
  /// the empty `:` prompt surfaces frequently-typed commands.
  static func command(label: String) -> String {
    "command:\(label.lowercased())"
  }
}
