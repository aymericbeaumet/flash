import Foundation

/// Parsed documents by their source text. Popup bodies and status texts are
/// re-read on every tick; the parse is pure, so each distinct text is lexed
/// once while it stays in use.
final class StatusFormatDocumentCache {
  static let shared = StatusFormatDocumentCache()
  private struct Key: Hashable {
    var raw: String
    var origin: StatusFormatOrigin
    var defaultForeground: FlashStatusTextColor
  }
  private let cache = StatusFormatBoundedCache<Key, StatusFormatDocument>(
    maxEntries: 512, maxBytes: 2_097_152, maxEntryBytes: 262_144)

  func document(
    raw: String, origin: StatusFormatOrigin, defaultForeground: FlashStatusTextColor,
    parse: () -> StatusFormatDocument
  ) -> StatusFormatDocument {
    cache.value(
      for: Key(raw: raw, origin: origin, defaultForeground: defaultForeground),
      size: raw.utf8.count, make: parse)
  }
}
