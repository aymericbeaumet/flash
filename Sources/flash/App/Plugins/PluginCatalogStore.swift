import FlashCore
import Foundation

/// Host-owned warm-catalog store fed by plugin `publish` notifications.
/// The flashlight first paint reads host memory here and never waits on a
/// plugin. Each publish is a full replacement of that plugin's catalog
/// (empty rows = authoritative empty); a rejected publish never reaches this
/// store, so the last-good catalog is kept by construction — across plugin
/// crashes and restarts. Entries are dropped only on `failed` park or
/// unload.
final class PluginCatalogStore {
  struct Entry {
    var rows: [Candidate]
    var generation: UInt64
    var publishedAt: Date
    var encodedBytes: Int
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
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

  func publish(pluginID: String, rows: [Candidate], encodedBytes: Int) {
    lock.lock()
    generation &+= 1
    entries[pluginID] = Entry(
      rows: rows,
      generation: generation,
      publishedAt: Date(),
      encodedBytes: encodedBytes)
    lock.unlock()
    scheduleNotify()
  }

  /// Drop one plugin's catalog (unload or `failed` park). Plain restarts do
  /// NOT drop — the catalog survives so the flashlight stays populated while
  /// the plugin relaunches.
  func drop(pluginID: String) {
    lock.lock()
    let removed = entries.removeValue(forKey: pluginID) != nil
    lock.unlock()
    if removed {
      scheduleNotify()
    }
  }

  /// Manager shutdown: clear everything without a change tick (the callback
  /// is being torn down with the manager).
  func removeAll() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
  }

  /// Value-snapshot read of one plugin's rows; `[]` when nothing published.
  func rows(for pluginID: String) -> [Candidate] {
    lock.lock()
    defer { lock.unlock() }
    return entries[pluginID]?.rows ?? []
  }

  func entry(for pluginID: String) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    return entries[pluginID]
  }

  func publishedPluginIDs() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return entries.keys.sorted()
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
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.notifyScheduled = false
      self.lastNotifyAt = Date()
      self.lock.unlock()
      self.onCatalogsChanged?()
    }
  }
}
