import Foundation

/// Pulls complete length-prefixed MessagePack frames out of a byte stream: a
/// 4-byte big-endian payload length followed by exactly that many bytes. Binary-
/// safe (no delimiter scanning).
///
/// Extracted from `PluginProcess` so the framing edge cases — a partial tail
/// split across reads, several frames arriving in one chunk, an oversized length
/// from a desynced stream — are unit-testable without spawning a plugin (the
/// host's actual frame parser previously had no coverage).
struct MessagePackFrameCollector {
  /// A declared payload length past this means the stream desynced (a stray
  /// write to the plugin's stdout misread as a length prefix). The collector
  /// can't realign mid-stream, so it drops the buffer rather than try to
  /// allocate gigabytes.
  let maxFrameBytes: Int
  private var buffer = Data()

  enum Output: Equatable {
    case frame(Data)
    /// The declared length exceeded `maxFrameBytes` (or was negative): the
    /// stream is unrecoverable, the buffer has been dropped, stop processing.
    case desynced(length: Int)
  }

  init(maxFrameBytes: Int) {
    self.maxFrameBytes = maxFrameBytes
  }

  /// Append freshly-read bytes and return every complete frame now available,
  /// in order. A `.desynced` output is always last (the buffer is dropped after
  /// it). Any partial tail stays buffered for the next call.
  mutating func append(_ data: Data) -> [Output] {
    buffer.append(data)
    var outputs: [Output] = []
    while buffer.count >= 4 {
      let base = buffer.startIndex
      let length =
        (Int(buffer[base]) << 24)
        | (Int(buffer[base + 1]) << 16)
        | (Int(buffer[base + 2]) << 8)
        | Int(buffer[base + 3])
      guard length >= 0, length <= maxFrameBytes else {
        outputs.append(.desynced(length: length))
        buffer.removeAll(keepingCapacity: false)
        return outputs
      }
      guard buffer.count >= 4 + length else { break }
      let payloadStart = base + 4
      let payloadEnd = payloadStart + length
      outputs.append(.frame(buffer.subdata(in: payloadStart..<payloadEnd)))
      buffer.removeSubrange(base..<payloadEnd)
    }
    return outputs
  }
}
