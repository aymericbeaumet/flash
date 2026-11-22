import Darwin
import Foundation

final class StatusFormatCompiledRegex {
  let pointer: UnsafeMutablePointer<regex_t>

  init?(pattern: String, flags: Int32) {
    let allocation = UnsafeMutablePointer<regex_t>.allocate(capacity: 1)
    allocation.initialize(to: regex_t())
    guard regcomp(allocation, pattern, flags) == 0 else {
      allocation.deinitialize(count: 1)
      allocation.deallocate()
      return nil
    }
    pointer = allocation
  }

  deinit {
    regfree(pointer)
    pointer.deinitialize(count: 1)
    pointer.deallocate()
  }
}

/// Compiled regexes by pattern and flags; a pattern that does not compile is
/// remembered as nil.
final class StatusFormatRegexCache {
  static let shared = StatusFormatRegexCache()
  private struct Key: Hashable {
    var pattern: String
    var flags: Int32
  }
  private let cache = StatusFormatBoundedCache<Key, StatusFormatCompiledRegex?>(
    maxEntries: 128, maxBytes: 262_144, maxEntryBytes: 65_536)

  func regex(pattern: String, flags: Int32) -> StatusFormatCompiledRegex? {
    cache.value(for: Key(pattern: pattern, flags: flags), size: pattern.utf8.count) {
      StatusFormatCompiledRegex(pattern: pattern, flags: flags)
    }
  }
}
