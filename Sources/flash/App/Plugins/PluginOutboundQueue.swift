import Darwin
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

    init(
      data: Data, label: String, coalescingKey: String?, handle: FileHandle,
      reservation: PluginTransportBudget.Reservation
    ) throws {
      // Teardown closes the lifecycle's stdin handle while a dequeued write
      // may still be running. Foundation raises an Objective-C exception if
      // that same handle is closed during write, outside Swift's do/catch.
      // Keep this frame's writer alive until its final write has returned.
      let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
      guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        close(descriptor)
        throw error
      }
      self.data = data
      self.label = label
      self.coalescingKey = coalescingKey
      self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      self.reservation = reservation
    }
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
