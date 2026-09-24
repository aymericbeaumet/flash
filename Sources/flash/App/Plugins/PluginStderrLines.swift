import Foundation

/// A plugin's stderr as whole log lines: chunks are split on newlines (a
/// partial line waits for its end), each line is capped and decoded lossily,
/// and at most `maxLines` lines per window reach the log — the rest are
/// counted and reported once, when the next window opens.
struct PluginStderrLines {
  static let maxLineBytes = 4096
  static let maxLines = 20
  static let windowNs: UInt64 = 10_000_000_000

  private var partial = Data()
  private var windowStart: UInt64 = 0
  private var emittedInWindow = 0
  private var suppressedInWindow = 0

  struct Output: Equatable {
    var lines: [String] = []
    /// Lines the previous window dropped, reported with the first line of the next.
    var suppressed = 0
  }

  mutating func append(_ data: Data, now: UInt64) -> Output {
    var output = Output()
    if now &- windowStart >= Self.windowNs {
      output.suppressed = suppressedInWindow
      windowStart = now
      emittedInWindow = 0
      suppressedInWindow = 0
    }
    partial.append(data)
    while let newline = partial.firstIndex(of: 0x0A) {
      let line = partial[partial.startIndex..<newline]
      partial.removeSubrange(partial.startIndex...newline)
      emit(line, into: &output)
    }
    // A line longer than the cap is flushed rather than buffered forever.
    if partial.count > Self.maxLineBytes {
      emit(partial, into: &output)
      partial.removeAll()
    }
    return output
  }

  private mutating func emit(_ bytes: Data, into output: inout Output) {
    let text = String(decoding: bytes.prefix(Self.maxLineBytes), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard emittedInWindow < Self.maxLines else {
      suppressedInWindow += 1
      return
    }
    emittedInWindow += 1
    output.lines.append(bytes.count > Self.maxLineBytes ? text + "…" : text)
  }
}
