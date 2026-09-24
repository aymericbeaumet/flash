import Foundation

/// Flash's one periodic clock.
///
/// Anything that genuinely cannot be driven by an event registers a cadence
/// here instead of arming its own timer: the core's own watchers and every
/// plugin that polls. One `DispatchSourceTimer` serves all of them, so twenty
/// pollers cost one wake-up rather than twenty, and deadlines snap to a
/// multiple of each interval so clients that share a period also share a tick
/// instead of drifting into their own slots.
///
/// The scheduler stops completely when nothing is registered, and a client
/// whose previous tick has not returned is skipped rather than queued, so a
/// slow collector can never pile work up behind itself.
final class PollScheduler {
  /// The process-wide clock. Core watchers and plugin registrations share it
  /// so the whole app wakes on one schedule.
  static let shared = PollScheduler()

  /// Floor on any registration. Below this a "poll" is a busy loop, and the
  /// answer is an event source, not a faster clock.
  static let minimumIntervalMs = 50

  /// How precisely a client needs its deadline honoured. This is the knob that
  /// lets unrelated wake-ups collapse into one: a generous leeway lets the
  /// kernel slide a tick onto an interrupt it was already going to take, which
  /// is where the real power saving lives. Ask for `system` only when the
  /// timing is the feature.
  enum Priority: Int, Comparable, CaseIterable {
    /// Input-adjacent probes whose lateness is user-visible.
    case system
    /// Surfaces the user is looking at right now.
    case high
    /// Ordinary sampling and refreshes.
    case normal
    /// Background upkeep nobody is waiting on.
    case low

    var leewayMs: Int {
      switch self {
      case .system: return 5
      case .high: return 25
      case .normal: return 100
      case .low: return 1000
      }
    }

    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
  }

  struct Plan: Equatable {
    /// Clients due now and free to run.
    var fire: [String] = []
    /// Clients due now whose previous tick is still running.
    var skipped: [String] = []
    /// New deadline for every repeating client that was due.
    var rescheduled: [String: Int] = [:]
    /// One-shot clients that fired and should now be dropped.
    var expired: [String] = []
    /// When the timer should next fire, or nil when nothing is registered.
    var nextWakeupMs: Int?
    /// Slack for that wake-up: the tightest requirement among the clients
    /// riding it, so one demanding client cannot be loosened by a lax one.
    var leewayMs: Int = Priority.low.leewayMs
  }

  struct ClientState: Equatable {
    var id: String
    var intervalMs: Int
    var nextAtMs: Int
    var busy: Bool
    var priority: Priority = .normal
    /// False for a deadline registration, which runs once and is dropped.
    var repeats: Bool = true
  }

  /// A deadline lands on the next multiple of the interval, so every client
  /// registered at (say) one second fires on the same second boundary and the
  /// timer wakes once for all of them.
  static func nextDeadlineMs(afterNowMs now: Int, intervalMs: Int) -> Int {
    let interval = max(minimumIntervalMs, intervalMs)
    return (now / interval + 1) * interval
  }

  /// Pure tick planning, so the coalescing and backpressure rules are tested
  /// without a live timer.
  static func plan(nowMs: Int, clients: [ClientState]) -> Plan {
    var plan = Plan()
    guard !clients.isEmpty else { return plan }
    var pending: [(deadline: Int, priority: Priority)] = []
    for client in clients {
      guard client.nextAtMs <= nowMs else {
        pending.append((client.nextAtMs, client.priority))
        continue
      }
      if client.busy {
        plan.skipped.append(client.id)
      } else {
        plan.fire.append(client.id)
      }
      guard client.repeats else {
        plan.expired.append(client.id)
        continue
      }
      let next = nextDeadlineMs(afterNowMs: nowMs, intervalMs: client.intervalMs)
      plan.rescheduled[client.id] = next
      pending.append((next, client.priority))
    }
    plan.fire.sort()
    plan.skipped.sort()
    plan.expired.sort()
    guard let wakeup = pending.map(\.deadline).min() else { return plan }
    plan.nextWakeupMs = wakeup
    plan.leewayMs =
      pending.filter { $0.deadline == wakeup }.map { $0.priority.leewayMs }.min()
      ?? Priority.normal.leewayMs
    return plan
  }

  private struct Client {
    var state: ClientState
    var queue: DispatchQueue
    var handler: () -> Void
  }

  private let queue = DispatchQueue(label: "flash.poll", qos: .utility)
  private var clients: [String: Client] = [:]
  private var timer: DispatchSourceTimer?
  private var armedForMs: Int?
  private let clock: () -> Int

  init(clock: @escaping () -> Int = { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }) {
    self.clock = clock
  }

  /// Register (or re-register) `id` at `everyMs`. The handler runs on `queue`
  /// and must call nothing back into the scheduler synchronously.
  func register(
    _ id: String, everyMs: Int, priority: Priority = .normal, on handlerQueue: DispatchQueue,
    handler: @escaping () -> Void
  ) {
    let interval = max(Self.minimumIntervalMs, everyMs)
    queue.async { [weak self] in
      guard let self else { return }
      let now = self.clock()
      let existing = self.clients[id]
      let unchanged = existing?.state.intervalMs == interval && existing?.state.repeats == true
      let nextAt =
        unchanged
        ? (existing?.state.nextAtMs ?? Self.nextDeadlineMs(afterNowMs: now, intervalMs: interval))
        : Self.nextDeadlineMs(afterNowMs: now, intervalMs: interval)
      self.clients[id] = Client(
        state: ClientState(
          id: id, intervalMs: interval, nextAtMs: nextAt, busy: existing?.state.busy ?? false,
          priority: priority, repeats: true),
        queue: handlerQueue, handler: handler)
      self.rearm(now: now)
    }
  }

  /// Run once, `afterMs` from now, then drop the registration.
  ///
  /// This is what lets a client whose wake-ups are not a fixed cadence — the
  /// status bar, whose next deadline is the earliest of its per-source
  /// intervals, cycle rotations and pending output — still ride the shared
  /// clock: it re-registers its next deadline each time it fires. Re-arming
  /// an existing id always replaces the pending deadline.
  func scheduleOnce(
    _ id: String, afterMs: Int, priority: Priority = .normal, on handlerQueue: DispatchQueue,
    handler: @escaping () -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let now = self.clock()
      self.clients[id] = Client(
        state: ClientState(
          id: id, intervalMs: max(1, afterMs), nextAtMs: now + max(0, afterMs), busy: false,
          priority: priority, repeats: false),
        queue: handlerQueue, handler: handler)
      self.rearm(now: now)
    }
  }

  func unregister(_ id: String) {
    queue.async { [weak self] in
      guard let self, self.clients.removeValue(forKey: id) != nil else { return }
      self.rearm(now: self.clock())
    }
  }

  /// Every registered id, for diagnostics.
  func registeredIDs(completion: @escaping ([String]) -> Void) {
    queue.async { [weak self] in completion((self?.clients.keys).map { $0.sorted() } ?? []) }
  }

  private func finish(_ id: String) {
    queue.async { [weak self] in self?.clients[id]?.state.busy = false }
  }

  private func rearm(now: Int) {
    let plan = Self.plan(nowMs: now, clients: clients.values.map(\.state))
    guard let wakeup = plan.nextWakeupMs else {
      timer?.cancel()
      timer = nil
      armedForMs = nil
      return
    }
    guard armedForMs != wakeup || timer == nil else { return }
    armedForMs = wakeup
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(max(0, wakeup - now)),
      leeway: .milliseconds(plan.leewayMs))
    timer.setEventHandler { [weak self] in self?.fire() }
    self.timer = timer
    timer.resume()
  }

  private func fire() {
    let now = clock()
    let plan = Self.plan(nowMs: now, clients: clients.values.map(\.state))
    for (id, next) in plan.rescheduled { clients[id]?.state.nextAtMs = next }
    var expired: [String: Client] = [:]
    for id in plan.expired {
      if let client = clients.removeValue(forKey: id) { expired[id] = client }
    }
    if !plan.skipped.isEmpty {
      FlashLog.debug("[poll] overrun skipped=\(plan.skipped.joined(separator: ","))")
    }
    for id in plan.fire {
      if let once = expired[id] {
        once.queue.async { once.handler() }
        continue
      }
      guard let client = clients[id] else { continue }
      clients[id]?.state.busy = true
      client.queue.async { [weak self] in
        client.handler()
        self?.finish(id)
      }
    }
    armedForMs = nil
    rearm(now: now)
  }
}
