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
        let lhsPriority = lhs.priority(in: context)
        let rhsPriority = rhs.priority(in: context)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
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
    let startedNs = DispatchTime.now().uptimeNanoseconds
    refreshRunningApplications()
    let allSources = sources
    var sourceSnapshot: [FlashSource] = []
    var excluded: [String] = []
    for source in allSources {
      if source.capabilities.contains(.candidates) {
        sourceSnapshot.append(source)
      } else {
        excluded.append(
          "\(source.identifier)(caps=\(source.capabilities.traceDescription))")
      }
    }
    if !excluded.isEmpty {
      FlashLog.trace(
        "[candidate_finder] candidates_pool considered=\(allSources.count) "
          + "passing=\(sourceSnapshot.count) excluded=[\(excluded.joined(separator: ","))]")
    }
    let env = environment
    var raw: [Candidate] = []
    for source in sourceSnapshot {
      // Candidate-finder sessions freeze this synchronous snapshot. Do not call
      // `queryCandidates` here; plugins are expected to keep candidates warm in
      // memory and late updates are for the next session.
      let sourceStartedNs = DispatchTime.now().uptimeNanoseconds
      let sourceCandidates = source.candidates(in: env, scope: scope)
      let sourceMs = Int((DispatchTime.now().uptimeNanoseconds &- sourceStartedNs) / 1_000_000)
      FlashLog.trace(
        "[candidate_finder] source=\(source.identifier) count=\(sourceCandidates.count) "
          + "ms=\(sourceMs)")
      raw.append(contentsOf: sourceCandidates)
    }
    let prepareStartedNs = DispatchTime.now().uptimeNanoseconds
    let prepared = CandidateFinder.prepare(raw)
    let prepareMs = Int((DispatchTime.now().uptimeNanoseconds &- prepareStartedNs) / 1_000_000)
    let totalMs = Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
    FlashLog.trace(
      "[candidate_finder] prepare scope=\(scope) raw=\(raw.count) prepared=\(prepared.count) "
        + "prepare_ms=\(prepareMs) total_ms=\(totalMs)")
    return prepared
  }

  func coreAppCandidates(scope: CandidateScope) -> [Candidate] {
    refreshRunningApplications()
    let env = environment
    guard let source = source(identifier: "core.apps") else { return [] }
    return CandidateFinder.prepare(source.candidates(in: env, scope: scope))
  }

  /// Candidates from the in-process built-in sources only (currently
  /// `core.apps`). This is the instant first-paint seed when a flashlight
  /// session opens; plugin location rows are pulled asynchronously via
  /// `queryCandidates` and merged in as they land (the pull model — the host
  /// keeps no candidate cache of its own).
  func synchronousCandidates(scope: CandidateScope) -> [Candidate] {
    refreshRunningApplications()
    let env = environment
    lock.lock()
    let builtIn = Array(activeSourcesByID.values)
    lock.unlock()
    var raw: [Candidate] = []
    for source in builtIn where source.capabilities.contains(.candidates) {
      raw.append(contentsOf: source.candidates(in: env, scope: scope))
    }
    return CandidateFinder.prepare(raw)
  }

  /// Plugin candidate sources that contribute location rows to the default
  /// flashlight pool — those declaring a `kind: .locations` descriptor at normal
  /// priority or above. Fanned out via `queryCandidates` on flashlight open.
  /// Built-in sources (e.g. `core.apps`) are excluded; they paint synchronously
  /// via `synchronousCandidates`.
  func locationCandidateSources() -> [FlashSource] {
    pluginSourcesProvider().filter { Self.isLocationCandidateSource($0) }
  }

  /// Plugin candidate sources that do NOT contribute default-pool location rows
  /// — emojis, search-engine bangs, notes, contacts, etc. These are pulled
  /// lazily the first time the user types an `@source`/`!`bang filter, not on
  /// open.
  func nonLocationCandidateSources() -> [FlashSource] {
    pluginSourcesProvider().filter { source in
      source.capabilities.contains(.candidates) && !Self.isLocationCandidateSource(source)
    }
  }

  private static func isLocationCandidateSource(_ source: FlashSource) -> Bool {
    source.capabilities.contains(.candidates)
      && source.candidateSourceDescriptors.contains { descriptor in
        descriptor.kind == .locations && descriptor.priority.rank >= FlashPriority.normal.rank
      }
  }

  var snapshotEnvironment: FlashSourceEnvironment { environment }

  func registeredCandidateSourceLabels() -> [String] {
    refreshRunningApplications()
    var seen = Set<String>()
    var labels: [String] = []
    for source in sources where source.capabilities.contains(.candidates) {
      let sourceLabels = source.candidateSourceLabels
      let sourceDescriptors = source.candidateSourceDescriptors
      let candidates =
        sourceLabels.isEmpty
        ? (sourceDescriptors.isEmpty ? [source.displayName] : sourceDescriptors.map(\.name))
        : sourceLabels
      for raw in candidates {
        let label = raw.trimmed
        let key = label.lowercased()
        guard !label.isEmpty, seen.insert(key).inserted else { continue }
        labels.append(label)
      }
    }
    labels.sort()
    return labels
  }

  func registeredCandidateSourceDescriptors() -> [CandidateSourceDescriptor] {
    refreshRunningApplications()
    var seen = Set<String>()
    var descriptors: [CandidateSourceDescriptor] = []
    for source in sources where source.capabilities.contains(.candidates) {
      let declared = source.candidateSourceDescriptors
      let candidates =
        declared.isEmpty
        ? [CandidateSourceDescriptor(name: source.displayName)]
        : declared
      for raw in candidates {
        var descriptor = raw
        descriptor.name = descriptor.name.trimmed
        let key = descriptor.name.lowercased()
        guard !descriptor.name.isEmpty, seen.insert(key).inserted else { continue }
        descriptors.append(descriptor)
      }
    }
    descriptors.sort { lhs, rhs in
      let left = lhs.name.lowercased()
      let right = rhs.name.lowercased()
      if left != right { return left < right }
      return lhs.name < rhs.name
    }
    return descriptors
  }

  func candidate(
    matching target: String,
    sourceID: String? = nil
  ) -> Candidate? {
    refreshRunningApplications()
    let env = environment
    let sourceSnapshot = sources.filter { source in
      source.capabilities.contains(.appActivation)
        && (sourceID == nil || Self.source(source, owns: sourceID!))
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

  func currentLocation(in context: AppContext) -> Candidate? {
    let locationCandidates =
      candidates(scope: .all)
      .filter { $0.isLocation && $0.kind != CandidateFinder.sourceKind }
    let samePID = locationCandidates.filter { $0.pid == context.processID }
    if let current = samePID.first(where: \.isCurrentLocation) {
      return current
    }
    if let documentURL = documentURL(in: context),
      let current = location(in: samePID, matchingURLString: documentURL)
    {
      return current
    }
    if samePID.count == 1 {
      return samePID[0]
    }
    if let app = samePID.first(where: { $0.kind == .app }) {
      return app
    }
    return candidate(forProcessID: context.processID)
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

  /// Dispatch `action` through the source chain. The first registered
  /// source whose ``FlashSourceCapabilities`` includes
  /// ``SourceAction/requiredCapability`` and supports the focused app gets
  /// to handle it; on `.unhandled` the next source runs; on `.performed`
  /// or `.failed` the chain stops and the result is reported. Replaces the
  /// dozen tab*/scroll* dispatch methods this registry used to expose.
  func perform(
    _ action: SourceAction,
    in context: AppContext,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    performSourceAction(
      capability: action.requiredCapability,
      context: context,
      completion: completion
    ) { source, env, done in
      source.performAction(action, in: context, environment: env, completion: done)
    }
  }

  func canRestoreNavigation(to url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    refreshRunningApplications()
    return sources.contains { source in
      source.capabilities.contains(.navigationRoutes)
        && source.navigationSchemes.contains(scheme)
    }
  }

  func restoreNavigation(
    to url: URL,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    refreshRunningApplications()
    let env = environment
    let sourceSnapshot = sources.filter { source in
      source.capabilities.contains(.navigationRoutes)
        && source.navigationSchemes.contains(scheme)
    }
    guard !sourceSnapshot.isEmpty else {
      FlashLog.debug("[navigation] no route handler scheme=\(scheme) url=\(url.absoluteString)")
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }

    func attempt(_ index: Int) {
      guard index < sourceSnapshot.count else {
        DispatchQueue.main.async { completion(.unhandled) }
        return
      }
      let source = sourceSnapshot[index]
      source.restoreNavigation(to: url, environment: env) { result in
        FlashLog.trace(
          "[navigation] source=\(source.identifier) scheme=\(scheme) disposition=\(result.disposition)"
        )
        switch result.disposition {
        case .performed, .failed:
          completion(result)
        case .unhandled:
          attempt(index + 1)
        }
      }
    }

    attempt(0)
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
    return pluginSources.first { source in Self.source(source, owns: identifier) }
  }

  private static func source(_ source: FlashSource, owns identifier: String) -> Bool {
    source.identifier == identifier || identifier.hasPrefix(source.identifier + ".")
  }

  private func location(in candidates: [Candidate], matchingURLString raw: String) -> Candidate? {
    let normalized = Self.normalizedLocationURL(raw)
    guard !normalized.isEmpty else { return nil }
    return candidates.first { candidate in
      if let url = candidate.url, Self.normalizedLocationURL(url.absoluteString) == normalized {
        return true
      }
      if let navigationURL = candidate.navigationURL,
        Self.normalizedLocationURL(navigationURL.absoluteString) == normalized
      {
        return true
      }
      return false
    }
  }

  private static func normalizedLocationURL(_ raw: String) -> String {
    let trimmed = raw.trimmed
    guard !trimmed.isEmpty else { return "" }
    if let components = URLComponents(string: trimmed) {
      var normalized = components
      normalized.scheme = components.scheme?.lowercased()
      normalized.host = components.host?.lowercased()
      let rendered = normalized.string ?? trimmed
      if rendered.count > 1, rendered.hasSuffix("/") {
        return String(rendered.dropLast()).lowercased()
      }
      return rendered.lowercased()
    }
    return trimmed.lowercased()
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
    let allSources = sources
    var passingChain: [String] = []
    var excluded: [String] = []
    var sourceSnapshot: [FlashSource] = []
    for source in allSources {
      let hasCap = source.capabilities.contains(capability)
      let supports = source.supports(context)
      if hasCap, supports {
        sourceSnapshot.append(source)
        passingChain.append(source.identifier)
      } else {
        let reason =
          !hasCap
          ? "missing_cap[has=\(source.capabilities.traceDescription)]"
          : "no_supports[bundle=\(context.bundleIdentifier)]"
        excluded.append("\(source.identifier)(\(reason))")
      }
    }
    sourceSnapshot.sort { lhs, rhs in
      let lhsPriority = lhs.priority(in: context)
      let rhsPriority = rhs.priority(in: context)
      if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
      return lhs.identifier < rhs.identifier
    }
    passingChain = sourceSnapshot.map(\.identifier)
    if !excluded.isEmpty {
      FlashLog.trace(
        "[source_action] action=\(capability.traceDescription) "
          + "excluded=[\(excluded.joined(separator: ","))]")
    }
    guard !sourceSnapshot.isEmpty else {
      FlashLog.trace(
        "[source_action] action=\(capability.traceDescription) considered=\(allSources.count) "
          + "passing=0 refresh_ms=\(refreshMs) unhandled "
          + "bundle=\(context.bundleIdentifier)")
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    FlashLog.trace(
      "[source_action] action=\(capability.traceDescription) "
        + "chain=[\(passingChain.joined(separator: ","))] "
        + "refresh_ms=\(refreshMs)")

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
