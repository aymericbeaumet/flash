import Foundation

/// Parsed documents by their source text. Popup bodies and status texts are
/// re-read on every tick; the parse is pure, so each distinct text is lexed
/// once while it stays in use. Bounded like `StatusFormatProgramCache`.
final class StatusFormatDocumentCache {
  static let shared = StatusFormatDocumentCache()
  private struct Key: Hashable {
    var raw: String
    var origin: StatusFormatOrigin
    var defaultForeground: FlashStatusTextColor
  }
  private let lock = NSLock()
  private var entries: [Key: StatusFormatDocument] = [:]
  private var order: [Key] = []
  private var bytes = 0

  func document(
    raw: String, origin: StatusFormatOrigin, defaultForeground: FlashStatusTextColor,
    parse: () -> StatusFormatDocument
  ) -> StatusFormatDocument {
    let key = Key(raw: raw, origin: origin, defaultForeground: defaultForeground)
    lock.lock()
    if let cached = entries[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let document = parse()
    let size = raw.utf8.count
    guard size <= 262_144 else { return document }
    lock.lock()
    defer { lock.unlock() }
    if let cached = entries[key] { return cached }
    while !order.isEmpty, order.count >= 512 || bytes + size > 2_097_152 {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
      bytes -= oldest.raw.utf8.count
    }
    entries[key] = document
    order.append(key)
    bytes += size
    return document
  }
}
