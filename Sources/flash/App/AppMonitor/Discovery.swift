import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// Activation discovery pipeline. Activation either serves a prepared
/// model (instant) or runs the full provider chain on `axQueue`.
/// Everything below routes between those two regimes.
extension AppMonitor {
  // MARK: Discovery

  /// Activation hot path. Tries the prepared AX model first. Volatile
  /// providers (tmux) bypass the model entirely.
  func discoverAsync(
    context: AppContext,
    profiler: FlashProfiler? = nil,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let pid = context.processID
    if observers[pid] == nil {
      installObserver(for: pid)
    }

    if registry.anyVolatileSourceApplies(to: context) {
      runActivationDiscovery(
        context: context,
        profiler: profiler,
        targetFilter: targetFilter,
        completion: completion)
      return
    }

    if let model = lookupPreparedModel(for: pid) {
      let ageMs =
        Double(DispatchTime.now().uptimeNanoseconds - model.computedAt.uptimeNanoseconds)
        / 1_000_000
      profiler?.mark(
        "model_hit",
        detail:
          "hints=\(model.hints.count) age_ms=\(String(format: "%.1f", ageMs)) token=\(model.dirtyToken)"
      )
      if let targetFilter {
        let cfg = snapshotConfig()
        completion(assignTargets(model.targets.filter(targetFilter), cfg: cfg, profiler: profiler))
      } else {
        completion(model.hints)
      }
      return
    }

    profiler?.mark("model_miss", detail: "pid=\(pid)")
    runModelRefresh(
      pid: pid,
      reason: "activation",
      profiler: profiler
    ) { [weak self] model in
      guard let self else { return }
      if let model {
        if let targetFilter {
          let cfg = self.snapshotConfig()
          completion(self.assignTargets(model.targets.filter(targetFilter), cfg: cfg, profiler: profiler))
        } else {
          completion(model.hints)
        }
      } else {
        self.runActivationDiscovery(
          context: context,
          profiler: profiler,
          targetFilter: targetFilter,
          completion: completion)
      }
    }
  }

  func finishQueueWait(_ profiler: FlashProfiler?, since start: UInt64) {
    profiler?.finishInterval("ax_queue_wait", since: start)
  }

  private struct DiscoveryResult {
    let targets: [JumpTarget]
    let hints: [AssignedHint]
  }

  private struct DiscoveryFrame {
    let providerContext: AppContext
    let visibleRegions: [CGRect]
  }

  func buildPreparedModel(
    context: AppContext,
    providers: [FlashSource],
    cfg: Config,
    dirtyToken: UInt64,
    configRevision: UInt64,
    profiler: FlashProfiler?
  ) -> PreparedModel {
    let result = runAndAssign(
      context: context,
      cfg: cfg,
      providers: providers,
      profiler: profiler)
    return PreparedModel(
      pid: context.processID,
      bundleID: context.bundleIdentifier,
      targets: result.targets,
      hints: result.hints,
      computedAt: DispatchTime.now(),
      dirtyToken: dirtyToken,
      configRevision: configRevision)
  }

  private func runActivationDiscovery(
    context: AppContext,
    profiler: FlashProfiler?,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let cfg = snapshotConfig()
    let providers = registry.chain(for: context)
    let enqueueNs = profiler?.intervalStart()
    axQueue.async { [weak self] in
      guard let self else { return }
      if let enqueueNs {
        self.finishQueueWait(profiler, since: enqueueNs)
      }
      profiler?.mark(
        "walk_start", detail: "providers=\(providers.map(\.identifier).joined(separator: ","))")
      let result = self.runAndAssign(
        context: context,
        cfg: cfg,
        providers: providers,
        targetFilter: targetFilter,
        profiler: profiler)
      profiler?.mark("walk_done", detail: "hints=\(result.hints.count)")
      DispatchQueue.main.async {
        completion(result.hints)
      }
    }
  }

  private func runAndAssign(
    context: AppContext,
    cfg: Config,
    providers: [FlashSource],
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    profiler: FlashProfiler? = nil
  ) -> DiscoveryResult {
    let walkStart = profiler?.intervalStart()
    configureRuntime(for: cfg)
    let frame = resolveDiscoveryFrame(for: context, profiler: profiler)
    guard !frame.visibleRegions.isEmpty else {
      if let walkStart {
        profiler?.finishInterval("walk_all", since: walkStart, detail: "targets=0")
      }
      return DiscoveryResult(targets: [], hints: [])
    }
    let collected = collectFocusedTargets(
      context: frame.providerContext,
      providers: providers,
      profiler: profiler)
    let finalizeStart = profiler?.intervalStart()
    let finalized = TargetFinalizer.finalizeWithStats(
      collected,
      visibleRegions: frame.visibleRegions)
    let targets = targetFilter.map { finalized.targets.filter($0) } ?? finalized.targets
    if let finalizeStart {
      profiler?.finishInterval(
        "finalize_targets",
        since: finalizeStart,
        detail:
          "raw=\(finalized.rawCount) visible=\(finalized.visibleCount) "
          + "deduped=\(finalized.dedupedCount)")
    }
    if let walkStart {
      profiler?.finishInterval("walk_all", since: walkStart, detail: "targets=\(targets.count)")
    }
    let hints = assignTargets(targets, cfg: cfg, profiler: profiler)
    return DiscoveryResult(targets: targets, hints: hints)
  }

  private func assignTargets(
    _ targets: [JumpTarget],
    cfg: Config,
    profiler: FlashProfiler?
  ) -> [AssignedHint] {
    let resolved = cfg.resolvedAlphabet
    let assignStart = profiler?.intervalStart()
    let hints = HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: cfg.hints.minLength
    )
    if let assignStart {
      profiler?.finishInterval(
        "assign_hints", since: assignStart, detail: "targets=\(targets.count) hints=\(hints.count)")
    }
    return hints
  }

  private func resolveDiscoveryFrame(
    for context: AppContext,
    profiler: FlashProfiler? = nil
  ) -> DiscoveryFrame {
    let snapshotStart = profiler?.intervalStart()
    let snapshot = WindowSnapshot.build(
      primaryH: primaryScreenHeight(),
      onlyComputingVisibleRegionsFor: context.processID,
      ignoringPids: [getpid()])
    let visible: [CGRect]
    if let regions = snapshot.visibleRegions[context.processID] {
      visible = regions
    } else if snapshot.entries.isEmpty {
      // CGWindowList can fail transiently. Fall back to the activation-time
      // screen union so the user still gets hints instead of a silent empty
      // overlay; normal runs use the precise active-window visible regions.
      visible = [context.frontWindowFrame]
    } else {
      visible = []
    }
    let providerFrame = snapshot.activeWindowFrame ?? union(of: visible)
    if let snapshotStart {
      profiler?.finishInterval(
        "window_snapshot",
        since: snapshotStart,
        detail:
          "windows=\(snapshot.entries.count) visible_regions=\(visible.count)"
      )
    }
    return DiscoveryFrame(
      providerContext: clip(context, to: providerFrame),
      visibleRegions: visible)
  }

  private func collectFocusedTargets(
    context focused: AppContext,
    providers: [FlashSource],
    profiler: FlashProfiler? = nil
  ) -> [TargetCandidate] {
    var collected: [TargetCandidate] = []
    collected.reserveCapacity(256)
    for (providerOrder, provider) in providers.enumerated() {
      let providerStart = profiler?.intervalStart()
      let results =
        (try? provider.discover(in: focused)) ?? []
      collected.append(
        contentsOf: results.enumerated().map { ordinal, target in
          TargetCandidate(
            target: target,
            priority: provider.priority,
            providerOrder: providerOrder,
            ordinal: ordinal)
        })
      if let providerStart {
        profiler?.finishInterval(
          "provider.\(provider.identifier)",
          since: providerStart,
          detail: "raw=\(results.count)"
        )
      }
    }
    return collected
  }
}
