/// Discovery may be replaced immediately. A pending commit may be cancelled
/// before input starts; an active gesture retains ownership until its mouse-up.
/// Only the latest replacement waits behind an active gesture.
struct ActivationLifecycle<Request> {
  enum Phase: Equatable {
    case idle
    case discovering(UInt64)
    case pendingCommit(UInt64)
    case committing(UInt64)
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

  mutating func prepareCommit() -> UInt64? {
    guard !isCommitting else { return nil }
    generation &+= 1
    phase = .pendingCommit(generation)
    return generation
  }

  mutating func startCommit(token: UInt64) -> Bool {
    guard phase == .pendingCommit(token), isCurrent(token) else { return false }
    phase = .committing(token)
    return true
  }

  mutating func completeCommit(token: UInt64) -> Completion? {
    guard phase == .committing(token) else { return nil }
    let result = Completion(applyOutcome: isCurrent(token), replacement: replacement)
    phase = .idle
    replacement = nil
    return result
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
