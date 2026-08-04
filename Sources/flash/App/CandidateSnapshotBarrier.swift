import FlashCore

/// Session-local fan-in for the flashlight's initial location snapshot.
///
/// The host does not retain plugin candidates between sessions. Each open
/// pulls every eligible default-location source — including `core.apps` and
/// plugin warm stores — in parallel, then publishes exactly one deterministic
/// snapshot when every source replies or the first-paint budget expires.
struct CandidateSnapshotBarrier {
  enum FinalizationReason: String {
    case allSourcesSettled = "all_sources_settled"
    case firstPaintBudget = "first_paint_budget"
  }

  enum RecordResult: Equatable {
    case accepted
    case duplicate
    case unknownSource
    case finalized
  }

  struct Reply {
    let sourceID: String
    let candidates: [Candidate]
    let latencyMs: Int
  }

  struct Snapshot {
    let generation: UInt64
    let reason: FinalizationReason
    let replies: [Reply]
    let missingSourceIDs: [String]

    var sourceLatencies: String {
      replies
        .map { "\($0.sourceID):\($0.latencyMs)" }
        .joined(separator: ",")
    }
  }

  let generation: UInt64
  let startedNs: UInt64
  private let orderedSourceIDs: [String]
  private var repliesBySourceID: [String: Reply] = [:]
  private var finalized = false

  init(
    generation: UInt64,
    startedNs: UInt64,
    expectedSourceIDs: [String]
  ) {
    self.generation = generation
    self.startedNs = startedNs
    self.orderedSourceIDs = Array(Set(expectedSourceIDs)).sorted()
  }

  var isSettled: Bool {
    repliesBySourceID.count == orderedSourceIDs.count
  }

  var expectedSourceCount: Int {
    orderedSourceIDs.count
  }

  var settledSourceCount: Int {
    repliesBySourceID.count
  }

  var pendingSourceIDs: [String] {
    orderedSourceIDs.filter { repliesBySourceID[$0] == nil }
  }

  mutating func record(
    sourceID: String,
    candidates: [Candidate],
    latencyMs: Int
  ) -> RecordResult {
    guard !finalized else { return .finalized }
    guard orderedSourceIDs.contains(sourceID) else { return .unknownSource }
    guard repliesBySourceID[sourceID] == nil else { return .duplicate }
    repliesBySourceID[sourceID] = Reply(
      sourceID: sourceID,
      candidates: candidates,
      latencyMs: latencyMs)
    return .accepted
  }

  mutating func finalize(reason: FinalizationReason) -> Snapshot? {
    guard !finalized else { return nil }
    finalized = true
    return Snapshot(
      generation: generation,
      reason: reason,
      replies: orderedSourceIDs.compactMap { repliesBySourceID[$0] },
      missingSourceIDs: pendingSourceIDs)
  }
}
