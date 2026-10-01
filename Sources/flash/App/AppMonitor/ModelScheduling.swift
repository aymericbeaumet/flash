import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// Prepared-model refresh scheduling: debounce, coalesce, maintenance
/// pre-fire, and the actual background walk that produces a fresh
/// `PreparedModel` from the focused-app context.
extension AppMonitor {
  // MARK: Prepared model scheduling

  func invalidatePreparedModel(for pid: pid_t) {
    preparedModels.discardModel(pid: pid)
    cancelMaintenance(pid: pid)
  }

  /// Revoke `pid`'s maintenance ticket and release its wake on the shared
  /// clock, so a cancelled maintenance costs no wake-up.
  func cancelMaintenance(pid: pid_t) {
    modelScheduler.cancelMaintenance(pid: pid)
    releaseMaintenanceWake(pid: pid)
  }

  private func releaseMaintenanceWake(pid: pid_t?) {
    guard let pending = maintenanceWakePID, pid == nil || pid == pending else { return }
    maintenanceWakePID = nil
    pollScheduler.unregister(Self.maintenanceClientID)
  }

  /// Release `pid`'s debounce and readiness wakes (every app's when nil), so
  /// cancelled refresh work costs no wake-up.
  private func releaseRefreshWakes(pid: pid_t?) {
    let released = refreshWakeClientIDs.filter { id in
      pid.map { id.hasSuffix(":\($0)") } ?? true
    }
    refreshWakeClientIDs.subtract(released)
    for id in released { pollScheduler.unregister(id) }
  }

  func cancelRefreshWork(for pid: pid_t) {
    modelScheduler.reset(pid: pid)
    releaseMaintenanceWake(pid: pid)
    releaseRefreshWakes(pid: pid)
    pendingModelCompletion.removeValue(forKey: pid)
    slowAutomaticModelRefreshPIDs.remove(pid)
    readinessRewalkBudget.removeValue(forKey: pid)
  }

  func cancelAllRefreshWork() {
    modelScheduler.reset()
    releaseMaintenanceWake(pid: nil)
    releaseRefreshWakes(pid: nil)
    pendingModelCompletion.removeAll()
    slowAutomaticModelRefreshPIDs.removeAll()
    readinessRewalkBudget.removeAll()
  }

  /// A gated app gets no automatic walk at all. Otherwise speculative walks
  /// pause while the app storms, walks slow, or has a readiness ladder
  /// pending: that ladder owes the app a walk once its tree is ready, and a
  /// speculative walk before then reads the tree it is waiting for.
  private func allowsAutomaticRefresh(pid: pid_t, reason: ModelRefreshReason) -> Bool {
    guard !backgroundWalkGate.isGated(pid) else { return false }
    guard reason.isSpeculative else { return true }
    return !axEventStormingPIDs.contains(pid) && !slowAutomaticModelRefreshPIDs.contains(pid)
      && !modelScheduler.hasReadiness(pid: pid)
  }

  /// New events extend one debounce wake per burst. Higher-priority requests
  /// can move it earlier; an obsolete callback never owns the replacement.
  func scheduleModelRefresh(for pid: pid_t, reason: ModelRefreshReason) {
    guard allowsAutomaticRefresh(pid: pid, reason: reason),
      let arm = modelScheduler.scheduleRefresh(
        pid: pid, reason: reason, now: DispatchTime.now().uptimeNanoseconds)
    else { return }
    armRefreshTimer(arm)
  }

  func suppressScheduledBackgroundModelRefresh(for pid: pid_t) {
    modelScheduler.suppressSpeculativeRefresh(pid: pid)
    releaseMaintenanceWake(pid: pid)
  }

  /// The focus change's walk. A runtime that builds its tree asynchronously
  /// was just woken (`onFocusedAppChanged`); its walk waits on the readiness
  /// ladder instead of reading a tree still being built. Activation never
  /// waits on this ladder: it walks on demand and cancels it.
  func scheduleFocusModelRefresh(for pid: pid_t, bundleIdentifier: String?) {
    guard allowsAutomaticRefresh(pid: pid, reason: .focus),
      Self.focusRefreshAwaitsReadiness(
        traits: AppTraits.cached(bundleIdentifier: bundleIdentifier),
        onDemand: OnDemandHintApps.contains(bundleIdentifier))
    else {
      scheduleModelRefresh(for: pid, reason: .focus)
      return
    }
    // A request already pending would walk before the tree is ready; the
    // ladder ends in the focus walk.
    modelScheduler.cancelRefresh(pid: pid)
    armReadinessStep(pid: pid, step: 0, then: .focus)
  }

  /// Arm step `step` of a readiness ladder; past its end, request the walk.
  func armReadinessStep(pid: pid_t, step: Int, then: ModelRefreshReason) {
    guard let delayMs = ReadinessLadder.delayMs(step: step) else {
      scheduleModelRefresh(for: pid, reason: then)
      return
    }
    armRefreshTimer(
      modelScheduler.scheduleReadiness(
        pid: pid, step: step, then: then,
        deadline: DispatchTime.now().uptimeNanoseconds + UInt64(delayMs) * 1_000_000))
  }

  /// A readiness step fired: probe the tree on the AX queue and request the
  /// walk once it is ready, or climb to the next step. The last step, and an
  /// app that builds its tree on demand, request the walk without probing.
  /// The probe's verdict applies only while its hold survives: focus moving
  /// away, an activation walk, termination or a newer ladder revoke it.
  private func runReadinessStep(pid: pid_t, step: Int, then: ModelRefreshReason) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      !backgroundWalkGate.isGated(pid),
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
    else { return }
    let bundleIdentifier = app.bundleIdentifier
    guard ReadinessLadder.probesBeforeWalking(step: step),
      AppTraits.cached(bundleIdentifier: bundleIdentifier)?.buildsAccessibilityTreeAsynchronously
        == true
    else {
      scheduleModelRefresh(for: pid, reason: then)
      return
    }
    let hold = modelScheduler.holdReadiness(pid: pid, step: step, then: then)
    axQueue.async { [weak self] in
      let ready = AccessibilityReadiness.probe(pid: pid, bundleIdentifier: bundleIdentifier)
      DispatchQueue.main.async {
        guard let self, self.modelScheduler.releaseReadiness(hold),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        guard ready else {
          self.armReadinessStep(pid: pid, step: step + 1, then: then)
          return
        }
        FlashLog.debug(
          "[ax] readiness_ready",
          fields: [
            "pid": "\(pid)", "bundle": bundleIdentifier ?? "", "step": "\(step)",
            "reason": then.logValue,
          ])
        self.scheduleModelRefresh(for: pid, reason: then)
      }
    }
  }

  /// A background walk of an app with a healthy history came back
  /// degenerate: its tree was caught mid-build (Chromium after a focus
  /// change, Gecko reloading a page). Walk it again once it is ready, at most
  /// `backgroundReadinessRewalksPerFocus` times per focus.
  private func scheduleReadinessRewalk(
    pid: pid_t, bundleIdentifier: String, after reason: ModelRefreshReason, targets: Int,
    lastHealthy: Int
  ) {
    guard !backgroundWalkGate.isGated(pid), !modelScheduler.hasReadiness(pid: pid) else { return }
    let remaining = readinessRewalkBudget[pid, default: Self.backgroundReadinessRewalksPerFocus]
    guard remaining > 0 else { return }
    readinessRewalkBudget[pid] = remaining - 1
    FlashLog.debug(
      "[ax] readiness_rewalk",
      fields: [
        "pid": "\(pid)", "bundle": bundleIdentifier, "after": reason.logValue,
        "targets": "\(targets)", "last_healthy": "\(lastHealthy)",
        "remaining": "\(remaining - 1)",
      ])
    armReadinessStep(pid: pid, step: 0, then: .readiness)
  }

  /// Bookkeeping for one completed automatic walk: the slow-walk backoff and
  /// the empty-walk gate. A degenerate walk is fast because there was nothing
  /// to read, not because the app is cheap, so it never lifts the backoff.
  private func noteAutomaticWalk(
    pid: pid_t, bundleIdentifier: String, reason: ModelRefreshReason, elapsedMs: Double,
    targets: Int, degenerate: Bool, hasVolatileProvider: Bool, stillFocused: Bool
  ) {
    let wasSlow = slowAutomaticModelRefreshPIDs.contains(pid)
    if Self.automaticModelRefreshIsSlow(elapsedMs: elapsedMs) {
      slowAutomaticModelRefreshPIDs.insert(pid)
      suppressScheduledBackgroundModelRefresh(for: pid)
      if !wasSlow {
        FlashLog.debug(
          "[ax] model_refresh_backoff",
          fields: [
            "pid": "\(pid)",
            "bundle": bundleIdentifier,
            "reason": reason.logValue,
            "elapsed_ms": String(format: "%.2f", elapsedMs),
          ])
      }
    } else if !degenerate {
      slowAutomaticModelRefreshPIDs.remove(pid)
    }
    guard stillFocused,
      backgroundWalkGate.noteBackgroundWalk(
        pid: pid, targets: targets, hasVolatileProvider: hasVolatileProvider)
    else { return }
    modelScheduler.cancelRefresh(pid: pid)
    cancelMaintenance(pid: pid)
    modelScheduler.cancelReadiness(pid: pid)
    FlashLog.info(
      "[ax] model_refresh_gated pid=\(pid) bundle=\(bundleIdentifier) "
        + "empty_walks=\(EmptyBackgroundWalkGate.threshold) reason=volatile_provider")
  }

  /// One registration per app and kind: a newer arm of the same slot
  /// replaces the pending wake instead of stacking a stale one behind it.
  static func refreshWakeClientID(_ arm: PreparedModelScheduler.Arm) -> String {
    "core:prepared_model_\(arm.kind.rawValue):\(arm.ticket.pid)"
  }

  /// Milliseconds from now until an uptime deadline, rounded up so a wake
  /// never lands before the deadline it serves.
  static func delayMs(untilUptime deadline: UInt64) -> Int {
    let now = DispatchTime.now().uptimeNanoseconds
    return deadline > now ? Int((deadline - now + 999_999) / 1_000_000) : 0
  }

  /// Debounce and readiness wakes re-arm themselves — an event extends the
  /// debounce, a readiness step arms the next — so they ride the shared clock
  /// as deadline registrations, coalescing with every other wake-up and held
  /// while the displays sleep or the session is locked. `.normal`: they warm
  /// a model ahead of an activation nobody has asked for yet; an activation
  /// that arrives first walks on demand instead of waiting for them.
  private func armRefreshTimer(_ arm: PreparedModelScheduler.Arm) {
    let id = Self.refreshWakeClientID(arm)
    refreshWakeClientIDs.insert(id)
    pollScheduler.scheduleOnce(
      id, afterMs: Self.delayMs(untilUptime: arm.deadline), priority: .normal, on: .main
    ) { [weak self] in
      guard let self else { return }
      self.refreshWakeClientIDs.remove(id)
      self.wakeRefreshTimer(arm, rearm: { $0.armRefreshTimer($1) })
    }
  }

  static let maintenanceClientID = "core:prepared_model_maintenance"

  /// Maintenance is the one self-renewing wake: every stored model arms the
  /// next, ahead of its freshness ceiling (AOT: an activation served from a
  /// warm model only draws). It rides the shared clock as a deadline
  /// registration, so it coalesces with every other wake-up and is held
  /// while the displays sleep or the session is locked. Only the frontmost
  /// app's model is ever stored, so one registration serves: arming another
  /// app's replaces it. `.normal`: its 100-ms slack stays inside the 250-ms
  /// maintenance lead, so a late wake still lands before the ceiling.
  private func armMaintenanceWake(_ arm: PreparedModelScheduler.Arm) {
    maintenanceWakePID = arm.ticket.pid
    pollScheduler.scheduleOnce(
      Self.maintenanceClientID, afterMs: Self.delayMs(untilUptime: arm.deadline),
      priority: .normal, on: .main
    ) { [weak self] in
      guard let self else { return }
      if self.maintenanceWakePID == arm.ticket.pid { self.maintenanceWakePID = nil }
      self.wakeRefreshTimer(arm, rearm: { $0.armMaintenanceWake($1) })
    }
  }

  /// A wake consumes its own ticket: a cancelled or replaced one is stale,
  /// and one that fired early re-arms the same way it was armed.
  private func wakeRefreshTimer(
    _ arm: PreparedModelScheduler.Arm,
    rearm: (AppMonitor, PreparedModelScheduler.Arm) -> Void
  ) {
    let pid = arm.ticket.pid
    switch modelScheduler.wake(arm.ticket, now: DispatchTime.now().uptimeNanoseconds) {
    case .stale: return
    case .wait(let extended): rearm(self, extended)
    case .fire(.refresh(let reason)):
      guard allowsAutomaticRefresh(pid: pid, reason: reason) else { return }
      runModelRefresh(pid: pid, reason: reason, completion: nil)
    case .fire(.readiness(let step, let then)):
      runReadinessStep(pid: pid, step: step, then: then)
    case .fire(.maintenance(let dirtyToken, let configRevision)):
      guard (dirtyTokens[pid] ?? 0) == dirtyToken,
        self.configRevision == configRevision,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      else { return }
      // Idle desk, locked screen, or sleeping display: nothing is looking
      // at the hints, so let the model expire; the next activation walks.
      guard Self.userInputIsRecent(withinSeconds: Self.maintenanceIdleSuspendSeconds) else {
        FlashLog.debug("[ax] maintenance_suspended pid=\(pid) reason=user_idle")
        return
      }
      scheduleModelRefresh(for: pid, reason: .maintenance)
    }
  }

  func scheduleMaintenanceRefresh(for model: PreparedModel) {
    cancelMaintenance(pid: model.pid)
    guard allowsAutomaticRefresh(pid: model.pid, reason: .maintenance) else { return }
    let arm = modelScheduler.scheduleMaintenance(
      pid: model.pid, computedAt: model.computedAt.uptimeNanoseconds,
      dirtyToken: model.dirtyToken, configRevision: model.configRevision,
      freshnessNs: UInt64(model.freshnessMs) * 1_000_000)
    armMaintenanceWake(arm)
  }

  /// Seconds since the last keyboard, mouse, or scroll event in the session.
  static func userInputIsRecent(withinSeconds limit: Double) -> Bool {
    let types: [CGEventType] = [
      .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged,
    ]
    let idle =
      types.map {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
      }.min() ?? 0
    return idle < limit
  }

  /// A maintenance walk that reproduces the current model unchanged is
  /// evidence the app is static: serve it longer before walking again. Any
  /// other outcome resets to the base ceiling.
  static func nextFreshnessMs(
    previous: PreparedModel?, built: PreparedModel, reason: ModelRefreshReason
  ) -> Int {
    guard reason == .maintenance, let previous,
      previous.dirtyToken == built.dirtyToken,
      previous.configRevision == built.configRevision,
      previous.fingerprint == built.fingerprint
    else { return modelFreshnessMs }
    return min(previous.freshnessMs * 2, modelFreshnessMaxMs)
  }

  func runModelRefresh(
    pid: pid_t,
    reason: ModelRefreshReason,
    completion: ((PreparedModel?) -> Void)?
  ) {
    // Activation may jump a debounce, maintenance or readiness wake. Invalidate
    // every ticket before starting so no callback can consume a later rearmed
    // request.
    modelScheduler.cancelRefresh(pid: pid)
    cancelMaintenance(pid: pid)
    modelScheduler.cancelReadiness(pid: pid)

    guard PermissionCheck.isAccessibilityTrusted else {
      completion?(nil)
      return
    }
    // Only prepare the front app. Background-app walks would compete
    // with the user's active app for AX IPC bandwidth and produce hints
    // that'd never be served.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      completion?(nil)
      return
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
      completion?(nil)
      return
    }
    let startToken = dirtyTokens[pid] ?? 0
    let revision = configRevision
    let cfg = snapshotConfig()
    guard let context = makeContext(for: app) else {
      completion?(nil)
      return
    }
    if completion == nil,
      !Self.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: context.bundleIdentifier)
    {
      FlashLog.debug(
        "[ax] model_refresh_skipped",
        fields: [
          "pid": "\(pid)",
          "bundle": context.bundleIdentifier,
          "reason": reason.logValue,
        ])
      return
    }
    // Prepare only the continuous suffix of the exclusive provider plan. A
    // dynamic volatile provider such as tmux is still probed on activation,
    // but its explicit empty result can fall through to this warm AX model.
    let plan = registry.hintProviderPlan(for: context)
    let providers = plan.preparedProviders
    let hasVolatileProvider = plan.uncachedProviders.contains { $0.resultsAreVolatile }
    guard !providers.isEmpty else {
      completion?(nil)
      return
    }
    guard preparedModels.beginRebuild(pid: pid) else {
      // Last-writer-wins: only the latest activation waiter matters,
      // earlier waiters are already-stale activations.
      if let completion {
        pendingModelCompletion[pid] = completion
      }
      return
    }
    if completion == nil {
      modelScheduler.noteRefreshStarted(pid: pid, now: DispatchTime.now().uptimeNanoseconds)
    }
    let primaryH = primaryScreenHeight()

    axQueue.async { [weak self] in
      guard let self else { return }
      let rebuildStartedAt = DispatchTime.now()
      let built = self.buildPreparedModel(
        context: context,
        providers: providers,
        cfg: cfg,
        primaryH: primaryH,
        dirtyToken: startToken,
        configRevision: revision)
      let rebuildEndedAt = DispatchTime.now()
      let rebuildElapsedMs =
        Double(
          rebuildEndedAt.uptimeNanoseconds - rebuildStartedAt.uptimeNanoseconds) / 1_000_000
      DispatchQueue.main.async {
        let shouldRunQueued = self.preparedModels.finishRebuild(pid: pid)
        let waiter = self.pendingModelCompletion.removeValue(forKey: pid)
        defer {
          if shouldRunQueued {
            self.scheduleModelRefresh(for: pid, reason: .queued)
          }
        }

        let tokenStillMatches = (self.dirtyTokens[pid] ?? 0) == startToken
        let revisionStillMatches = self.configRevision == revision
        let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let lastHealthy = self.healthyTargetCounts[pid]
        let degenerate = Self.discoveryLooksDegenerate(
          targets: built.targets.count, lastHealthy: lastHealthy)
        if completion == nil {
          self.noteAutomaticWalk(
            pid: pid, bundleIdentifier: context.bundleIdentifier, reason: reason,
            elapsedMs: rebuildElapsedMs, targets: built.targets.count, degenerate: degenerate,
            hasVolatileProvider: hasVolatileProvider,
            stillFocused: stillFocused && revisionStillMatches)
        }

        var built = built
        built.freshnessMs = Self.nextFreshnessMs(
          previous: self.preparedModels.current(pid: pid), built: built, reason: reason)
        let valid = tokenStillMatches && revisionStillMatches && stillFocused
        if valid {
          self.preparedModels.store(built)
          self.scheduleMaintenanceRefresh(for: built)
          if completion == nil, !degenerate {
            self.noteHealthyTargets(built.targets.count, pid: pid)
          }
        }
        // A degenerate walk is still complete: it is stored (activation
        // judges it a miss), but an app that has shown a healthy tree is owed
        // a walk once that tree is back. The token may have moved during the
        // walk — a tree being built fires events — so validity is not asked.
        if completion == nil, degenerate, let lastHealthy, revisionStillMatches, stillFocused {
          self.scheduleReadinessRewalk(
            pid: pid, bundleIdentifier: context.bundleIdentifier, after: reason,
            targets: built.targets.count, lastHealthy: lastHealthy)
        }
        let validModel = valid ? built : nil
        completion?(validModel)
        waiter?(validModel)
      }
    }
  }
}
