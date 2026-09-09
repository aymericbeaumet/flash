import AppKit
import ApplicationServices
import FlashCore

/// Prepared-model refresh scheduling: debounce, coalesce, maintenance
/// pre-fire, and the actual background walk that produces a fresh
/// `PreparedModel` from the focused-app context.
extension AppMonitor {
  // MARK: Prepared model scheduling

  func invalidatePreparedModel(for pid: pid_t) {
    preparedModels.discardModel(pid: pid)
    modelScheduler.cancelMaintenance(pid: pid)
  }

  func cancelRefreshWork(for pid: pid_t) {
    modelScheduler.reset(pid: pid)
    pendingModelCompletion.removeValue(forKey: pid)
    slowAutomaticModelRefreshPIDs.remove(pid)
  }

  func cancelAllRefreshWork() {
    modelScheduler.reset()
    pendingModelCompletion.removeAll()
    slowAutomaticModelRefreshPIDs.removeAll()
  }

  private func allowsAutomaticRefresh(pid: pid_t, reason: String) -> Bool {
    !PreparedModelScheduler.isSpeculative(reason: reason)
      || (!axEventStormingPIDs.contains(pid) && !slowAutomaticModelRefreshPIDs.contains(pid))
  }

  /// New events extend one debounce wake per burst. Higher-priority requests
  /// can move it earlier; an obsolete callback never owns the replacement.
  func scheduleModelRefresh(for pid: pid_t, reason: String) {
    guard allowsAutomaticRefresh(pid: pid, reason: reason),
      let arm = modelScheduler.scheduleRefresh(
        pid: pid, reason: reason, now: DispatchTime.now().uptimeNanoseconds)
    else { return }
    armRefreshTimer(arm)
  }

  func suppressScheduledBackgroundModelRefresh(for pid: pid_t) {
    modelScheduler.suppressSpeculativeRefresh(pid: pid)
  }

  private func armRefreshTimer(_ arm: PreparedModelScheduler.Arm) {
    DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: arm.deadline)) {
      [weak self] in
      guard let self else { return }
      let pid = arm.ticket.pid
      switch self.modelScheduler.wake(arm.ticket, now: DispatchTime.now().uptimeNanoseconds) {
      case .stale: return
      case .wait(let extended): self.armRefreshTimer(extended)
      case .fire(.refresh(let reason)):
        guard self.allowsAutomaticRefresh(pid: pid, reason: reason) else { return }
        self.runModelRefresh(pid: pid, reason: reason, completion: nil)
      case .fire(.maintenance(let dirtyToken, let configRevision)):
        guard (self.dirtyTokens[pid] ?? 0) == dirtyToken,
          self.configRevision == configRevision,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        self.scheduleModelRefresh(for: pid, reason: "maintenance")
      }
    }
  }

  private func scheduleMaintenanceRefresh(for model: PreparedModel) {
    modelScheduler.cancelMaintenance(pid: model.pid)
    guard allowsAutomaticRefresh(pid: model.pid, reason: "maintenance") else { return }
    let arm = modelScheduler.scheduleMaintenance(
      pid: model.pid, computedAt: model.computedAt.uptimeNanoseconds,
      dirtyToken: model.dirtyToken, configRevision: model.configRevision)
    armRefreshTimer(arm)
  }

  func runModelRefresh(
    pid: pid_t,
    reason: String,
    completion: ((PreparedModel?) -> Void)?
  ) {
    // Activation may jump a debounce/maintenance wake. Invalidate both tickets
    // before starting so neither callback can consume a later rearmed request.
    modelScheduler.cancelRefresh(pid: pid)
    modelScheduler.cancelMaintenance(pid: pid)

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
          "reason": reason,
        ])
      return
    }
    // Prepare only the continuous suffix of the exclusive provider plan. A
    // dynamic volatile provider such as tmux is still probed on activation,
    // but its explicit empty result can fall through to this warm AX model.
    let providers = registry.hintProviderPlan(for: context).preparedProviders
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

    axQueue.async { [weak self] in
      guard let self else { return }
      let rebuildStartedAt = DispatchTime.now()
      let built = self.buildPreparedModel(
        context: context,
        providers: providers,
        cfg: cfg,
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
            self.scheduleModelRefresh(for: pid, reason: "queued")
          }
        }

        if completion == nil {
          let wasSlow = self.slowAutomaticModelRefreshPIDs.contains(pid)
          let isSlow = Self.automaticModelRefreshIsSlow(elapsedMs: rebuildElapsedMs)
          if isSlow {
            self.slowAutomaticModelRefreshPIDs.insert(pid)
            self.modelScheduler.suppressSpeculativeRefresh(pid: pid)
            if !wasSlow {
              FlashLog.debug(
                "[ax] model_refresh_backoff",
                fields: [
                  "pid": "\(pid)",
                  "bundle": context.bundleIdentifier,
                  "reason": reason,
                  "elapsed_ms": String(format: "%.2f", rebuildElapsedMs),
                ])
            }
          } else {
            self.slowAutomaticModelRefreshPIDs.remove(pid)
          }
        }

        let tokenStillMatches = (self.dirtyTokens[pid] ?? 0) == startToken
        let revisionStillMatches = self.configRevision == revision
        let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if tokenStillMatches, revisionStillMatches, stillFocused {
          self.preparedModels.store(built)
          self.scheduleMaintenanceRefresh(for: built)
        }
        let validModel = tokenStillMatches && revisionStillMatches && stillFocused ? built : nil
        completion?(validModel)
        waiter?(validModel)
      }
    }
  }
}
