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

final class StatusFormatRegexCache {
  static let shared = StatusFormatRegexCache()
  private struct Key: Hashable {
    var pattern: String
    var flags: Int32
  }
  private struct Entry { var regex: StatusFormatCompiledRegex? }
  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]
  private var order: [Key] = []
  private var bytes = 0

  func regex(pattern: String, flags: Int32) -> StatusFormatCompiledRegex? {
    let key = Key(pattern: pattern, flags: flags)
    lock.lock()
    if let entry = entries[key] {
      lock.unlock()
      return entry.regex
    }
    lock.unlock()
    let regex = StatusFormatCompiledRegex(pattern: pattern, flags: flags)
    let size = pattern.utf8.count
    guard size <= 65_536 else { return regex }
    lock.lock()
    defer { lock.unlock() }
    if let entry = entries[key] { return entry.regex }
    while !order.isEmpty, order.count >= 128 || bytes + size > 262_144 {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
      bytes -= oldest.pattern.utf8.count
    }
    entries[key] = Entry(regex: regex)
    order.append(key)
    bytes += size
    return regex
  }
}
