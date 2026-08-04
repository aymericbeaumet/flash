/// One user action held while the flashlight is still deciding what the first
/// row is. Initial catalog gathering and per-query evaluators are separate
/// barriers, but submission crosses them as one transaction: a Return/Tab
/// pressed for `1+1` must act on the eventual calculator answer, never on the
/// fuzzy row that happened to be selected before the answer arrived.
struct CandidateSubmissionDeferral {
  struct Action: Equatable {
    let submit: Bool
    let allowFinisher: Bool
    let submitFinalDestinations: Bool
  }

  enum Resolution: Equatable {
    case none
    case waiting
    case replay(Action)
    case discarded
  }

  private struct Pending {
    let action: Action
    let sessionGeneration: UInt64
    let query: String
    /// Nil while waiting for the initial catalog snapshot. Once that barrier
    /// settles, the action binds to the exact evaluator generation started by
    /// the resulting re-render.
    var evaluationGeneration: UInt64?
  }

  private var pending: Pending?

  var hasPendingAction: Bool { pending != nil }

  mutating func deferAction(
    _ action: Action,
    sessionGeneration: UInt64,
    query: String,
    evaluationGeneration: UInt64?
  ) {
    pending = Pending(
      action: action,
      sessionGeneration: sessionGeneration,
      query: query,
      evaluationGeneration: evaluationGeneration)
  }

  mutating func resolve(
    sessionGeneration: UInt64,
    query: String,
    currentEvaluationGeneration: UInt64,
    initialSnapshotPending: Bool,
    evaluationInFlightGeneration: UInt64?
  ) -> Resolution {
    guard var pending else { return .none }
    guard
      pending.sessionGeneration == sessionGeneration,
      pending.query == query
    else {
      self.pending = nil
      return .discarded
    }
    if let expected = pending.evaluationGeneration,
      expected != currentEvaluationGeneration
    {
      self.pending = nil
      return .discarded
    }
    if initialSnapshotPending {
      return .waiting
    }
    if let inFlight = evaluationInFlightGeneration {
      if let expected = pending.evaluationGeneration, expected != inFlight {
        self.pending = nil
        return .discarded
      }
      pending.evaluationGeneration = inFlight
      self.pending = pending
      return .waiting
    }
    self.pending = nil
    return .replay(pending.action)
  }

  mutating func cancel() {
    pending = nil
  }
}
