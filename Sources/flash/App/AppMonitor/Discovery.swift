import AppKit
import ApplicationServices
import FlashCore

/// Activation discovery pipeline. Activation-time providers run first; when a
/// dynamically scoped provider explicitly declines with an empty result, Flash
/// falls through to the prepared continuous-provider model.
extension AppMonitor {
  // MARK: Discovery

  /// Activation hot path. Dynamically scoped uncached providers (tmux) get the
  /// first chance to claim the context. Their explicit empty-result fallback
  /// can then use the prepared AX model without merging provider results.
  func discoverAsync(
    context: AppContext,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let pid = context.processID
    let startedAt = DispatchTime.now()
    let hasTargetFilter = targetFilter != nil
    func complete(
      path: String,
      hints: [AssignedHint],
      extra: [String: String] = [:]
    ) {
      if FlashLog.wouldEmit(.debug) {
        var fields: [String: String] = [
          "path": path,
          "pid": "\(pid)",
          "bundle": context.bundleIdentifier,
          "hints": "\(hints.count)",
          "target_filter": "\(hasTargetFilter)",
          "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
        ]
        for (key, value) in extra {
          fields[key] = value
        }
        FlashLog.debug("[discover] complete", fields: fields)
      }
      completion(hints)
    }

    if observers[pid] == nil {
      installObserver(for: pid)
    }

    let plan = registry.hintProviderPlan(for: context)

    func discoverPreparedFallback() {
      guard !plan.preparedProviders.isEmpty else {
        complete(path: "activation_no_fallback", hints: [])
        return
      }

      if let model = lookupPreparedModel(for: pid) {
        if let targetFilter {
          let cfg = snapshotConfig()
          let targets = model.targets.filter(targetFilter)
          complete(
            path: "prepared_model_filter",
            hints: assignTargets(targets, cfg: cfg),
            extra: [
              "model_targets": "\(model.targets.count)",
              "targets": "\(targets.count)",
            ])
        } else {
          complete(
            path: "prepared_model",
            hints: model.hints,
            extra: ["targets": "\(model.targets.count)"])
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
            let targets = model.targets.filter(targetFilter)
            complete(
              path: "prepared_model_refresh_filter",
              hints: self.assignTargets(targets, cfg: cfg),
              extra: [
                "model_targets": "\(model.targets.count)",
                "targets": "\(targets.count)",
              ])
          } else {
            complete(
              path: "prepared_model_refresh",
              hints: model.hints,
              extra: ["targets": "\(model.targets.count)"])
          }
        } else {
          self.runActivationDiscovery(
            context: context,
            providers: plan.preparedProviders,
            targetFilter: targetFilter
          ) { result in
            complete(path: "activation_refresh_miss", hints: result.hints)
          }
        }
      }
    }

    guard !plan.uncachedProviders.isEmpty else {
      discoverPreparedFallback()
      return
    }
    runActivationDiscovery(
      context: context,
      providers: plan.uncachedProviders,
      targetFilter: targetFilter
    ) { result in
      if result.allowsFallback {
        discoverPreparedFallback()
      } else {
        complete(path: "activation_uncached", hints: result.hints)
      }
    }
  }

  private struct DiscoveryResult {
    let targets: [JumpTarget]
    let hints: [AssignedHint]
    let allowsFallback: Bool
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
      reason: "prepared_model",
      context: context,
      cfg: cfg,
      providers: providers)
    return PreparedModel(
      pid: context.processID,
      targets: result.targets,
      hints: result.hints,
      computedAt: DispatchTime.now(),
      dirtyToken: dirtyToken,
      configRevision: configRevision)
  }

  private func runActivationDiscovery(
    context: AppContext,
    providers: [FlashSource],
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping (DiscoveryResult) -> Void
  ) {
    let cfg = snapshotConfig()
    axQueue.async { [weak self] in
      guard let self else { return }
      let result = self.runAndAssign(
        reason: "activation",
        context: context,
        cfg: cfg,
        providers: providers,
        targetFilter: targetFilter)
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  private func runAndAssign(
    reason: String,
    context: AppContext,
    cfg: Config,
    providers: [FlashSource],
    targetFilter: ((JumpTarget) -> Bool)? = nil
  ) -> DiscoveryResult {
    let startedAt = DispatchTime.now()
    configureRuntime(for: cfg)
    let frameStartedAt = DispatchTime.now()
    let frame = resolveDiscoveryFrame(for: context)
    let frameEndedAt = DispatchTime.now()
    guard !frame.visibleRegions.isEmpty else {
      logDiscoveryPipeline(
        reason: reason,
        context: context,
        providers: providers,
        visibleRegionCount: 0,
        targetFilterApplied: targetFilter != nil,
        rawCount: 0,
        visibleCount: 0,
        dedupedCount: 0,
        targetCount: 0,
        hintCount: 0,
        startedAt: startedAt,
        frameStartedAt: frameStartedAt,
        frameEndedAt: frameEndedAt,
        collectStartedAt: frameEndedAt,
        collectEndedAt: frameEndedAt,
        finalizeStartedAt: frameEndedAt,
        finalizeEndedAt: frameEndedAt,
        assignStartedAt: frameEndedAt,
        assignEndedAt: frameEndedAt)
      return DiscoveryResult(targets: [], hints: [], allowsFallback: false)
    }
    let collectStartedAt = DispatchTime.now()
    let collection = Self.collectFocusedTargets(
      context: frame.providerContext,
      providers: providers)
    let collectEndedAt = DispatchTime.now()
    let finalizeStartedAt = DispatchTime.now()
    let finalized = TargetFinalizer.finalizeWithStats(
      collection.targets,
      visibleRegions: frame.visibleRegions)
    let finalizeEndedAt = DispatchTime.now()
    let targets = targetFilter.map { finalized.targets.filter($0) } ?? finalized.targets
    let assignStartedAt = DispatchTime.now()
    let hints = assignTargets(targets, cfg: cfg)
    let assignEndedAt = DispatchTime.now()
    logDiscoveryPipeline(
      reason: reason,
      context: context,
      providers: collection.attemptedProviders,
      visibleRegionCount: frame.visibleRegions.count,
      targetFilterApplied: targetFilter != nil,
      rawCount: finalized.rawCount,
      visibleCount: finalized.visibleCount,
      dedupedCount: finalized.dedupedCount,
      targetCount: targets.count,
      hintCount: hints.count,
      startedAt: startedAt,
      frameStartedAt: frameStartedAt,
      frameEndedAt: frameEndedAt,
      collectStartedAt: collectStartedAt,
      collectEndedAt: collectEndedAt,
      finalizeStartedAt: finalizeStartedAt,
      finalizeEndedAt: finalizeEndedAt,
      assignStartedAt: assignStartedAt,
      assignEndedAt: assignEndedAt)
    return DiscoveryResult(
      targets: targets,
      hints: hints,
      allowsFallback: collection.allowsFallback)
  }

  private func logDiscoveryPipeline(
    reason: String,
    context: AppContext,
    providers: [FlashSource],
    visibleRegionCount: Int,
    targetFilterApplied: Bool,
    rawCount: Int,
    visibleCount: Int,
    dedupedCount: Int,
    targetCount: Int,
    hintCount: Int,
    startedAt: DispatchTime,
    frameStartedAt: DispatchTime,
    frameEndedAt: DispatchTime,
    collectStartedAt: DispatchTime,
    collectEndedAt: DispatchTime,
    finalizeStartedAt: DispatchTime,
    finalizeEndedAt: DispatchTime,
    assignStartedAt: DispatchTime,
    assignEndedAt: DispatchTime
  ) {
    guard FlashLog.wouldEmit(.debug) else { return }
    FlashLog.debug(
      "[discover] pipeline",
      fields: [
        "reason": reason,
        "pid": "\(context.processID)",
        "bundle": context.bundleIdentifier,
        "providers": providers.map(\.identifier).joined(separator: ","),
        "visible_regions": "\(visibleRegionCount)",
        "target_filter": "\(targetFilterApplied)",
        "raw_targets": "\(rawCount)",
        "visible_targets": "\(visibleCount)",
        "deduped_targets": "\(dedupedCount)",
        "targets": "\(targetCount)",
        "hints": "\(hintCount)",
        "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
        "frame_ms": Self.elapsedMilliseconds(from: frameStartedAt, to: frameEndedAt),
        "collect_ms": Self.elapsedMilliseconds(from: collectStartedAt, to: collectEndedAt),
        "finalize_ms": Self.elapsedMilliseconds(from: finalizeStartedAt, to: finalizeEndedAt),
        "assign_ms": Self.elapsedMilliseconds(from: assignStartedAt, to: assignEndedAt),
      ])
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

  struct FocusedTargetCollection {
    let targets: [TargetCandidate]
    let attemptedProviders: [FlashSource]
    let allowsFallback: Bool
  }

  /// Run an exclusive provider chain. Results never merge: the first provider
  /// returning any targets owns the context. Only an explicit empty-result
  /// fallback advances to the next provider.
  static func collectFocusedTargets(
    context focused: AppContext,
    providers: [FlashSource]
  ) -> FocusedTargetCollection {
    var attemptedProviders: [FlashSource] = []
    for (providerOrder, provider) in providers.enumerated() {
      attemptedProviders.append(provider)
      let results: [JumpTarget]
      do {
        results = try provider.discover(in: focused)
      } catch {
        // Rule 8 keeps the UI silent on no-targets, but a throwing provider
        // is the one breadcrumb that explains "pressed f, nothing happened"
        // — log it instead of swallowing.
        FlashLog.warn(
          "[discover] provider=\(provider.identifier) failed: \(error)",
          fields: ["provider": provider.identifier, "error": String(describing: error)])
        results = []
      }
      if !results.isEmpty {
        let targets = results.enumerated().map { ordinal, target in
          TargetCandidate(
            target: target,
            priority: provider.priority(in: focused),
            providerOrder: providerOrder,
            ordinal: ordinal)
        }
        return FocusedTargetCollection(
          targets: targets,
          attemptedProviders: attemptedProviders,
          allowsFallback: false)
      }
      if !provider.fallsBackOnEmptyDiscovery {
        return FocusedTargetCollection(
          targets: [],
          attemptedProviders: attemptedProviders,
          allowsFallback: false)
      }
    }
    return FocusedTargetCollection(
      targets: [],
      attemptedProviders: attemptedProviders,
      allowsFallback: attemptedProviders.last?.fallsBackOnEmptyDiscovery == true)
  }

  private static func elapsedMilliseconds(since start: DispatchTime) -> String {
    elapsedMilliseconds(from: start, to: DispatchTime.now())
  }

  private static func elapsedMilliseconds(from start: DispatchTime, to end: DispatchTime) -> String
  {
    let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
    return String(format: "%.2f", Double(nanos) / 1_000_000)
  }
}
