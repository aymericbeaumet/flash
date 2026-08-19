import Foundation

/// Reassembles plugin stdout bytes into complete newline-terminated frames.
/// One JSON object per line; an overlong line is discarded (reported once,
/// with its byte count) and the stream self-heals at the next newline — no
/// teardown required, unlike length-prefixed framing where a desynced
/// prefix poisoned everything after it.
struct NDJSONFrameCollector {
  enum Output: Equatable {
    case frame(Data)
    case oversized(Int)
  }

  private var buffer = Data()
  private var discarding = false
  private var discardedBytes = 0
  let maxLineBytes: Int

  init(maxLineBytes: Int = 10 * 1024 * 1024) {
    self.maxLineBytes = maxLineBytes
  }

  mutating func append(_ data: Data) -> [Output] {
    var outputs: [Output] = []
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer = Data(buffer[buffer.index(after: newline)...])
      if discarding {
        discarding = false
        outputs.append(.oversized(discardedBytes + line.count))
        discardedBytes = 0
      } else if line.count > maxLineBytes {
        outputs.append(.oversized(line.count))
      } else if !line.isEmpty {
        outputs.append(.frame(line))
      }
    }
    if discarding {
      discardedBytes += buffer.count
      buffer.removeAll(keepingCapacity: true)
    } else if buffer.count > maxLineBytes {
      discarding = true
      discardedBytes = buffer.count
      buffer.removeAll(keepingCapacity: false)
    }
    return outputs
  }
}
