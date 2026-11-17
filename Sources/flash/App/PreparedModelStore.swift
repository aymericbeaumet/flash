import Darwin
import FlashCore
import Foundation

struct PreparedModel {
  let pid: pid_t
  let targets: [JumpTarget]
  let hints: [AssignedHint]
  let computedAt: DispatchTime
  let dirtyToken: UInt64
  let configRevision: UInt64
  /// Geometry/role digest of `targets`; equal digests across consecutive
  /// maintenance walks are the evidence that lets the freshness ceiling grow.
  let fingerprint: Int
  /// How long this model may be served without a refresh: the app's
  /// maintenance interval when it was walked (`AppMonitor.modelIntervalMs`).
  /// It starts at `AppMonitor.modelFreshnessMs` and doubles (to
  /// `modelFreshnessMaxMs`) for every maintenance walk that reproduces the
  /// previous model unchanged, so a static focused app is re-walked seconds
  /// apart instead of every 1.3 s, and for every walk slow enough to cost a
  /// tenth of a core at the current interval (`nextModelIntervalMs`).
  var freshnessMs: Int
  /// The walk found no visible region for the focused window: something
  /// covered all of it, or nothing of it was on screen. Such a model is never
  /// stored (`PreparedModelStore.store`).
  let occluded: Bool
  /// What covered the window when it was walked; a lookup must see the same.
  /// Nil when the walk had no window list, and then never served.
  let occlusion: WindowSnapshot.OcclusionSignature?

  var isEmptyReady: Bool { hints.isEmpty }
}

/// Why an activation could not be served from the prepared model, logged as
/// `miss_reason=` in `[latency] hints_visible` (see docs/performance.md).
enum PreparedModelMiss: String, Equatable {
  /// The app was never walked since it was stored, or the store was cleared.
  case absent
  /// A focus change discarded the model and its focus walk has not landed.
  case focus
  /// An AX event or a Flash action moved the dirty token since the walk.
  case invalidated
  /// The configuration changed since the walk.
  case config
  /// The window list no longer matches what the walk saw: the window was
  /// covered, uncovered, or had no window list at all.
  case occluded
  /// Older than its freshness window; maintenance did not replace it.
  case expired
  /// Current, but empty or collapsed against the app's healthy count.
  case degenerate
  /// No model because Flash chose not to warm the app: an AX event storm, the
  /// empty-walk gate or an on-demand declaration.
  case suppressed
  /// A volatile provider (tmux) owned the hints; the model was not consulted.
  case provider
}

struct PreparedModelStore {
  struct RebuildTicket: Equatable {
    let pid: pid_t
    fileprivate let generation: UInt64
  }

  /// What a lookup found: the model, or why there is none to serve.
  enum Resolution {
    case model(PreparedModel)
    case miss(PreparedModelMiss)

    var model: PreparedModel? {
      if case .model(let model) = self { return model }
      return nil
    }

    var miss: PreparedModelMiss? {
      if case .miss(let miss) = self { return miss }
      return nil
    }
  }

  private var models: [pid_t: PreparedModel] = [:]
  /// Why an app has no model, from the discard that removed it, so a later
  /// lookup can say so; a stored model clears it.
  private var absences: [pid_t: PreparedModelMiss] = [:]
  private var rebuilding: [pid_t: RebuildTicket] = [:]
  private var queuedAfterRebuild: Set<pid_t> = []
  private var rebuildGeneration: UInt64 = 0

  /// Store a completed walk's model. An occluded one is not stored, and it
  /// evicts the current model: whether the window is covered is window-list
  /// state no AX event reports, so nothing would invalidate the empty model
  /// once the covering window left, and a model walked before the window was
  /// covered no longer describes the screen. The next activation walks.
  @discardableResult
  mutating func store(_ model: PreparedModel) -> Bool {
    guard !model.occluded else {
      models.removeValue(forKey: model.pid)
      absences[model.pid] = .occluded
      return false
    }
    models[model.pid] = model
    absences.removeValue(forKey: model.pid)
    return true
  }

  /// Drop `pid`'s model, remembering why for the next lookup.
  mutating func discardModel(pid: pid_t, because miss: PreparedModelMiss) {
    models.removeValue(forKey: pid)
    absences[pid] = miss
  }

  mutating func remove(pid: pid_t) {
    models.removeValue(forKey: pid)
    absences.removeValue(forKey: pid)
    rebuilding.removeValue(forKey: pid)
    queuedAfterRebuild.remove(pid)
  }

  mutating func removeAll() {
    models.removeAll()
    absences.removeAll()
    rebuilding.removeAll()
    queuedAfterRebuild.removeAll()
  }

  func current(pid: pid_t) -> PreparedModel? {
    models[pid]
  }

  /// `occlusion` is what covers the window now; a model walked under
  /// another cover is a miss.
  func lookup(
    pid: pid_t,
    dirtyToken: UInt64,
    configRevision: UInt64,
    now: DispatchTime,
    occlusion: WindowSnapshot.OcclusionSignature?
  ) -> PreparedModel? {
    resolve(
      pid: pid, dirtyToken: dirtyToken, configRevision: configRevision, now: now,
      occlusion: occlusion
    ).model
  }

  /// The model for `pid` if it is still current, else why it is not. The
  /// checks run in the order the causes arise: no model, then the identities
  /// the walk captured (dirty token, configuration, visible region), then
  /// age.
  func resolve(
    pid: pid_t,
    dirtyToken: UInt64,
    configRevision: UInt64,
    now: DispatchTime,
    occlusion: WindowSnapshot.OcclusionSignature?
  ) -> Resolution {
    guard let model = models[pid] else { return .miss(absences[pid] ?? .absent) }
    guard model.dirtyToken == dirtyToken else { return .miss(.invalidated) }
    guard model.configRevision == configRevision else { return .miss(.config) }
    guard let walked = model.occlusion, walked == occlusion else { return .miss(.occluded) }
    let ageNs = now.uptimeNanoseconds - model.computedAt.uptimeNanoseconds
    let ageMs = Double(ageNs) / 1_000_000
    guard ageMs <= Double(model.freshnessMs) else { return .miss(.expired) }
    return .model(model)
  }

  mutating func beginRebuild(pid: pid_t) -> RebuildTicket? {
    if rebuilding[pid] != nil {
      queuedAfterRebuild.insert(pid)
      return nil
    }
    rebuildGeneration &+= 1
    let ticket = RebuildTicket(pid: pid, generation: rebuildGeneration)
    rebuilding[pid] = ticket
    return ticket
  }

  /// Nil rejects an obsolete completion before it can consume a successor's
  /// waiter, publish a model or re-arm refresh work. False is a current walk
  /// that completed without a queued refresh.
  mutating func finishRebuild(_ ticket: RebuildTicket) -> Bool? {
    guard rebuilding[ticket.pid] == ticket else { return nil }
    rebuilding.removeValue(forKey: ticket.pid)
    return queuedAfterRebuild.remove(ticket.pid) != nil
  }

  func isRebuilding(pid: pid_t) -> Bool {
    rebuilding[pid] != nil
  }
}
