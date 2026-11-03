import Foundation

/// One connection's unsent frames, bounded, pure. Replies (`welcome`,
/// `result`, `subscribed`, `error`) are always admitted: the in-flight cap
/// bounds them. Events are admitted under `maxEvents` frames and
/// `maxEventBytes` bytes. A replacement event (`HostEvent.supersedesEarlier`,
/// keyed by `PluginProtocol.coalescingKey`) first drops an unsent one with
/// its key and joins the tail, as a plugin's queue does, so a slow reader
/// sees the latest state; an event that still does not fit overflows the
/// subscriber, which the server then disconnects. The frame being written
/// is never dropped or coalesced away: that would cut a line in half.
struct IPCOutbox {
  enum Admission: Equatable {
    case queued
    /// An older unsent event with the same key was dropped for this one.
    case coalesced
    /// It does not fit: the subscriber is too far behind.
    case overflow
  }

  private struct Frame {
    var data: Data
    var isEvent: Bool
    var coalescingKey: String?
  }

  let maxEvents: Int
  let maxEventBytes: Int
  private var frames: [Frame] = []
  /// Bytes of `frames[0]` already written.
  private var written = 0
  private(set) var eventCount = 0
  private(set) var eventBytes = 0

  init(
    maxEvents: Int = IPCProtocol.maxQueuedEvents,
    maxEventBytes: Int = IPCProtocol.maxQueuedEventBytes
  ) {
    self.maxEvents = maxEvents
    self.maxEventBytes = maxEventBytes
  }

  var isEmpty: Bool { frames.isEmpty }
  var count: Int { frames.count }

  mutating func enqueueReply(_ data: Data) {
    frames.append(Frame(data: data, isEvent: false, coalescingKey: nil))
  }

  mutating func enqueueEvent(_ data: Data, coalescingKey key: String?) -> Admission {
    var admission = Admission.queued
    if let key,
      let index = frames.indices.first(where: { index in
        frames[index].coalescingKey == key && !(index == 0 && written > 0)
      })
    {
      eventCount -= 1
      eventBytes -= frames[index].data.count
      frames.remove(at: index)
      admission = .coalesced
    }
    guard eventCount < maxEvents, eventBytes + data.count <= maxEventBytes else {
      return .overflow
    }
    frames.append(Frame(data: data, isEvent: true, coalescingKey: key))
    eventCount += 1
    eventBytes += data.count
    return admission
  }

  /// Drop every unsent frame for `data`, the last thing this connection
  /// says (an `overflow` or `shutting_down` error). A frame already half
  /// written stays ahead of it, so the line it started still ends.
  mutating func replaceWithFinal(_ data: Data) {
    if written > 0, let head = frames.first {
      frames = [head]
      eventCount = head.isEvent ? 1 : 0
      eventBytes = head.isEvent ? head.data.count : 0
    } else {
      frames = []
      eventCount = 0
      eventBytes = 0
    }
    frames.append(Frame(data: data, isEvent: false, coalescingKey: nil))
  }

  /// Hand bytes to `write`, which returns how many it took (0 when the
  /// socket is full), until everything is written or it takes nothing.
  /// Returns false when `write` failed (it returned a negative count).
  mutating func drain(_ write: (UnsafeRawBufferPointer) -> Int) -> Bool {
    while let head = frames.first {
      let count = head.data.withUnsafeBytes { raw in
        write(UnsafeRawBufferPointer(rebasing: raw[written...]))
      }
      if count < 0 { return false }
      if count == 0 { return true }
      written += count
      guard written >= head.data.count else { continue }
      if head.isEvent {
        eventCount -= 1
        eventBytes -= head.data.count
      }
      frames.removeFirst()
      written = 0
    }
    return true
  }

  /// The unsent frames' names, oldest first, for tests: each frame's
  /// coalescing key, or nil.
  var keys: [String?] { frames.map(\.coalescingKey) }
}
