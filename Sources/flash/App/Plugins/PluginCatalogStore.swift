import FlashCore
import Foundation

/// Host-owned warm-catalog store fed by plugin `publish` notifications.
/// The flashlight first paint reads host memory here and never waits on a
/// plugin. A plugin's catalog is its sources' rows, each source holding the
/// rows it last published: a publish without `source` replaces every
/// source, one with `source` replaces that source alone (empty rows =
/// authoritative empty, of the catalog or of the source). The row and byte
/// quotas bound the merged catalog, so an over-quota merge is rejected and
/// the previous rows stay; a rejected publish never reaches the rows, and
/// the last-good catalog is kept by construction — across plugin crashes
/// and restarts. Entries are dropped only on `failed` park or unload.
final class PluginCatalogStore {
  struct Entry {
    var rows: [Candidate]
    var generation: UInt64
    var publishedAt: Date
    /// The merged catalog's wire bytes (`quotas.catalog_bytes`).
    var encodedBytes: Int
  }

  enum PublishOutcome: Equatable {
    case stored
    /// The rows it names are already held: nothing moved.
    case unchanged
    /// The merged catalog would exceed the row or byte quota: nothing moved.
    case overQuota
  }

  private struct SourceRows {
    var rows: [Candidate]
    /// The sum of its rows' wire spans.
    var spanBytes: Int
  }

  private struct Catalog {
    /// Sources in first-publication order; the merged rows follow it.
    var order: [String] = []
    var sources: [String: SourceRows] = [:]
    var entry: Entry

    var mergedRows: [Candidate] { order.flatMap { sources[$0]?.rows ?? [] } }
    var rowCount: Int { sources.values.reduce(0) { $0 + $1.rows.count } }
    var encodedBytes: Int {
      PluginWireCodec.DecodedPublish.catalogBytes(
        spanSum: sources.values.reduce(0) { $0 + $1.spanBytes }, rows: rowCount)
    }
  }

  private let lock = NSLock()
  private var catalogs: [String: Catalog] = [:]
  private var generation: UInt64 = 0
  private var lastNotifyAt: Date?
  private var notifyScheduled = false
  /// Minimum spacing of `onCatalogsChanged` callbacks. Overridable so tests
  /// exercise the coalescing in milliseconds.
  var notifyInterval: TimeInterval = 1.0
  /// Fired on the main queue, coalesced to at most one call per
  /// `notifyInterval` — lossless, because consumers re-read the store, which
  /// is already current when the trailing tick lands.
  var onCatalogsChanged: (() -> Void)?
  /// One pending notify per store, by instance.
  private let notifyClientID = "core:catalog_notify:\(UUID().uuidString)"

  /// Merge one decoded publish into the plugin's catalog. The comparison
  /// and the merge run outside the lock — the flashlight's paint path reads
  /// through it — and the write re-checks that no other publish landed
  /// meanwhile.
  @discardableResult
  func publish(pluginID: String, _ publish: PluginWireCodec.DecodedPublish) -> PublishOutcome {
    while true {
      lock.lock()
      let current = catalogs[pluginID]
      lock.unlock()
      let before = current?.entry.generation
      // A source publish compares only its source; a catalog one compares
      // the catalogs as the store would hold them, grouped by source.
      if let source = publish.source {
        let held = current?.sources[source]?.rows ?? []
        if Self.sameCatalog(held, publish.rows) { return .unchanged }
      }
      guard let next = Self.merged(publish, into: current) else { return .overQuota }
      let mergedRows = next.mergedRows
      if publish.source == nil, let current, Self.sameCatalog(current.entry.rows, mergedRows) {
        return .unchanged
      }
      lock.lock()
      guard catalogs[pluginID]?.entry.generation == before else {
        lock.unlock()
        continue
      }
      generation &+= 1
      var stored = next
      stored.entry = Entry(
        rows: mergedRows, generation: generation, publishedAt: Date(),
        encodedBytes: next.encodedBytes)
      catalogs[pluginID] = stored
      lock.unlock()
      scheduleNotify()
      return .stored
    }
  }

  /// The catalog after `publish`, or nil when the merge would exceed a
  /// quota.
  private static func merged(
    _ publish: PluginWireCodec.DecodedPublish, into current: Catalog?
  ) -> Catalog? {
    var next =
      current
      ?? Catalog(entry: Entry(rows: [], generation: 0, publishedAt: Date(), encodedBytes: 2))
    if let source = publish.source {
      if publish.rows.isEmpty {
        next.sources.removeValue(forKey: source)
        next.order.removeAll { $0 == source }
      } else {
        if next.sources[source] == nil { next.order.append(source) }
        next.sources[source] = SourceRows(
          rows: publish.rows, spanBytes: publish.rowBytes.reduce(0, +))
      }
    } else {
      next.order = []
      next.sources = [:]
      for (row, bytes) in zip(publish.rows, publish.rowBytes) {
        let source = row.metadata[CandidateMetadataKey.source] ?? ""
        if next.sources[source] == nil {
          next.order.append(source)
          next.sources[source] = SourceRows(rows: [], spanBytes: 0)
        }
        next.sources[source]?.rows.append(row)
        next.sources[source]?.spanBytes += bytes
      }
    }
    guard next.rowCount <= PluginProtocol.maxCatalogRows,
      next.encodedBytes <= PluginProtocol.maxCatalogBytes
    else { return nil }
    return next
  }

  /// Compare only the source-owned catalog contract. Ranking caches are
  /// derived later on value copies and must not turn an identical publish
  /// into observable catalog churn.
  private static func sameCatalog(_ lhs: [Candidate], _ rhs: [Candidate]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
      left.title == right.title
        && left.url == right.url
        && left.metadata == right.metadata
        && left.effect == right.effect
    }
  }

  /// Drop one plugin's catalog (unload or `failed` park). Plain restarts do
  /// NOT drop — the catalog survives so the flashlight stays populated while
  /// the plugin relaunches.
  func drop(pluginID: String) {
    lock.lock()
    let removed = catalogs.removeValue(forKey: pluginID) != nil
    lock.unlock()
    if removed {
      scheduleNotify()
    }
  }

  /// Manager shutdown: clear everything without a change tick (the callback
  /// is being torn down with the manager).
  func removeAll() {
    lock.lock()
    catalogs.removeAll()
    lock.unlock()
  }

  /// Value-snapshot read of one plugin's rows; `[]` when nothing published.
  func rows(for pluginID: String) -> [Candidate] {
    lock.lock()
    defer { lock.unlock() }
    return catalogs[pluginID]?.entry.rows ?? []
  }

  func entry(for pluginID: String) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return catalogs[pluginID]?.entry
  }

  func publishedPluginIDs() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return catalogs.keys.sorted()
  }

  private func scheduleNotify() {
    lock.lock()
    if notifyScheduled {
      lock.unlock()
      return
    }
    let delay: TimeInterval
    if let last = lastNotifyAt {
      delay = max(0, notifyInterval - Date().timeIntervalSince(last))
    } else {
      delay = 0
    }
    notifyScheduled = true
    lock.unlock()
    // The throttle's trailing edge rides the shared clock. `.normal`: an open
    // flashlight re-reads the store on it at most once a second, so a tenth
    // of a second is invisible, and with the flashlight closed it only
    // updates movement history.
    PollScheduler.shared.scheduleOnce(
      notifyClientID, afterMs: Int((delay * 1000).rounded(.up)), priority: .normal, on: .main
    ) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.notifyScheduled = false
      self.lastNotifyAt = Date()
      self.lock.unlock()
      self.onCatalogsChanged?()
    }
  }
}
