/// Byte and frame admission for one child transport. Its owner supplies the
/// lock; stale releases never consume a replacement child's reservations.
struct PluginTransportBudget {
  enum Lane: Hashable { case readChunks, readFrames, writeFrames }
  struct Reservation {
    let generation: UInt64
    let lane: Lane
    let bytes: Int
  }
  private(set) var generation: UInt64 = 0
  private var failed = false
  private var usage: [Lane: (frames: Int, bytes: Int)] = [:]

  mutating func begin(_ generation: UInt64) {
    self.generation = generation
    failed = false
    usage.removeAll(keepingCapacity: true)
  }

  mutating func reserve(_ lane: Lane, bytes: Int) -> Reservation? {
    let current = usage[lane] ?? (0, 0)
    let frameLimit =
      lane == .writeFrames ? PluginProtocol.maxOutboundFrames : PluginProtocol.maxInboundFrames
    let byteLimit =
      lane == .writeFrames ? PluginProtocol.maxOutboundBytes : PluginProtocol.maxInboundBytes
    guard !failed, generation != 0, bytes >= 0, bytes <= byteLimit,
      current.frames < frameLimit, current.bytes <= byteLimit - bytes
    else { return nil }
    usage[lane] = (current.frames + 1, current.bytes + bytes)
    return Reservation(generation: generation, lane: lane, bytes: bytes)
  }

  mutating func fail(generation: UInt64) -> Bool {
    guard generation != 0, generation == self.generation, !failed else { return false }
    failed = true
    return true
  }

  mutating func release(_ reservation: Reservation) {
    guard reservation.generation == generation, let current = usage[reservation.lane] else {
      return
    }
    usage[reservation.lane] = (
      max(0, current.frames - 1), max(0, current.bytes - reservation.bytes)
    )
  }
}
