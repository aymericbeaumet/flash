import Foundation

/// The socket clients' share of the one host-event fan-out
/// (`AppDelegate.emitHostEvent`), main-thread confined. It knows which
/// connection subscribes to which events; `publish` encodes an event once,
/// numbers it, and hands the frame to `deliver` with the connections that
/// asked for it. With no subscriber `hasSubscriber` is false for every
/// event, so no OS source runs and nothing is encoded on its account.
final class IPCEventHub {
  /// Hands one encoded event to the server: the frame, its coalescing key
  /// (`PluginProtocol.coalescingKey`) and the connections it is for.
  var deliver: ((_ frame: Data, _ coalescingKey: String?, _ connections: [UInt64]) -> Void)?
  /// The set of subscribed events changed: OS sources may start or stop.
  var subscribersDidChange: (() -> Void)?

  private var subscriptions: [UInt64: Set<String>] = [:]
  /// How many connections subscribe to each event.
  private var subscriberCounts: [String: Int] = [:]
  /// The last `seq` sent: one sequence for every subscriber, so a gap in
  /// what one client reads is an event it did not ask for, or coalesced.
  private(set) var sequence: UInt64 = 0
  private let clock: () -> Int64

  init(clock: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }) {
    self.clock = clock
  }

  var isEmpty: Bool { subscriberCounts.isEmpty }

  func hasSubscriber(for name: String) -> Bool {
    subscriberCounts[name] != nil
  }

  /// `connection` subscribes to exactly `events` from now on; nil or empty
  /// forgets it.
  func setSubscription(_ connection: UInt64, events: [String]?) {
    let previous = subscriptions[connection] ?? []
    let next = Set(events ?? [])
    guard previous != next else { return }
    for name in previous.subtracting(next) {
      let remaining = (subscriberCounts[name] ?? 1) - 1
      subscriberCounts[name] = remaining > 0 ? remaining : nil
    }
    for name in next.subtracting(previous) {
      subscriberCounts[name, default: 0] += 1
    }
    subscriptions[connection] = next.isEmpty ? nil : next
    subscribersDidChange?()
  }

  /// Send `event` to every connection subscribed to it.
  func publish(_ event: PluginEvent) {
    guard subscriberCounts[event.name] != nil, let deliver else { return }
    let targets = subscriptions.compactMap { id, names in names.contains(event.name) ? id : nil }
      .sorted()
    guard !targets.isEmpty else { return }
    let payload = event.wirePayload
    sequence &+= 1
    guard
      let frame = IPCProtocol.eventFrame(
        seq: sequence, name: event.name, timeMs: clock(), payload: payload)
    else {
      FlashLog.warn("[ipc] unencodable_event", fields: ["event": event.name])
      return
    }
    deliver(frame, PluginProtocol.coalescingKey(eventName: event.name, payload: payload), targets)
  }
}
