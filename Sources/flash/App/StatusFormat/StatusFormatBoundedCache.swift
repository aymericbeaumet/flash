import Foundation

/// The status format's memo of pure work keyed by text — parsed documents,
/// compiled programs, compiled regexes — bounded in entries and in the bytes
/// of the text they were made from, oldest first. The work runs outside the
/// lock; two callers racing on one key keep the first value stored. An entry
/// made from more than `maxEntryBytes` is returned but never kept.
final class StatusFormatBoundedCache<Key: Hashable, Value> {
  let maxEntries: Int
  let maxBytes: Int
  let maxEntryBytes: Int
  private let lock = NSLock()
  private var entries: [Key: (value: Value, bytes: Int)] = [:]
  private var order: [Key] = []
  private var bytes = 0

  init(maxEntries: Int, maxBytes: Int, maxEntryBytes: Int) {
    self.maxEntries = maxEntries
    self.maxBytes = maxBytes
    self.maxEntryBytes = maxEntryBytes
  }

  /// The value for `key`, made by `make` from text of `size` bytes when
  /// absent.
  func value(for key: Key, size: Int, make: () -> Value) -> Value {
    lock.lock()
    if let cached = entries[key] {
      lock.unlock()
      return cached.value
    }
    lock.unlock()
    let made = make()
    guard size <= maxEntryBytes else { return made }
    lock.lock()
    defer { lock.unlock() }
    if let cached = entries[key] { return cached.value }
    while !order.isEmpty, order.count >= maxEntries || bytes + size > maxBytes {
      let oldest = order.removeFirst()
      bytes -= entries.removeValue(forKey: oldest)?.bytes ?? 0
    }
    entries[key] = (made, size)
    order.append(key)
    bytes += size
    return made
  }

  /// Entries kept now. Tests.
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }
}
