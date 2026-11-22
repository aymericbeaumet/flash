import Foundation

/// Dynamic E/T expansions share the compiler without retaining an unbounded
/// history of plugin values. Compilations happen outside the lock.
final class StatusFormatProgramCache {
  static let shared = StatusFormatProgramCache()
  private struct Key: Hashable {
    var source: String
    var origin: StatusFormatOrigin
  }
  private let cache = StatusFormatBoundedCache<Key, StatusFormatProgram>(
    maxEntries: 256, maxBytes: 1_048_576, maxEntryBytes: 262_144)

  func program(source: String, origin: StatusFormatOrigin, compile: () -> StatusFormatProgram)
    -> StatusFormatProgram
  {
    cache.value(for: Key(source: source, origin: origin), size: source.utf8.count, make: compile)
  }
}
