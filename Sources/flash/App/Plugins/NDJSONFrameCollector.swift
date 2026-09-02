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

  init(maxLineBytes: Int = PluginProtocol.maxFrameBytes) {
    self.maxLineBytes = maxLineBytes
  }

  mutating func append(_ data: Data) -> [Output] {
    var outputs: [Output] = []
    buffer.append(data)
    var consumed = buffer.startIndex
    var searchStart = buffer.startIndex
    while searchStart < buffer.endIndex,
      let newline = buffer[searchStart...].firstIndex(of: 0x0A)
    {
      let line = Data(buffer[consumed..<newline])
      consumed = buffer.index(after: newline)
      searchStart = consumed
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
    if consumed > buffer.startIndex {
      buffer.removeSubrange(buffer.startIndex..<consumed)
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
