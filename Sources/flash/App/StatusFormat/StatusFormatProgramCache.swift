import Foundation

/// Dynamic E/T expansions share the compiler without retaining an unbounded
/// history of plugin values. Compilations happen outside the lock.
final class StatusFormatProgramCache {
  static let shared = StatusFormatProgramCache()
  private struct Key: Hashable {
    var source: String
    var origin: StatusFormatOrigin
  }
  private let lock = NSLock()
  private var entries: [Key: StatusFormatProgram] = [:]
  private var order: [Key] = []
  private var bytes = 0

  func program(source: String, origin: StatusFormatOrigin, compile: () -> StatusFormatProgram)
    -> StatusFormatProgram
  {
    let key = Key(source: source, origin: origin)
    lock.lock()
    if let cached = entries[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let program = compile()
    let size = source.utf8.count
    guard size <= 262_144 else { return program }
    lock.lock()
    defer { lock.unlock() }
    guard entries[key] == nil else { return entries[key]! }
    while !order.isEmpty, order.count >= 256 || bytes + size > 1_048_576 {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
      bytes -= oldest.source.utf8.count
    }
    entries[key] = program
    order.append(key)
    bytes += size
    return program
  }
}
