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
    maintenanceRefresh[pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: pid)
  }

  func cancelRefreshWork(for pid: pid_t) {
    modelRefreshArmed.remove(pid)
    modelRefreshDeadline.removeValue(forKey: pid)
    modelRefreshReason.removeValue(forKey: pid)
    maintenanceRefresh[pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: pid)
    lastBackgroundModelRefreshAt.removeValue(forKey: pid)
    pendingModelCompletion.removeValue(forKey: pid)
    slowAutomaticModelRefreshPIDs.remove(pid)
  }

  func cancelAllRefreshWork() {
    modelRefreshArmed.removeAll()
    modelRefreshDeadline.removeAll()
    modelRefreshReason.removeAll()
    for work in maintenanceRefresh.values { work.cancel() }
    maintenanceRefresh.removeAll()
    lastBackgroundModelRefreshAt.removeAll()
    pendingModelCompletion.removeAll()
    slowAutomaticModelRefreshPIDs.removeAll()
  }

  /// Debounced model refresh. Multiple events arriving within
  /// `modelDebounceMs` coalesce into a single background walk. The
  /// deadline pushes back on every fresh event so a steady stream
  /// (e.g. scrolling) stays quiet until it settles. We allocate at
  /// most one in-flight closure per pid for the whole burst.
  func scheduleModelRefresh(for pid: pid_t, reason: String) {
    let speculative = Self.backgroundModelRefreshShouldThrottle(reason: reason)
    guard
      !speculative
        || (!axEventStormingPIDs.contains(pid)
          && !slowAutomaticModelRefreshPIDs.contains(pid))
    else { return }
    let now = DispatchTime.now()
    let deadline = backgroundModelRefreshDeadline(pid: pid, reason: reason, now: now)
    modelRefreshDeadline[pid] = deadline
    modelRefreshReason[pid] = reason
    guard modelRefreshArmed.insert(pid).inserted else { return }
    armRefreshTimer(pid: pid, deadline: deadline)
  }

  private func backgroundModelRefreshDeadline(
    pid: pid_t,
    reason: String,
    now: DispatchTime
  ) -> DispatchTime {
    var deadline = now + .milliseconds(Self.modelDebounceMs)
    guard Self.backgroundModelRefreshShouldThrottle(reason: reason),
      let last = lastBackgroundModelRefreshAt[pid]
    else {
      return deadline
    }
    let minIntervalNs = UInt64(Self.backgroundModelMinIntervalMs) * 1_000_000
    let earliest = DispatchTime(uptimeNanoseconds: last.uptimeNanoseconds + minIntervalNs)
    if deadline.uptimeNanoseconds < earliest.uptimeNanoseconds {
      deadline = earliest
    }
    return deadline
  }

  static func backgroundModelRefreshShouldThrottle(reason: String) -> Bool {
    reason.hasPrefix("ax:") || reason == "queued" || reason == "maintenance"
  }

  /// Drop only speculative/noisy work when a notification storm is detected.
  /// Focus/config/user-action refreshes retain priority, and activation never
  /// enters this scheduler: it calls `runModelRefresh` with a completion and
  /// still performs one complete deterministic walk on demand.
  func suppressScheduledBackgroundModelRefresh(for pid: pid_t) {
    guard let reason = modelRefreshReason[pid],
      Self.backgroundModelRefreshShouldThrottle(reason: reason)
    else { return }
    modelRefreshArmed.remove(pid)
    modelRefreshDeadline.removeValue(forKey: pid)
    modelRefreshReason.removeValue(forKey: pid)
  }

  private func armRefreshTimer(pid: pid_t, deadline: DispatchTime) {
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
      guard let self else { return }
      guard let extended = self.modelRefreshDeadline[pid] else {
        self.modelRefreshArmed.remove(pid)
        self.modelRefreshReason.removeValue(forKey: pid)
        return
      }
      if DispatchTime.now() < extended {
        // A new event extended the deadline while we were waiting.
        // Re-arm rather than fire now so a burst still backs off.
        self.armRefreshTimer(pid: pid, deadline: extended)
        return
      }
      let reason = self.modelRefreshReason.removeValue(forKey: pid) ?? "debounced"
      self.modelRefreshArmed.remove(pid)
      self.modelRefreshDeadline.removeValue(forKey: pid)
      self.runModelRefresh(pid: pid, reason: reason, completion: nil)
    }
  }

  private func scheduleMaintenanceRefresh(for model: PreparedModel) {
    maintenanceRefresh[model.pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: model.pid)
    guard !slowAutomaticModelRefreshPIDs.contains(model.pid) else { return }
    let delayMs = max(0, Self.modelFreshnessMs - Self.modelMaintenanceLeadMs)
    let token = model.dirtyToken
    let revision = model.configRevision
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let currentToken = self.dirtyTokens[model.pid] ?? 0
      guard currentToken == token, self.configRevision == revision else { return }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == model.pid else { return }
      self.scheduleModelRefresh(for: model.pid, reason: "maintenance")
    }
    maintenanceRefresh[model.pid] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
  }

  func runModelRefresh(
    pid: pid_t,
    reason: String,
    completion: ((PreparedModel?) -> Void)?
  ) {
    // Any in-flight debounce closure for this pid has already finished
    // its check (it's the one calling us, or activation jumped the
    // queue). Clear the bookkeeping defensively.
    modelRefreshArmed.remove(pid)
    modelRefreshDeadline.removeValue(forKey: pid)
    modelRefreshReason.removeValue(forKey: pid)

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
    if completion == nil {
      lastBackgroundModelRefreshAt[pid] = DispatchTime.now()
    }
    guard preparedModels.beginRebuild(pid: pid) else {
      // Last-writer-wins: only the latest activation waiter matters,
      // earlier waiters are already-stale activations.
      if let completion {
        pendingModelCompletion[pid] = completion
      }
      return
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
            self.maintenanceRefresh[pid]?.cancel()
            self.maintenanceRefresh.removeValue(forKey: pid)
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
