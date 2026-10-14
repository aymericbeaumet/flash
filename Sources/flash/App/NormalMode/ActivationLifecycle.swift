import Foundation

/// Discovery may be replaced immediately. A pending commit may be cancelled
/// before input starts; an active gesture retains ownership until its mouse-up.
/// Only the latest replacement waits behind an active gesture.
///
/// A commit that raises its target app carries that app's pid as its
/// `handoff`: the activation it then waits for is part of the commit, not a
/// reason to cancel it. `isHandoff` tells the dismissal observers apart.
struct ActivationLifecycle<Request> {
  enum Phase: Equatable {
    case idle
    case discovering(UInt64)
    case pendingCommit(UInt64, handoff: pid_t?)
    case committing(UInt64, handoff: pid_t?)
  }

  /// What a dismissal observer saw: the workspace activating `pid`, or focus
  /// leaving Flash with no app named (a Space change, the panel resigning
  /// key).
  enum Departure: Equatable {
    case activated(pid_t)
    case focusLost
  }

  struct Completion {
    let applyOutcome: Bool
    let replacement: Request?
  }

  private(set) var generation: UInt64 = 0
  private(set) var phase: Phase = .idle
  private var replacement: Request?

  var inFlight: Bool { phase != .idle }
  var isCommitting: Bool {
    if case .committing = phase { return true }
    return false
  }

  /// Returns false when the request must wait for owned input to finish.
  mutating func requestReplacement(_ request: Request) -> Bool {
    if isCommitting {
      generation &+= 1
      replacement = request
      return false
    }
    invalidate()
    return true
  }

  mutating func begin() -> UInt64 {
    precondition(!isCommitting)
    generation &+= 1
    phase = .discovering(generation)
    return generation
  }

  @discardableResult
  mutating func complete(token: UInt64) -> Bool {
    guard phase == .discovering(token), isCurrent(token) else { return false }
    phase = .idle
    return true
  }

  /// `handoffTo` names the app the commit raises and waits for before it
  /// posts; nil when the target is already frontmost or never activates.
  mutating func prepareCommit(handoffTo pid: pid_t? = nil) -> UInt64? {
    guard !isCommitting else { return nil }
    generation &+= 1
    phase = .pendingCommit(generation, handoff: pid)
    return generation
  }

  mutating func startCommit(token: UInt64) -> Bool {
    guard case .pendingCommit(token, let handoff) = phase, isCurrent(token) else { return false }
    phase = .committing(token, handoff: handoff)
    return true
  }

  mutating func completeCommit(token: UInt64) -> Completion? {
    guard case .committing(token, _) = phase else { return nil }
    let result = Completion(applyOutcome: isCurrent(token), replacement: replacement)
    phase = .idle
    replacement = nil
    return result
  }

  /// Whether `departure` is the handoff the current commit is waiting on —
  /// its target coming forward, or the focus loss that raise causes — rather
  /// than the user leaving. True only for a current commit with a handoff:
  /// activating any other app, a superseded commit and discovery all cancel.
  func isHandoff(_ departure: Departure) -> Bool {
    let (token, handoff): (UInt64, pid_t?)
    switch phase {
    case .pendingCommit(let current, let pid), .committing(let current, let pid):
      (token, handoff) = (current, pid)
    case .idle, .discovering:
      return false
    }
    guard let handoff, isCurrent(token) else { return false }
    switch departure {
    case .activated(let pid): return pid == handoff
    case .focusLost: return true
    }
  }

  /// Cancellation suppresses outcomes immediately, but cannot forget a gesture
  /// which still owes the target its release event.
  mutating func invalidate() {
    generation &+= 1
    replacement = nil
    if !isCommitting { phase = .idle }
  }

  func isCurrent(_ token: UInt64) -> Bool { generation == token }
}
