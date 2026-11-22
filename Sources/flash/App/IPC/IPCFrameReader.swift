import Foundation

/// Splits a byte stream into newline-delimited frames, each at most
/// `maxFrameBytes` long (the newline excluded). Blank lines are skipped, so a
/// session typed by hand survives an extra Return. Once a frame is too
/// large the stream has no trustworthy boundary left: the reader reports
/// `.tooLarge` once and ignores everything after it.
struct IPCFrameReader {
  enum Output: Equatable {
    case frame(Data)
    case tooLarge
  }

  let maxFrameBytes: Int
  private var buffer = Data()
  /// Bytes of `buffer` already searched for a newline.
  private var scanned = 0
  private(set) var poisoned = false

  init(maxFrameBytes: Int) {
    self.maxFrameBytes = maxFrameBytes
  }

  /// The frames `bytes` completes, in order.
  mutating func append(_ bytes: Data) -> [Output] {
    guard !poisoned else { return [] }
    buffer.append(bytes)
    var outputs: [Output] = []
    while true {
      let start = buffer.startIndex
      guard
        let newline = buffer[(start + scanned)...].firstIndex(of: 0x0A)
      else {
        scanned = buffer.count
        if buffer.count > maxFrameBytes { return outputs + [poison()] }
        return outputs
      }
      let line = buffer[start..<newline]
      if line.count > maxFrameBytes { return outputs + [poison()] }
      let isBlank = line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
      if !isBlank { outputs.append(.frame(Data(line))) }
      buffer.removeSubrange(start...newline)
      scanned = 0
    }
  }

  private mutating func poison() -> Output {
    poisoned = true
    buffer = Data()
    scanned = 0
    return .tooLarge
  }
}
