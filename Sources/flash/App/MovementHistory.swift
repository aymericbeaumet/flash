import FlashCore
import Foundation

/// One stop of the movement history: an app, a source's candidate, or the
/// route a performed switch named.
struct MovementEntry {
  enum Kind {
    case app
    case candidate
    case route
  }

  var kind: Kind
  var key: String
  var pid: pid_t?
  var candidate: Candidate?
  var navigationURL: URL?

  static func app(pid: pid_t) -> MovementEntry {
    MovementEntry(kind: .app, key: "app:\(pid)", pid: pid, candidate: nil, navigationURL: nil)
  }

  static func candidate(_ candidate: Candidate) -> MovementEntry {
    let target =
      candidate.navigationURL?.absoluteString
      ?? candidate.url?.absoluteString
      ?? candidate.sourcePayload
      ?? candidate.title
    return MovementEntry(
      kind: .candidate,
      key: "candidate:\(candidate.sourceID):\(candidate.pid ?? 0):\(target)",
      pid: candidate.pid,
      candidate: candidate,
      navigationURL: candidate.navigationURL)
  }

  static func route(_ url: URL, pid: pid_t?) -> MovementEntry {
    MovementEntry(
      kind: .route,
      key: "route:\(url.absoluteString)",
      pid: pid,
      candidate: nil,
      navigationURL: url)
  }

  /// An app as a whole, however it was observed.
  var isApp: Bool { kind == .app || candidate?.kind == .app }
}

/// The place an entry names. Two entries with one identity are one stop; an
/// entry with none (its app quit, its source is gone) cannot be restored.
struct MovementIdentity: Equatable {
  var key: String
}

/// The stops behind `movement back` / `movement forward`. Pure value state:
/// where the user is, the stops before it (`back`, oldest first), the stops a
/// navigation stepped past (`forward`, nearest last), and `settlingKey`, the
/// stop a performed switch or a restore is landing on. What an entry names
/// depends on the running apps and the registered sources, so every
/// transition takes the caller's `Identify`.
struct MovementHistory {
  typealias Identify = (MovementEntry) -> MovementIdentity?

  /// Each stack keeps its most recent stops.
  static let depth = 20

  private(set) var current: MovementEntry?
  private(set) var back: [MovementEntry] = []
  private(set) var forward: [MovementEntry] = []
  /// While set, an ambient observation naming another place is the location
  /// the switch left, not a stop: see `record`.
  private(set) var settlingKey: String?
  /// The selected locations the last catalog publication named, per app.
  private var selection: (pid: pid_t, keys: Set<String>)?

  init(
    current: MovementEntry? = nil, back: [MovementEntry] = [], forward: [MovementEntry] = [],
    settlingKey: String? = nil
  ) {
    self.current = current
    self.back = back
    self.forward = forward
    self.settlingKey = settlingKey
  }

  var isSettling: Bool { settlingKey != nil }

  /// What `record` did with an entry.
  enum Recorded: Equatable {
    /// The entry names nothing restorable; the history is unchanged.
    case unidentified
    /// An ambient observation of the place a settling switch left.
    case dropped
    /// The settling stop was observed.
    case arrived(key: String)
    /// The current stop again, with fresher detail.
    case coalesced(key: String)
    /// An app and one of its own locations: one activation, one stop.
    case coalescedActivation(key: String)
    /// A new stop; the previous one went onto `back`.
    case stop(key: String)
  }

  /// The user is at `entry`. An ambient record is an observation (a catalog
  /// publication, a settled focus change); any other is a move the user
  /// made, which ends whatever was settling and drops the forward stack when
  /// it names a new place.
  @discardableResult
  mutating func record(_ entry: MovementEntry, isAmbient: Bool, identify: Identify) -> Recorded {
    guard let identity = identify(entry) else { return .unidentified }
    if isAmbient, let target = settlingKey, target != identity.key {
      guard let current, current.isApp, current.pid != nil, current.pid == entry.pid else {
        return .dropped
      }
    }
    if !isAmbient { settlingKey = nil }
    if settlingKey == identity.key {
      settlingKey = nil
      current = entry
      prune(identify: identify)
      return .arrived(key: identity.key)
    }
    if let current, let currentIdentity = identify(current), currentIdentity.key == identity.key {
      self.current = entry
      settlingKey = nil
      prune(identify: identify)
      return .coalesced(key: identity.key)
    }
    if let current, Self.shareActivation(current, entry) {
      if current.isApp { self.current = entry }
      settlingKey = nil
      prune(identify: identify)
      return .coalescedActivation(key: identity.key)
    }
    if let current { Self.append(current, to: &back, identify: identify) }
    current = entry
    forward.removeAll(keepingCapacity: true)
    prune(identify: identify)
    return .stop(key: identity.key)
  }

  /// A source performed the switch to `entry`, already recorded: observations
  /// naming another place are dropped until one names it.
  mutating func settle(on entry: MovementEntry, identify: Identify) {
    guard let identity = identify(entry) else { return }
    settlingKey = identity.key
  }

  /// The switch being settled failed, or nothing will observe its landing.
  mutating func stopSettling() {
    settlingKey = nil
  }

  /// A restore landed on `entry`, which the next observation should name.
  mutating func arrive(at entry: MovementEntry, identify: Identify) {
    current = entry
    settlingKey = identify(entry)?.key
  }

  /// The current stop resolved to `entry`, a more precise name for it.
  mutating func refine(current entry: MovementEntry, identify: Identify) {
    current = entry
    prune(identify: identify)
  }

  /// Step to the nearest restorable stop in `direction`, leaving it settling.
  /// `origin` is where the user is now, recorded first so the step can be
  /// undone. Stops that no longer name anything, or that name the current
  /// place, are discarded on the way. Nil when no stop is left.
  mutating func take(
    _ direction: AppDelegate.NavigationDirection, from origin: MovementEntry?, identify: Identify
  ) -> MovementEntry? {
    if let origin { record(origin, isAmbient: true, identify: identify) }
    let current = self.current
    var source = direction == .back ? back : forward
    var destination = direction == .back ? forward : back
    defer {
      back = direction == .back ? source : destination
      forward = direction == .back ? destination : source
    }

    while let target = source.popLast() {
      guard let targetIdentity = identify(target) else { continue }
      if let current {
        let currentIdentity = identify(current)
        if currentIdentity == targetIdentity { continue }
        if currentIdentity != nil { Self.append(current, to: &destination, identify: identify) }
      }
      self.current = target
      settlingKey = targetIdentity.key
      return target
    }
    source.removeAll { identify($0) == nil }
    destination.removeAll { identify($0) == nil }
    return nil
  }

  /// Drop the stops that no longer name anything.
  mutating func prune(identify: Identify) {
    back.removeAll { identify($0) == nil }
    forward.removeAll { identify($0) == nil }
  }

  /// How an app's selected locations changed with a catalog publication.
  enum SelectionChange: Equatable {
    /// The same selection as last time: nothing to record.
    case unchanged
    /// The one location that became selected, or the only one selected.
    case selected(key: String)
    /// Several candidates and no single newcomer.
    case ambiguous
  }

  /// Only a changed selection can add a stop; any other publication would
  /// replay an old selected tab while a direct navigation is settling.
  mutating func noteSelection(_ keys: Set<String>, pid: pid_t) -> SelectionChange {
    let previous = selection.flatMap { $0.pid == pid ? $0.keys : nil }
    guard previous != keys else { return .unchanged }
    selection = (pid, keys)
    let added = keys.subtracting(previous ?? [])
    if added.count == 1, let key = added.first { return .selected(key: key) }
    if keys.count == 1, let key = keys.first { return .selected(key: key) }
    return .ambiguous
  }

  private static func append(
    _ entry: MovementEntry, to stack: inout [MovementEntry], identify: Identify
  ) {
    guard let identity = identify(entry) else { return }
    if let last = stack.last, identify(last) == identity { return }
    stack.append(entry)
    if stack.count > depth {
      stack.removeFirst(stack.count - depth)
    }
  }

  private static func shareActivation(_ current: MovementEntry, _ next: MovementEntry) -> Bool {
    (current.isApp || next.isApp) && current.pid != nil && current.pid == next.pid
  }
}
