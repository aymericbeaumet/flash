import AppKit
import FlashCore
import FlashProviders
import Foundation

struct SourceDescriptor {
  let identifier: String
  let activationPolicy: FlashSourceActivationPolicy
  let make: () -> FlashSource
}

final class SourceRegistry {
  private let descriptors: [SourceDescriptor]
  private let terminalBundleIDs: Set<String>
  private let runningApplicationsProvider: () -> [NSRunningApplication]
  private let pluginSourcesProvider: () -> [FlashSource]
  private let lock = NSLock()
  private var activeSourcesByID: [String: FlashSource] = [:]
  private var runningApplications: [NSRunningApplication] = []
  private var openConfig: Config.Open

  init(
    descriptors: [SourceDescriptor]? = nil,
    openConfig: Config.Open = .init(),
    terminalBundleIDs: Set<String> = TerminalBundles.identifiers,
    runningApplications: [NSRunningApplication]? = nil,
    runningApplicationsProvider: (() -> [NSRunningApplication])? = nil,
    pluginSourcesProvider: (() -> [FlashSource])? = nil
  ) {
    let initialRunningApplications =
      runningApplications ?? runningApplicationsProvider?()
      ?? NSWorkspace.shared.runningApplications
    if let runningApplicationsProvider {
      self.runningApplicationsProvider = runningApplicationsProvider
    } else if runningApplications != nil {
      self.runningApplicationsProvider = { initialRunningApplications }
    } else {
      self.runningApplicationsProvider = { NSWorkspace.shared.runningApplications }
    }
    self.pluginSourcesProvider = pluginSourcesProvider ?? { [] }
    self.terminalBundleIDs = terminalBundleIDs
    self.openConfig = openConfig
    self.descriptors =
      descriptors
      ?? [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          ApplicationSource(ignoredApps: openConfig.ignoredApps)
        },
        SourceDescriptor(identifier: "accessibility", activationPolicy: .always) {
          AccessibilityProvider()
        },
        SourceDescriptor(
          identifier: "safari-tabs",
          activationPolicy: .bundleIDs(BrowserTabSources.safariBundleIdentifiers)
        ) {
          SafariTabsSource()
        },
        SourceDescriptor(
          identifier: "chromium-tabs",
          activationPolicy: .bundleIDs(BrowserTabSources.chromiumBundleIdentifiers)
        ) {
          ChromiumTabsSource()
        },
      ]
    refreshRunningApplications(initialRunningApplications)
  }

  func updateOpenConfig(_ openConfig: Config.Open) {
    lock.lock()
    self.openConfig = openConfig
    let appSource = activeSourcesByID["core.apps"] as? ApplicationSource
    lock.unlock()
    appSource?.updateIgnoredApps(openConfig.ignoredApps)
  }

  var sources: [FlashSource] {
    lock.lock()
    let builtIn = Array(activeSourcesByID.values)
    lock.unlock()
    return (builtIn + pluginSourcesProvider()).sorted { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      return lhs.identifier < rhs.identifier
    }
  }

  var environment: FlashSourceEnvironment {
    lock.lock()
    defer { lock.unlock() }
    return FlashSourceEnvironment(runningApplications: runningApplications)
  }

  func refreshRunningApplications(_ applications: [NSRunningApplication]? = nil) {
    let applications = applications ?? runningApplicationsProvider()
    lock.lock()
    runningApplications = applications
    let activeIDs = Set(
      descriptors
        .filter { descriptor in
          Self.activationPolicyMatches(
            descriptor.activationPolicy,
            runningApplications: applications,
            terminalBundleIDs: terminalBundleIDs)
        }
        .map(\.identifier))

    for identifier in Array(activeSourcesByID.keys) where !activeIDs.contains(identifier) {
      activeSourcesByID.removeValue(forKey: identifier)
    }
    for descriptor in descriptors where activeIDs.contains(descriptor.identifier) {
      if activeSourcesByID[descriptor.identifier] == nil {
        let source = descriptor.make()
        if let appSource = source as? ApplicationSource {
          appSource.updateIgnoredApps(openConfig.ignoredApps)
        }
        activeSourcesByID[descriptor.identifier] = source
      }
    }
    lock.unlock()
  }

  func chain(for context: AppContext) -> [FlashSource] {
    return
      sources
      .filter { $0.capabilities.contains(.jumpTargets) && $0.supports(context) }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.identifier < rhs.identifier
      }
  }

  /// The single source that owns hints for `context`. Hint selection is
  /// exclusive: only the highest-priority `.jumpTargets` provider runs, with
  /// no additive merge and no fallback if it yields nothing. For a generic app
  /// this is the core AX walk (`accessibility`, priority 10); when a plugin
  /// opts in via `provides_hints` at a higher priority and supports the app,
  /// it takes over `f` for that app alone. `chain(for:)` is already
  /// priority-sorted, so the winner is its head.
  func hintProvider(for context: AppContext) -> FlashSource? {
    chain(for: context).first
  }

  func anyVolatileSourceApplies(to context: AppContext) -> Bool {
    for source in sources where source.readinessPolicy == .volatile || source.resultsAreVolatile {
      if source.capabilities.contains(.jumpTargets), source.supports(context) {
        return true
      }
    }
    return false
  }

  func candidates(scope: CandidateScope) -> [Candidate] {
    refreshRunningApplications()
    let sourceSnapshot = sources.filter { $0.capabilities.contains(.candidates) }
    let env = environment
    var raw: [Candidate] = []
    for source in sourceSnapshot {
      let sourceCandidates = source.candidates(in: env, scope: scope)
      FlashLog.trace(
        "[candidate_finder] source=\(source.identifier) count=\(sourceCandidates.count)")
      raw.append(contentsOf: sourceCandidates)
    }
    return CandidateFinder.prepare(raw)
  }

  func coreAppCandidates(scope: CandidateScope) -> [Candidate] {
    refreshRunningApplications()
    let env = environment
    guard let source = source(identifier: "core.apps") else { return [] }
    return CandidateFinder.prepare(source.candidates(in: env, scope: scope))
  }

  func registeredCandidateSourceLabels() -> [String] {
    refreshRunningApplications()
    var seen = Set<String>()
    var labels: [String] = []
    for source in sources where source.capabilities.contains(.candidates) {
      let sourceLabels = source.candidateSourceLabels
      let candidates = sourceLabels.isEmpty ? [source.displayName] : sourceLabels
      for raw in candidates {
        let label = raw.trimmed
        guard !label.isEmpty, !seen.contains(label) else { continue }
        seen.insert(label)
        labels.append(label)
      }
    }
    labels.sort()
    return labels
  }

  func queryCandidateSources(
    scope: CandidateScope,
    text: String,
    sourceFilters: [String],
    firstDeadlineMs: Int? = nil,
    completion: @escaping (_ candidates: [Candidate], _ isFinal: Bool) -> Void
  ) {
    refreshRunningApplications()
    let env = environment
    let request = CandidateQuery(scope: scope, text: text, sourceFilters: sourceFilters)
    let sourceSnapshot = sources.filter { source in
      guard source.identifier != "core.apps",
        source.identifier.hasPrefix("plugin:"),
        source.capabilities.contains(.candidates)
      else { return false }
      guard !sourceFilters.isEmpty else { return true }
      let labels =
        source.candidateSourceLabels.isEmpty
        ? [source.displayName, source.identifier]
        : source.candidateSourceLabels
      return sourceFilters.contains { filter in
        labels.contains { label in
          CandidateFinder.sourceLabelMatchesFilter(label, filter: filter)
        }
      }
    }
    guard !sourceSnapshot.isEmpty else {
      DispatchQueue.main.async { completion([], true) }
      return
    }
    let resultLock = NSLock()
    var raw: [Candidate] = []
    var remaining = sourceSnapshot.count
    var sentFirst = false

    func snapshotPrepared() -> [Candidate] {
      resultLock.lock()
      let items = raw
      resultLock.unlock()
      return CandidateFinder.prepare(items)
    }

    if let firstDeadlineMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(firstDeadlineMs)) {
        resultLock.lock()
        let shouldSend = !sentFirst && remaining > 0
        sentFirst = true
        let items = raw
        resultLock.unlock()
        if shouldSend {
          completion(CandidateFinder.prepare(items), false)
        }
      }
    }

    for source in sourceSnapshot {
      source.queryCandidates(in: env, request: request) { items in
        resultLock.lock()
        raw.append(contentsOf: items)
        remaining -= 1
        let isDone = remaining == 0
        if isDone {
          sentFirst = true
        }
        resultLock.unlock()
        FlashLog.trace(
          "[candidate_finder] query_source=\(source.identifier) count=\(items.count)")
        if isDone {
          completion(snapshotPrepared(), true)
        }
      }
    }
  }

  func candidate(
    matching target: String,
    sourceID: String? = nil
  ) -> Candidate? {
    refreshRunningApplications()
    let env = environment
    let sourceSnapshot = sources.filter { source in
      source.capabilities.contains(.appActivation)
        && (sourceID == nil || source.identifier == sourceID)
    }
    // `app_open?name=` means "activate application X". The app source resolves
    // names precisely (bundle id / exact running name / `<name>.app` lookup),
    // so consult it first — otherwise a higher-priority plugin shadows the app
    // with a loose substring match: e.g. a "[slack]" channel whose decorated
    // title contains the query. Skip text-insertion candidates entirely so an
    // app_open can never type emoji content into the focused field.
    let ordered =
      sourceSnapshot.filter { $0.identifier == "core.apps" }
      + sourceSnapshot.filter { $0.identifier != "core.apps" }
    for source in ordered {
      guard let item = source.candidate(matching: target, in: env),
        !CandidateFinder.insertsText(item)
      else { continue }
      return CandidateFinder.prepare(item)
    }
    return nil
  }

  func candidate(forProcessID pid: pid_t) -> Candidate? {
    refreshRunningApplications()
    let env = environment
    for source in sources where source.identifier == "core.apps" {
      if let appSource = source as? ApplicationSource,
        let item = appSource.candidate(forProcessID: pid, in: env)
      {
        return CandidateFinder.prepare(item)
      }
    }
    return nil
  }

  func resolveCandidate(
    _ item: Candidate,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    refreshRunningApplications()
    let env = environment
    guard let source = source(identifier: item.sourceID) else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }
    source.resolveCandidate(item, in: env, completion: completion)
  }

  func documentURL(in context: AppContext) -> String? {
    for source in chain(for: context)
    where source.capabilities.contains(.documentURL) {
      if let url = source.documentURL(in: context) {
        return url
      }
    }
    return nil
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabSelection, context: context, completion: completion) {
      source, env, done in
      source.tabSelect(at: index, in: context, environment: env, completion: done)
    }
  }

  func tabNext(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabNavigation, context: context, completion: completion) {
      source, env, done in
      source.tabNext(in: context, environment: env, completion: done)
    }
  }

  func tabPrev(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabNavigation, context: context, completion: completion) {
      source, env, done in
      source.tabPrev(in: context, environment: env, completion: done)
    }
  }

  func tabFirst(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabNavigation, context: context, completion: completion) {
      source, env, done in
      source.tabFirst(in: context, environment: env, completion: done)
    }
  }

  func tabLast(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabNavigation, context: context, completion: completion) {
      source, env, done in
      source.tabLast(in: context, environment: env, completion: done)
    }
  }

  func tabNew(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabCreation, context: context, completion: completion) {
      source, env, done in
      source.tabNew(in: context, environment: env, completion: done)
    }
  }

  func tabClose(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabClosing, context: context, completion: completion) {
      source, env, done in
      source.tabClose(in: context, environment: env, completion: done)
    }
  }

  func scrollTop(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .scrollExtremes, context: context, completion: completion) {
      source, env, done in
      source.scrollTop(in: context, environment: env, completion: done)
    }
  }

  func scrollBottom(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .scrollExtremes, context: context, completion: completion) {
      source, env, done in
      source.scrollBottom(in: context, environment: env, completion: done)
    }
  }

  func tabMovePrev(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabReorder, context: context, completion: completion) {
      source, env, done in
      source.tabMovePrev(in: context, environment: env, completion: done)
    }
  }

  func tabMoveNext(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabReorder, context: context, completion: completion) {
      source, env, done in
      source.tabMoveNext(in: context, environment: env, completion: done)
    }
  }

  func tabReopen(
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(capability: .tabReopen, context: context, completion: completion) {
      source, env, done in
      source.tabReopen(in: context, environment: env, completion: done)
    }
  }

  func source(identifier: String) -> FlashSource? {
    lock.lock()
    if let builtIn = activeSourcesByID[identifier] {
      lock.unlock()
      return builtIn
    }
    lock.unlock()
    let pluginSources = pluginSourcesProvider()
    if let exact = pluginSources.first(where: { $0.identifier == identifier }) {
      return exact
    }
    return pluginSources.first { source in
      identifier.hasPrefix(source.identifier + ".")
    }
  }

  private func performSourceAction(
    capability: FlashSourceCapabilities,
    context: AppContext,
    completion: @escaping (SourceActionResult) -> Void,
    action:
      @escaping (FlashSource, FlashSourceEnvironment, @escaping (SourceActionResult) -> Void)
      -> Void
  ) {
    // Timing breakdown for the tab-action latency investigation: which source
    // a tab key waits on, and for how long. `refresh_ms` is the synchronous
    // running-apps refresh; each `source` line is one (possibly plugin-RPC)
    // attempt; `total_ms` is wall time from entry to resolution.
    let startedNs = DispatchTime.now().uptimeNanoseconds
    refreshRunningApplications()
    let refreshMs = Self.elapsedMs(since: startedNs)
    let env = environment
    let sourceSnapshot = sources.filter {
      $0.capabilities.contains(capability) && $0.supports(context)
    }
    guard !sourceSnapshot.isEmpty else {
      FlashLog.trace(
        "[source_action] cap=\(capability.rawValue) sources=0 refresh_ms=\(refreshMs) unhandled")
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }

    func finish(_ result: SourceActionResult, handledBy: String) {
      FlashLog.trace(
        "[source_action] cap=\(capability.rawValue) handled_by=\(handledBy) "
          + "refresh_ms=\(refreshMs) total_ms=\(Self.elapsedMs(since: startedNs)) "
          + "did_perform=\(result.didPerform)")
      completion(result)
    }

    func attempt(_ index: Int) {
      guard index < sourceSnapshot.count else {
        finish(.unhandled, handledBy: "none")
        return
      }
      let source = sourceSnapshot[index]
      let attemptNs = DispatchTime.now().uptimeNanoseconds
      action(source, env) { result in
        FlashLog.trace(
          "[source_action] source=\(source.identifier) ms=\(Self.elapsedMs(since: attemptNs)) "
            + "disposition=\(result.disposition)")
        switch result.disposition {
        case .performed, .failed:
          // `.failed` also stops the chain: the source claimed the action
          // for this context, so a lower-priority source must not re-run
          // it (and the caller must not keystroke-fallback).
          finish(result, handledBy: source.identifier)
        case .unhandled:
          attempt(index + 1)
        }
      }
    }
    attempt(0)
  }

  private static func elapsedMs(since startNs: UInt64) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
  }

  private static func activationPolicyMatches(
    _ policy: FlashSourceActivationPolicy,
    runningApplications: [NSRunningApplication],
    terminalBundleIDs: Set<String>
  ) -> Bool {
    switch policy {
    case .always:
      return true
    case .bundleIDs(let bundleIDs):
      return runningApplications.contains { app in
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleIDs.contains(bundleID)
      }
    case .terminalBundles:
      return runningApplications.contains { app in
        guard let bundleID = app.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundleID)
      }
    }
  }
}
