import Foundation

/// Main-thread scheduling state. Times are supplied by the caller so debounce,
/// preemption, cancellation, and maintenance can be checked without real timers.
struct PreparedModelScheduler {
  enum Request: Equatable {
    case refresh(String)
    case maintenance(dirtyToken: UInt64, configRevision: UInt64)
  }

  private enum Kind: Hashable { case refresh, maintenance }
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

  static func isSpeculative(reason: String) -> Bool {
    shouldThrottle(reason: reason) || reason == "maintenance"
  }

  static func shouldThrottle(reason: String) -> Bool {
    reason.hasPrefix("ax:") || reason == "queued"
  }

  private static func priority(reason: String) -> Int {
    if shouldThrottle(reason: reason) { return 0 }
    return reason == "maintenance" ? 1 : 2
  }

  func hasRefresh(pid: pid_t) -> Bool {
    entries[Key(pid: pid, kind: .refresh)] != nil
  }

  mutating func scheduleRefresh(pid: pid_t, reason: String, now: UInt64) -> Arm? {
    let key = Key(pid: pid, kind: .refresh)
    var deadline = now + debounceNs
    if Self.shouldThrottle(reason: reason), let last = lastStartedAt[pid] {
      deadline = max(deadline, last + minimumIntervalNs)
    }
    if var existing = entries[key], case .refresh(let previousReason) = existing.request {
      // AX events may invalidate the model while a focus/config refresh is
      // pending, but must not demote that refresh into a throttled AX request.
      guard Self.priority(reason: reason) >= Self.priority(reason: previousReason) else {
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

  mutating func wake(_ ticket: Ticket, now: UInt64) -> Wake {
    let refreshKey = Key(pid: ticket.pid, kind: .refresh)
    let maintenanceKey = Key(pid: ticket.pid, kind: .maintenance)
    let key = entries[refreshKey]?.ticket == ticket ? refreshKey : maintenanceKey
    guard let entry = entries[key], entry.ticket == ticket else { return .stale }
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
    if case .refresh(let reason) = entries[key]?.request, Self.isSpeculative(reason: reason) {
      entries.removeValue(forKey: key)
    }
    cancelMaintenance(pid: pid)
  }

  mutating func reset(pid: pid_t) {
    cancelRefresh(pid: pid)
    cancelMaintenance(pid: pid)
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
