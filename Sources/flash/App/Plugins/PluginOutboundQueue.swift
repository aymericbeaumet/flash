import Foundation

/// Encoded frames waiting for one child's stdin, in send order. Its owner
/// supplies the lock and the admission budget each frame's reservation holds.
///
/// A frame carrying a coalescing key (a replacement event, see
/// `PluginProtocol.coalescingKey`) supersedes the unsent frame with the same
/// key: the older frame leaves the queue and the newer one joins the tail. A
/// child therefore reads a subsequence of what the host emitted, never a
/// reordering, and one that briefly stops reading accumulates at most one
/// frame per key instead of overflowing on pure state signals. Requests,
/// responses and every other event keep FIFO order and their budget.
struct PluginOutboundQueue {
  struct Frame {
    let data: Data
    let label: String
    let coalescingKey: String?
    let handle: FileHandle
    let reservation: PluginTransportBudget.Reservation
  }

  private var frames: [Frame] = []

  /// Remove and return the unsent frame `key` supersedes, if any.
  mutating func removeSuperseded(by key: String) -> Frame? {
    guard let index = frames.firstIndex(where: { $0.coalescingKey == key }) else { return nil }
    return frames.remove(at: index)
  }

  mutating func append(_ frame: Frame) {
    frames.append(frame)
  }

  mutating func popFirst() -> Frame? {
    frames.isEmpty ? nil : frames.removeFirst()
  }
}
