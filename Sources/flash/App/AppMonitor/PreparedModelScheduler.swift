import Foundation

/// Why a prepared hint model is rebuilt. The case decides throttling,
/// priority and speculation; `logValue` exists only for logs, so an AX event
/// storm no longer builds a reason string per notification.
enum ModelRefreshReason: Equatable {
  case activation
  case activationRetry
  case focus
  case config
  case space
  case screen
  case maintenance
  /// A rebuild requested while another one was running.
  case queued
  /// An Accessibility notification from the app, by name.
  case axEvent(String)
  /// A Flash action that changed the app (`normal_scroll`, …).
  case userAction(String)
  /// The walk a readiness ladder ends in, after a degenerate automatic walk
  /// of an app with a healthy history. Owed rather than speculative: event
  /// storms and slow-walk backoff do not suppress it.
  case readiness

  /// AX churn and queued follow-ups honor the minimum interval between walks.
  var isThrottled: Bool {
    switch self {
    case .axEvent, .queued: return true
    default: return false
    }
  }

  /// Rebuilds nobody is waiting on, paused while an app storms or walks slow.
  var isSpeculative: Bool { isThrottled || self == .maintenance }

  /// A pending refresh is never demoted to a lower-priority reason.
  var priority: Int {
    if isThrottled { return 0 }
    return self == .maintenance ? 1 : 2
  }

  var logValue: String {
    switch self {
    case .activation: return "activation"
    case .activationRetry: return "activation_retry"
    case .focus: return "focus"
    case .config: return "config"
    case .space: return "space"
    case .screen: return "screen"
    case .maintenance: return "maintenance"
    case .queued: return "queued"
    case .axEvent(let notification): return "ax:\(notification)"
    case .userAction(let action): return action
    case .readiness: return "readiness"
    }
  }
}

/// Main-thread scheduling state. Times are supplied by the caller so debounce,
/// preemption, cancellation, maintenance and readiness can be checked without
/// real timers.
struct PreparedModelScheduler {
  enum Request: Equatable {
    case refresh(ModelRefreshReason)
    case maintenance(dirtyToken: UInt64, configRevision: UInt64)
    /// One step of a readiness ladder (`ReadinessLadder`): probe the tree,
    /// then request a `then` refresh once it is ready or the ladder ends.
    case readiness(step: Int, then: ModelRefreshReason)
  }

  private enum Kind: Hashable, CaseIterable { case refresh, maintenance, readiness }
  private struct Key: Hashable {
    let pid: pid_t
    let kind: Kind
  }

  struct Ticket: Equatable {
    let pid: pid_t
    fileprivate let generation: UInt64
  }

  struct Arm: Equatable {
    let ticket: Ticket
    let deadline: UInt64
  }

  enum Wake: Equatable {
    case stale
    case wait(Arm)
    case fire(Request)
  }

  private struct Entry {
    let ticket: Ticket
    var deadline: UInt64
    var request: Request
  }

  private let debounceNs: UInt64
  private let minimumIntervalNs: UInt64
  private let defaultFreshnessNs: UInt64
  private let maintenanceLeadNs: UInt64
  private var generation: UInt64 = 0
  private var entries: [Key: Entry] = [:]
  private var lastStartedAt: [pid_t: UInt64] = [:]

  init(debounceMs: Int, minimumIntervalMs: Int, freshnessMs: Int, maintenanceLeadMs: Int) {
    debounceNs = UInt64(debounceMs) * 1_000_000
    minimumIntervalNs = UInt64(minimumIntervalMs) * 1_000_000
    defaultFreshnessNs = UInt64(freshnessMs) * 1_000_000
    maintenanceLeadNs = UInt64(maintenanceLeadMs) * 1_000_000
  }

  func hasRefresh(pid: pid_t) -> Bool {
    entries[Key(pid: pid, kind: .refresh)] != nil
  }

  /// A readiness step is armed or its probe is in flight.
  func hasReadiness(pid: pid_t) -> Bool {
    entries[Key(pid: pid, kind: .readiness)] != nil
  }

  mutating func scheduleRefresh(pid: pid_t, reason: ModelRefreshReason, now: UInt64) -> Arm? {
    let key = Key(pid: pid, kind: .refresh)
    var deadline = now + debounceNs
    if reason.isThrottled, let last = lastStartedAt[pid] {
      deadline = max(deadline, last + minimumIntervalNs)
    }
    if var existing = entries[key], case .refresh(let previousReason) = existing.request {
      // AX events may invalidate the model while a focus/config refresh is
      // pending, but must not demote that refresh into a throttled AX request.
      guard reason.priority >= previousReason.priority else {
        return nil
      }
      if deadline >= existing.deadline {
        existing.deadline = deadline
        existing.request = .refresh(reason)
        entries[key] = existing
        return nil
      }
      // An earlier deadline needs a new wake now. Its identity makes the
      // already-enqueued later callback harmless when it eventually arrives.
    }
    return replace(key: key, deadline: deadline, request: .refresh(reason))
  }

  /// Maintenance wakes `maintenanceLeadMs` before the model's own freshness
  /// ceiling (`freshnessNs`, defaulting to the configured base freshness).
  mutating func scheduleMaintenance(
    pid: pid_t, computedAt: UInt64, dirtyToken: UInt64, configRevision: UInt64,
    freshnessNs: UInt64? = nil
  ) -> Arm {
    let freshness = freshnessNs ?? defaultFreshnessNs
    let delay = freshness > maintenanceLeadNs ? freshness - maintenanceLeadNs : 0
    return replace(
      key: Key(pid: pid, kind: .maintenance),
      deadline: computedAt + delay,
      request: .maintenance(dirtyToken: dirtyToken, configRevision: configRevision))
  }

  /// A readiness step has its own ticket beside refresh and maintenance, so
  /// neither can consume it and it replaces only an earlier step.
  mutating func scheduleReadiness(
    pid: pid_t, step: Int, then: ModelRefreshReason, deadline: UInt64
  ) -> Arm {
    replace(
      key: Key(pid: pid, kind: .readiness), deadline: deadline,
      request: .readiness(step: step, then: then))
  }

  /// Claim the readiness slot while a fired step's probe runs off the main
  /// thread. The probe's verdict applies only if `releaseReadiness` still
  /// finds this hold: a newer ladder, a cancel or a reset revokes it. The
  /// hold never wakes on its own.
  mutating func holdReadiness(pid: pid_t, step: Int, then: ModelRefreshReason) -> Ticket {
    replace(
      key: Key(pid: pid, kind: .readiness), deadline: .max,
      request: .readiness(step: step, then: then)
    ).ticket
  }

  mutating func releaseReadiness(_ ticket: Ticket) -> Bool {
    let key = Key(pid: ticket.pid, kind: .readiness)
    guard entries[key]?.ticket == ticket else { return false }
    entries.removeValue(forKey: key)
    return true
  }

  mutating func cancelReadiness(pid: pid_t) {
    entries.removeValue(forKey: Key(pid: pid, kind: .readiness))
  }

  /// Focus moved to `pid`: every other app's ladder is moot.
  mutating func cancelReadiness(exceptPID pid: pid_t) {
    for key in Array(entries.keys) where key.kind == .readiness && key.pid != pid {
      entries.removeValue(forKey: key)
    }
  }

  mutating func wake(_ ticket: Ticket, now: UInt64) -> Wake {
    guard
      let key = Kind.allCases.lazy.map({ Key(pid: ticket.pid, kind: $0) })
        .first(where: { entries[$0]?.ticket == ticket }),
      let entry = entries[key]
    else { return .stale }
    guard now >= entry.deadline else {
      return .wait(Arm(ticket: ticket, deadline: entry.deadline))
    }
    entries.removeValue(forKey: key)
    return .fire(entry.request)
  }

  mutating func noteRefreshStarted(pid: pid_t, now: UInt64) {
    lastStartedAt[pid] = now
  }

  mutating func cancelRefresh(pid: pid_t) {
    entries.removeValue(forKey: Key(pid: pid, kind: .refresh))
  }

  mutating func cancelMaintenance(pid: pid_t) {
    entries.removeValue(forKey: Key(pid: pid, kind: .maintenance))
  }

  mutating func suppressSpeculativeRefresh(pid: pid_t) {
    let key = Key(pid: pid, kind: .refresh)
    if case .refresh(let reason) = entries[key]?.request, reason.isSpeculative {
      entries.removeValue(forKey: key)
    }
    cancelMaintenance(pid: pid)
  }

  mutating func reset(pid: pid_t) {
    cancelRefresh(pid: pid)
    cancelMaintenance(pid: pid)
    cancelReadiness(pid: pid)
    lastStartedAt.removeValue(forKey: pid)
  }

  mutating func reset() {
    entries.removeAll()
    lastStartedAt.removeAll()
  }

  private mutating func replace(key: Key, deadline: UInt64, request: Request) -> Arm {
    generation &+= 1
    let ticket = Ticket(pid: key.pid, generation: generation)
    entries[key] = Entry(ticket: ticket, deadline: deadline, request: request)
    return Arm(ticket: ticket, deadline: deadline)
  }
}
