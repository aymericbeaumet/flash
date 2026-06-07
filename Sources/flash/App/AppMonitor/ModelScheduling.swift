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
    pendingModelCompletion.removeValue(forKey: pid)
  }

  func cancelAllRefreshWork() {
    modelRefreshArmed.removeAll()
    modelRefreshDeadline.removeAll()
    modelRefreshReason.removeAll()
    for work in maintenanceRefresh.values { work.cancel() }
    maintenanceRefresh.removeAll()
    pendingModelCompletion.removeAll()
  }

  /// Debounced model refresh. Multiple events arriving within
  /// `modelDebounceMs` coalesce into a single background walk. The
  /// deadline pushes back on every fresh event so a steady stream
  /// (e.g. scrolling) stays quiet until it settles. We allocate at
  /// most one in-flight closure per pid for the whole burst.
  func scheduleModelRefresh(for pid: pid_t, reason: String) {
    let deadline = DispatchTime.now() + .milliseconds(Self.modelDebounceMs)
    modelRefreshDeadline[pid] = deadline
    modelRefreshReason[pid] = reason
    guard modelRefreshArmed.insert(pid).inserted else { return }
    armRefreshTimer(pid: pid, deadline: deadline)
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
      self.runModelRefresh(pid: pid, reason: reason, profiler: nil, completion: nil)
    }
  }

  private func scheduleMaintenanceRefresh(for model: PreparedModel) {
    maintenanceRefresh[model.pid]?.cancel()
    let delayMs = max(0, Self.modelFreshnessMs - Self.modelMaintenanceLeadMs)
    let token = model.dirtyToken
    let revision = model.configRevision
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let currentToken = self.dirtyTokens[model.pid] ?? 0
      guard currentToken == token, self.configRevision == revision else { return }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == model.pid else { return }
      self.runModelRefresh(pid: model.pid, reason: "maintenance", profiler: nil, completion: nil)
    }
    maintenanceRefresh[model.pid] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
  }

  func runModelRefresh(
    pid: pid_t,
    reason: String,
    profiler: FlashProfiler?,
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
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
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
    let startToken = dirtyTokens[pid] ?? 0
    let revision = configRevision
    let cfg = snapshotConfig()
    guard let context = makeContext(for: app) else {
      completion?(nil)
      return
    }
    if registry.anyVolatileSourceApplies(to: context) {
      completion?(nil)
      return
    }
    let providers = registry.continuousSources(for: context)
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

    let enqueueNs = profiler?.intervalStart()
    axQueue.async { [weak self] in
      guard let self else { return }
      if let enqueueNs {
        self.finishQueueWait(profiler, since: enqueueNs)
      }
      profiler?.mark(
        "model_build_start", detail: "token=\(startToken) reason=\(reason)")
      let built = self.buildPreparedModel(
        context: context,
        providers: providers,
        cfg: cfg,
        dirtyToken: startToken,
        configRevision: revision,
        profiler: profiler)
      profiler?.mark("model_build_done", detail: "hints=\(built.hints.count)")
      DispatchQueue.main.async {
        let shouldRunQueued = self.preparedModels.finishRebuild(pid: pid)
        let waiter = self.pendingModelCompletion.removeValue(forKey: pid)
        defer {
          if shouldRunQueued {
            self.scheduleModelRefresh(for: pid, reason: "queued")
          }
        }

        let tokenStillMatches = (self.dirtyTokens[pid] ?? 0) == startToken
        let revisionStillMatches = self.configRevision == revision
        let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if tokenStillMatches, revisionStillMatches, stillFocused {
          self.preparedModels.store(built)
          self.scheduleMaintenanceRefresh(for: built)
          if cfg.debug.profile {
            FlashLog.info(
              "[ax] model_ready pid=\(pid) bundle=\(context.bundleIdentifier) "
                + "hints=\(built.hints.count) token=\(startToken) reason=\(reason)"
            )
          }
        }
        let validModel = tokenStillMatches && revisionStillMatches && stillFocused ? built : nil
        completion?(validModel)
        waiter?(validModel)
      }
    }
  }
}
