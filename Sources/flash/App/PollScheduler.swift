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
/// slow collector can never pile work up behind itself. It also holds every
/// registration while nothing a poll produces can be seen or acted on —
/// displays asleep, the session switched out or locked, the system going to
/// sleep — and resumes with one catch-up tick for whatever fell due meanwhile.
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

  /// Why every registration is held. Each is set and cleared by its own
  /// workspace notification, so the reasons overlap freely.
  enum Suspension: Hashable, CaseIterable {
    /// The user session is switched out (fast user switching).
    case session
    /// The displays are asleep.
    case screens
    /// The system is going to sleep.
    case systemSleep
    /// The login window (a locked screen) or the screen saver is in front.
    case secureUI
  }

  /// Pure suspension state: the reasons in force and the transition a change
  /// makes. Only the first reason suspends and only the last one's release
  /// resumes.
  struct Gate: Equatable {
    enum Transition: Equatable {
      case unchanged
      case suspended
      case resumed
    }

    private(set) var reasons: Set<Suspension> = []
    var isSuspended: Bool { !reasons.isEmpty }

    mutating func set(_ reason: Suspension, active: Bool) -> Transition {
      let wasSuspended = isSuspended
      if active {
        guard reasons.insert(reason).inserted else { return .unchanged }
      } else {
        guard reasons.remove(reason) != nil else { return .unchanged }
      }
      switch (wasSuspended, isSuspended) {
      case (false, true): return .suspended
      case (true, false): return .resumed
      default: return .unchanged
      }
    }
  }

  /// Milliseconds on a clock that keeps counting while the system sleeps
  /// (`CLOCK_MONOTONIC`, unlike `DispatchTime`'s uptime): a wake finds every
  /// deadline that passed during the sleep overdue, so they run in the one
  /// catch-up tick instead of each waiting out its full interval again.
  static func continuousNowMs() -> Int {
    Int(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
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

  /// When the timer must next fire, from the registrations as they stand:
  /// the earliest deadline, even one already due — a zero-delay deadline, or
  /// whatever fell due while the scheduler was held — at the tightest slack
  /// among the clients sharing it. `plan` decides what a fire does; this
  /// decides when it happens.
  static func wakeup(clients: [ClientState]) -> (atMs: Int, leewayMs: Int)? {
    guard let at = clients.map(\.nextAtMs).min() else { return nil }
    let leeway =
      clients.filter { $0.nextAtMs == at }.map(\.priority.leewayMs).min()
      ?? Priority.normal.leewayMs
    return (at, leeway)
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
  private var gate = Gate()
  private let clock: () -> Int

  init(clock: @escaping () -> Int = PollScheduler.continuousNowMs) {
    self.clock = clock
  }

  /// Hold (or release) every registration for `reason`. Registrations keep
  /// changing while held; nothing fires. The release of the last reason runs
  /// each client whose deadline passed meanwhile exactly once — a repeating
  /// client then returns to its grid, a deadline registration is dropped.
  func setSuspended(_ suspended: Bool, reason: Suspension) {
    queue.async { [weak self] in
      guard let self else { return }
      switch self.gate.set(reason, active: suspended) {
      case .unchanged:
        return
      case .suspended:
        FlashLog.debug("[poll] suspended reason=\(reason)")
        self.timer?.cancel()
        self.timer = nil
        self.armedForMs = nil
      case .resumed:
        FlashLog.debug("[poll] resumed reason=\(reason)")
        self.rearm(now: self.clock())
      }
    }
  }

  /// Register (or re-register) `id` at `everyMs`. The handler runs on `queue`
  /// and must call nothing back into the scheduler synchronously. There is no
  /// default priority: every registration states how visible its lateness is.
  func register(
    _ id: String, everyMs: Int, priority: Priority, on handlerQueue: DispatchQueue,
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
    _ id: String, afterMs: Int, priority: Priority, on handlerQueue: DispatchQueue,
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
    guard !gate.isSuspended, let wakeup = Self.wakeup(clients: clients.values.map(\.state))
    else {
      timer?.cancel()
      timer = nil
      armedForMs = nil
      return
    }
    guard armedForMs != wakeup.atMs || timer == nil else { return }
    armedForMs = wakeup.atMs
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(max(0, wakeup.atMs - now)),
      leeway: .milliseconds(wakeup.leewayMs))
    timer.setEventHandler { [weak self] in self?.fire() }
    self.timer = timer
    timer.resume()
  }

  private func fire() {
    guard !gate.isSuspended else { return }
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

/// One re-armable deadline on the shared clock: a trailing debounce, a
/// retry or restart backoff, a grace period. `arm` replaces whatever is
/// pending — a fire already on its way to the handler queue is dropped as
/// stale — and `cancel` drops it. Use it only from the queue its handler runs
/// on; that confinement is what makes the generation check sound.
final class PollDeadline {
  let id: String
  let priority: PollScheduler.Priority
  private let queue: DispatchQueue
  private let scheduler: PollScheduler
  private var generation: UInt64 = 0
  private(set) var isArmed = false

  init(
    _ id: String, priority: PollScheduler.Priority, on queue: DispatchQueue,
    scheduler: PollScheduler = .shared
  ) {
    self.id = id
    self.priority = priority
    self.queue = queue
    self.scheduler = scheduler
  }

  /// `priority` overrides the deadline's own for this arming, for a backoff
  /// whose first step is visible and whose later ones are not.
  func arm(
    afterMs: Int, priority: PollScheduler.Priority? = nil, _ body: @escaping () -> Void
  ) {
    generation &+= 1
    let armed = generation
    isArmed = true
    scheduler.scheduleOnce(id, afterMs: afterMs, priority: priority ?? self.priority, on: queue) {
      [weak self] in
      guard let self, self.generation == armed else { return }
      self.isArmed = false
      body()
    }
  }

  func arm(
    after interval: TimeInterval, priority: PollScheduler.Priority? = nil,
    _ body: @escaping () -> Void
  ) {
    arm(afterMs: Int((max(0, interval) * 1000).rounded(.up)), priority: priority, body)
  }

  func cancel() {
    generation &+= 1
    guard isArmed else { return }
    isArmed = false
    scheduler.unregister(id)
  }

  deinit {
    if isArmed { scheduler.unregister(id) }
  }
}
