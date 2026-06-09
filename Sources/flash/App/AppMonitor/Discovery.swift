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
        targetFilter: targetFilter,
        completion: completion)
      return
    }

    if let model = lookupPreparedModel(for: pid) {
      if let targetFilter {
        let cfg = snapshotConfig()
        completion(assignTargets(model.targets.filter(targetFilter), cfg: cfg))
      } else {
        completion(model.hints)
      }
      return
    }

    runModelRefresh(
      pid: pid,
      reason: "activation"
    ) { [weak self] model in
      guard let self else { return }
      if let model {
        if let targetFilter {
          let cfg = self.snapshotConfig()
          completion(self.assignTargets(model.targets.filter(targetFilter), cfg: cfg))
        } else {
          completion(model.hints)
        }
      } else {
        self.runActivationDiscovery(
          context: context,
          targetFilter: targetFilter,
          completion: completion)
      }
    }
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
    configRevision: UInt64
  ) -> PreparedModel {
    let result = runAndAssign(
      context: context,
      cfg: cfg,
      providers: providers)
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
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let cfg = snapshotConfig()
    // Exclusive hints: run only the winning provider, never the whole chain.
    let providers = registry.hintProvider(for: context).map { [$0] } ?? []
    axQueue.async { [weak self] in
      guard let self else { return }
      let result = self.runAndAssign(
        context: context,
        cfg: cfg,
        providers: providers,
        targetFilter: targetFilter)
      DispatchQueue.main.async {
        completion(result.hints)
      }
    }
  }

  private func runAndAssign(
    context: AppContext,
    cfg: Config,
    providers: [FlashSource],
    targetFilter: ((JumpTarget) -> Bool)? = nil
  ) -> DiscoveryResult {
    configureRuntime(for: cfg)
    let frame = resolveDiscoveryFrame(for: context)
    guard !frame.visibleRegions.isEmpty else {
      return DiscoveryResult(targets: [], hints: [])
    }
    let collected = collectFocusedTargets(
      context: frame.providerContext,
      providers: providers)
    let finalized = TargetFinalizer.finalizeWithStats(
      collected,
      visibleRegions: frame.visibleRegions)
    let targets = targetFilter.map { finalized.targets.filter($0) } ?? finalized.targets
    let hints = assignTargets(targets, cfg: cfg)
    return DiscoveryResult(targets: targets, hints: hints)
  }

  private func assignTargets(
    _ targets: [JumpTarget],
    cfg: Config
  ) -> [AssignedHint] {
    let resolved = cfg.resolvedAlphabet
    return HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: cfg.hints.minLength
    )
  }

  private func resolveDiscoveryFrame(for context: AppContext) -> DiscoveryFrame {
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
    return DiscoveryFrame(
      providerContext: clip(context, to: providerFrame),
      visibleRegions: visible)
  }

  private func collectFocusedTargets(
    context focused: AppContext,
    providers: [FlashSource]
  ) -> [TargetCandidate] {
    var collected: [TargetCandidate] = []
    collected.reserveCapacity(256)
    for (providerOrder, provider) in providers.enumerated() {
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
    }
    return collected
  }
}
