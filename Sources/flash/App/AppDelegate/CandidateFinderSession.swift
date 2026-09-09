import FlashCore
import Foundation

final class CandidateFinderSession {
  var indexGenerationCounter: UInt64 = 0
  var candidates: [Candidate] = [] {
    didSet {
      // Each flashlight session freezes one source snapshot. Bump the
      // epoch only when that snapshot's observable candidate identity
      // changes; selection movement and repeated renders should keep the
      // filter and incremental scoring caches intact.
      if Self.sameSourceRows(oldValue, candidates) {
        return
      }
      candidatesEpoch &+= 1
      filteredPoolCache = nil
      incrementalCache = nil
    }
  }

  /// Fast pool-equality probe for candidate-finder cache invalidation. It
  /// checks stable scalar identity only, avoiding attributed-display work while
  /// still noticing same-source tab/window rows whose titles or URLs changed.
  static func sameSourceRows(
    _ lhs: [Candidate],
    _ rhs: [Candidate]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for index in lhs.indices {
      let left = lhs[index]
      let right = rhs[index]
      if left.sourceID != right.sourceID
        || left.source != right.source
        || left.title != right.title
        || left.url?.absoluteString != right.url?.absoluteString
        || left.sourcePayload != right.sourcePayload
      {
        return false
      }
    }
    return true
  }
  /// Monotonic counter bumped on every `candidates`
  /// reassignment so the filtered-pool cache can detect a stale base
  /// without comparing 2k-entry arrays element-wise per keystroke.
  var candidatesEpoch: UInt64 = 0
  /// One-slot cache for the per-keystroke pool filter. While the user
  /// types into flashlight the base pool and selectors stay constant — so
  /// re-filtering 2k+ candidates on every keystroke is pure waste. The
  /// cache is invalidated whenever the underlying array or the filter
  /// signature differs from the prior key.
  var filteredPoolCache: (epoch: UInt64, signature: String, pool: [Candidate])?
  /// Frozen alongside `candidates` when a flashlight session
  /// opens. Source descriptors come from plugin manifests/native sources, so
  /// do that lookup once per session instead of rebuilding the table on every
  /// keystroke.
  var precedenceTable: CandidateFinder.PrecedenceTable = .default
  /// Session-local candidate normalization is CPU-only but can take tens of
  /// milliseconds for installed apps or the full emoji catalog. Keep that work
  /// off AppKit's main thread; generation checks still publish only the active
  /// session's immutable prepared arrays.
  let preparationQueue = DispatchQueue(
    label: "com.flash.candidate-preparation",
    qos: .userInitiated,
    attributes: .concurrent)
  /// Incremental-narrowing cache for fuzzy scoring. When the next query
  /// extends the previous one (`mo` → `mor` → `moria`), no candidate
  /// that failed `mo` can pass `mor`, so we only need to re-score the
  /// previous match set. Each keystroke narrows the candidate space and
  /// the scoring path gets faster as the user types. Invalidated when
  /// the pool epoch or attribute-filter signature change, since either
  /// shifts the candidate base.
  var incrementalCache:
    (normalizedQuery: String, matches: [CandidateMatch], epoch: UInt64, signature: String)?
  var matches: [CandidateMatch] = []
  var selectedIndex = 0
  /// Ephemeral answer rows returned by query evaluators for the exact current
  /// input. They are deliberately separate from the frozen catalog so they can
  /// occupy a fixed lane above fuzzy matches without polluting later queries.
  var queryAnswers: [Candidate] = []
  var queryEvaluationText = ""
  var liveQuery = CandidateLiveQuery<Candidate>() {
    didSet {
      guard oldValue.revision != liveQuery.revision else { return }
      candidatesEpoch &+= 1
      filteredPoolCache = nil
      incrementalCache = nil
    }
  }
  /// Independent from the flashlight-session generation: every bare query
  /// supersedes the prior evaluator fan-out even within one open surface.
  var queryEvaluationGeneration: UInt64 = 0
  /// The exact evaluator generation whose aggregate reply is still pending.
  /// Return/Tab/Cmd-Return use this to defer selection until the answer lane is
  /// final for the current input.
  var queryEvaluationInFlightGeneration: UInt64?
  /// A reply may have arrived while its answer rows are still waiting for the
  /// coalesced re-render. Keep submission gated until that render has actually
  /// rebuilt `matches`.
  var queryEvaluationSettledGeneration: UInt64?
  var currentQuery = ""
  var scope: CandidateScope = .all
  /// Bumped every time a flashlight session is (re)seeded. Plugin replies and
  /// the first-paint deadline capture this value so work from a closed or
  /// superseded session cannot publish a stale snapshot.
  var sessionGeneration: UInt64 = 0
  /// Initial location rows are collected behind a session-local fan-in barrier.
  /// The prompt renders while this exists, but the result list stays hidden
  /// until the barrier publishes one frozen snapshot.
  var initialBarrier: CandidateSnapshotBarrier?
  var initialDeadlineWork: DispatchWorkItem?
  /// Distinguishes a valid empty frozen snapshot from a session that has not
  /// started gathering yet.
  var initialSnapshotReady = false
  /// Return/Tab/Cmd-Return pressed during either the initial catalog gather or
  /// the at-most-50-ms query evaluator fan-in is replayed against the exact
  /// completed query generation.
  var submissionDeferral = CandidateSubmissionDeferral()
  /// Non-location plugin stores already pulled into this flashlight session.
  /// Track providers individually so an explicit `@emojis.glyphs` query does
  /// not deserialize every unrelated catalog, while a later `@notes.notes`
  /// query can still fetch its own provider.
  var fetchedNonLocationSourceIDs = Set<String>()
  /// Prepared opt-in replies that finished while the deterministic initial
  /// location snapshot was still being normalized. They are published with
  /// that first snapshot instead of being overwritten or causing an extra
  /// intermediate render.
  var deferredNonLocationSnapshots: [String: [Candidate]] = [:]
  /// Non-location sources remain lazy and may reply in a burst after the user
  /// explicitly selects one. Coalesce those opt-in updates within a runloop
  /// turn; the initial location snapshot never uses this incremental path.
  var mergeRerenderScheduled = false
}
