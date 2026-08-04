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
  private struct PluginSnapshotReply {
    let source: FlashSource
    let candidates: [Candidate]
  }

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
    return (builtIn + activePluginSources()).sorted { lhs, rhs in
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

  func coreAppCandidates(scope: CandidateScope) -> [Candidate] {
    let env = environment
    guard let source = source(identifier: "core.apps") else { return [] }
    return CandidateFinder.prepare(source.candidates(in: env, scope: scope))
  }

  /// Candidates from in-process built-in sources for non-first-paint
  /// consumers. Flashlight first paint routes `core.apps` through
  /// `initialCandidateSnapshotSources()` so it can await only an already-running
  /// resident prewarm without performing activation-time I/O.
  func synchronousCandidates(scope: CandidateScope) -> [Candidate] {
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

  /// Resolve one complete, ephemeral candidate snapshot without retaining a
  /// host cache. Built-in warm sources contribute synchronously; active plugin
  /// stores are pulled in parallel and published once when all settle or the
  /// bounded timeout expires. Completion always runs on the main queue.
  func snapshotCandidates(
    scope: CandidateScope,
    timeoutMs: Int = 150,
    completion: @escaping ([Candidate]) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.snapshotCandidates(scope: scope, timeoutMs: timeoutMs, completion: completion)
      }
      return
    }
    let builtIn = synchronousCandidates(scope: scope)
    let plugins =
      activePluginSources()
      .filter { $0.capabilities.contains(.candidates) }
    gatherPluginSnapshots(
      plugins,
      scope: scope,
      timeoutMs: timeoutMs,
      operation: "candidate_snapshot"
    ) { replies in
      var aggregate = builtIn
      for reply in replies {
        aggregate.append(contentsOf: CandidateFinder.prepare(reply.candidates))
      }
      completion(aggregate)
    }
  }

  /// Location-only variant for movement/mark resolution. Avoids pulling warm
  /// emoji, notes, contacts, and other non-navigational catalogs on every focus
  /// change.
  func locationSnapshotCandidates(
    scope: CandidateScope,
    timeoutMs: Int = 150,
    completion: @escaping ([Candidate]) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.locationSnapshotCandidates(
          scope: scope,
          timeoutMs: timeoutMs,
          completion: completion)
      }
      return
    }
    let builtIn = synchronousCandidates(scope: scope)
    gatherPluginSnapshots(
      locationCandidateSources(),
      scope: scope,
      timeoutMs: timeoutMs,
      operation: "location_snapshot"
    ) { replies in
      var aggregate = builtIn
      for reply in replies {
        aggregate.append(contentsOf: CandidateFinder.prepare(reply.candidates))
      }
      completion(aggregate)
    }
  }

  /// Plugin candidate sources that contribute location rows to the default
  /// flashlight pool — those declaring a `kind: .locations` descriptor at normal
  /// priority or above. The hidden initial barrier fans these out via
  /// `snapshotCandidates` before the first candidate reveal. Built-ins are
  /// excluded because callers gather them through their built-in path.
  func locationCandidateSources() -> [FlashSource] {
    return activePluginSources().filter { Self.isLocationCandidateSource($0) }
  }

  /// Every source whose complete location snapshot must be frozen before the
  /// first flashlight publication. Unlike later gathers this includes built-in
  /// candidate sources: `core.apps` may still be awaiting its resident-startup
  /// index and therefore participates in the same host deadline as plugins.
  func initialCandidateSnapshotSources() -> [FlashSource] {
    lock.lock()
    let builtIn = activeSourcesByID.values.filter(Self.isLocationCandidateSource)
    lock.unlock()
    var byID: [String: FlashSource] = [:]
    for source in builtIn + locationCandidateSources() {
      byID[source.identifier] = source
    }
    return byID.values.sorted { $0.identifier < $1.identifier }
  }

  /// Plugin candidate sources that do NOT contribute default-pool location rows
  /// — emojis, search-engine bangs, notes, contacts, etc. These are pulled
  /// lazily the first time the user types an `@source`/`!`bang filter, not on
  /// open.
  func nonLocationCandidateSources(matching sourceFilter: String? = nil) -> [FlashSource] {
    return activePluginSources().filter { source in
      source.capabilities.contains(.candidates) && !Self.isLocationCandidateSource(source)
        && sourceFilter.map { filter in
          source.candidateSourceDescriptors.contains { descriptor in
            CandidateFinder.sourceLabel(descriptor.name, matchesFilter: filter)
          }
        } != false
    }
  }

  /// Plugin adapters may stay resident while their owning applications are
  /// closed. Apply the same manifest activation policy as built-in descriptors
  /// before any snapshot or query so inactive browser plugins never join the
  /// flashlight fan-out.
  private func activePluginSources() -> [FlashSource] {
    lock.lock()
    let applications = runningApplications
    lock.unlock()
    return pluginSourcesProvider().filter { source in
      Self.activationPolicyMatches(
        source.activationPolicy,
        runningApplications: applications,
        terminalBundleIDs: terminalBundleIDs)
    }
  }

  /// One-shot parallel fan-in for plugin-owned warm stores. The host never
  /// retains these replies. Duplicate callbacks and replies after the deadline
  /// are ignored, and output order is stable by source id.
  private func gatherPluginSnapshots(
    _ rawSources: [FlashSource],
    scope: CandidateScope,
    timeoutMs: Int,
    operation: String,
    completion: @escaping ([PluginSnapshotReply]) -> Void
  ) {
    var sourcesByID: [String: FlashSource] = [:]
    for source in rawSources {
      sourcesByID[source.identifier] = source
    }
    let sources = sourcesByID.values.sorted { $0.identifier < $1.identifier }
    guard !sources.isEmpty else {
      completion([])
      return
    }

    let timeoutMs = max(1, timeoutMs)
    let env = environment
    var pending = Set(sources.map(\.identifier))
    var replies: [String: PluginSnapshotReply] = [:]
    var finished = false

    func finish(timedOut: Bool) {
      guard !finished else { return }
      finished = true
      if timedOut, !pending.isEmpty {
        FlashLog.warn(
          "[plugin_snapshot] aggregate_timeout operation=\(operation) "
            + "timeout_ms=\(timeoutMs) pending=[\(pending.sorted().joined(separator: ","))]")
      }
      completion(
        sources.compactMap { source in
          replies[source.identifier]
        })
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
      finish(timedOut: true)
    }

    for source in sources {
      let startedNs = DispatchTime.now().uptimeNanoseconds
      source.snapshotCandidates(in: env, scope: scope) { candidates in
        DispatchQueue.main.async {
          guard !finished else { return }
          let elapsedMs = Self.elapsedMs(since: startedNs)
          guard pending.remove(source.identifier) != nil else {
            FlashLog.warn(
              "[plugin_snapshot] duplicate source=\(source.identifier) operation=\(operation)")
            return
          }
          replies[source.identifier] = PluginSnapshotReply(
            source: source,
            candidates: candidates)
          if elapsedMs >= 100 {
            FlashLog.warn(
              "[plugin_snapshot] slow source=\(source.identifier) operation=\(operation) "
                + "elapsed_ms=\(elapsedMs) count=\(candidates.count)")
          }
          if pending.isEmpty {
            finish(timedOut: false)
          }
        }
      }
    }
  }

  private static func isLocationCandidateSource(_ source: FlashSource) -> Bool {
    source.capabilities.contains(.candidates)
      && source.candidateSourceDescriptors.contains { descriptor in
        descriptor.kind == .locations
      }
  }

  var snapshotEnvironment: FlashSourceEnvironment { environment }

  /// Evaluate one exact input against every plugin that registered for the
  /// requested surface. Results are ephemeral: the host returns at most once,
  /// after every evaluator settles or the fixed CPU-path budget expires, and
  /// ignores late replies. Callers own query generations and must discard a
  /// completion whose input is no longer current.
  func evaluateQuery(
    _ request: QueryEvaluationRequest,
    timeoutMs: Int = 50,
    completion: @escaping ([Candidate]) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.evaluateQuery(request, timeoutMs: timeoutMs, completion: completion)
      }
      return
    }
    guard !request.text.trimmed.isEmpty else {
      completion([])
      return
    }
    let evaluators =
      sources
      .compactMap { $0 as? FlashQueryEvaluator }
      .filter {
        guard $0.queryEvaluationSurfaces.contains(request.surface) else { return false }
        guard let exclusivePrefix = request.exclusivePrefix else { return true }
        return $0.queryEvaluationPrefixes.contains(exclusivePrefix)
      }
      .sorted { lhs, rhs in
        if lhs.queryEvaluationPriority != rhs.queryEvaluationPriority {
          return lhs.queryEvaluationPriority > rhs.queryEvaluationPriority
        }
        return lhs.queryEvaluatorIdentifier < rhs.queryEvaluatorIdentifier
      }
    guard !evaluators.isEmpty else {
      completion([])
      return
    }

    let env = environment
    var pending = evaluators.count
    var finished = false
    var results: [String: [Candidate]] = [:]
    var settled = Set<String>()

    func finish(timedOut: Bool) {
      guard !finished else { return }
      finished = true
      if timedOut, settled.count < evaluators.count {
        let missing =
          evaluators
          .map(\.queryEvaluatorIdentifier)
          .filter { !settled.contains($0) }
          .joined(separator: ",")
        FlashLog.warn(
          "[query_evaluator] aggregate timeout_ms=\(max(1, timeoutMs)) pending=[\(missing)]")
      }
      let ordered = evaluators.flatMap {
        results[$0.queryEvaluatorIdentifier] ?? []
      }
      completion(CandidateFinder.prepare(ordered))
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(1, timeoutMs))) {
      finish(timedOut: true)
    }

    func settle(_ evaluator: FlashQueryEvaluator, candidates: [Candidate]) {
      guard !finished else { return }
      let identifier = evaluator.queryEvaluatorIdentifier
      guard settled.insert(identifier).inserted else { return }
      results[identifier] = candidates
      pending -= 1
      if pending == 0 {
        finish(timedOut: false)
      }
    }

    for evaluator in evaluators {
      evaluator.evaluateQuery(request, in: env) { candidates in
        // PluginProcess already returns query responses on main. Avoid a
        // second main-queue hop: under a busy first-paint turn that extra hop
        // can land behind the aggregate deadline even though the plugin
        // completed in time. Non-plugin evaluators retain a queue-agnostic API.
        if Thread.isMainThread {
          settle(evaluator, candidates: candidates)
        } else {
          DispatchQueue.main.async {
            settle(evaluator, candidates: candidates)
          }
        }
      }
    }
  }

  func registeredCandidateSourceLabels() -> [String] {
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

  func resolveCandidate(
    matching target: String,
    sourceID: String? = nil,
    timeoutMs: Int = 150,
    completion: @escaping (Candidate?) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.resolveCandidate(
          matching: target,
          sourceID: sourceID,
          timeoutMs: timeoutMs,
          completion: completion)
      }
      return
    }
    refreshRunningApplications()
    let env = environment
    lock.lock()
    let builtIn = Array(activeSourcesByID.values)
    lock.unlock()
    let builtInSources = builtIn.filter { source in
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
      builtInSources.filter { $0.identifier == "core.apps" }
      + builtInSources.filter { $0.identifier != "core.apps" }
    for source in ordered {
      guard let item = source.candidate(matching: target, in: env),
        !CandidateFinder.insertsText(item),
        item.effect == nil
      else { continue }
      completion(CandidateFinder.prepare(item))
      return
    }

    let plugins = activePluginSources().filter { source in
      source.capabilities.contains(.appActivation)
        && Self.isLocationCandidateSource(source)
        && (sourceID == nil || Self.source(source, owns: sourceID!))
    }
    gatherPluginSnapshots(
      plugins,
      scope: .all,
      timeoutMs: timeoutMs,
      operation: "candidate_match"
    ) { replies in
      let orderedReplies = replies.sorted { lhs, rhs in
        if lhs.source.priority != rhs.source.priority {
          return lhs.source.priority > rhs.source.priority
        }
        return lhs.source.identifier < rhs.source.identifier
      }
      for reply in orderedReplies {
        let prepared = CandidateFinder.prepare(reply.candidates)
        if let item = prepared.first(where: { candidate in
          candidate.isLocation
            && candidate.effect == nil
            && !CandidateFinder.insertsText(candidate)
            && (candidate.title.localizedCaseInsensitiveContains(target)
              || candidate.displayTitle.localizedCaseInsensitiveContains(target))
        }) {
          completion(item)
          return
        }
      }
      completion(nil)
    }
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

  func currentLocation(in context: AppContext, candidates: [Candidate]) -> Candidate? {
    let locationCandidates =
      candidates
      .filter { $0.isLocation && $0.kind != CandidateFinder.sourceKind }
    let samePID = locationCandidates.filter { $0.pid == context.processID }
    if let current = samePID.first(where: \.isCurrentLocation) {
      return current
    }
    // Zero or one same-process locations are already unambiguous. Do not ask
    // the Accessibility source for a document URL: its native-app fallback may
    // walk up to 2,000 AX nodes, and cannot change which candidate wins here.
    if samePID.isEmpty {
      return candidate(forProcessID: context.processID)
    }
    if samePID.count == 1 {
      return samePID[0]
    }
    if let documentURL = documentURL(in: context),
      let current = location(in: samePID, matchingURLString: documentURL)
    {
      return current
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
      FlashLog.debug("[navigation] no route handler scheme=\(scheme)")
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
    let pluginSources = activePluginSources()
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
