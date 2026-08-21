import AppKit
import Darwin
import FlashCore
import Foundation

/// Thin `FlashSource` adapter over one plugin: candidates are a synchronous
/// read of the host-owned catalog store (first paint never waits on a
/// plugin); search/evaluate/hints/perform pass straight through to the
/// process. No pre-flight, no availability bookkeeping — a stopped plugin's
/// requests settle empty inside `PluginProcess`.
final class PluginFlashSource: FlashSource, FlashQueryEvaluator {
  private let plugin: PluginProcess
  private let store: PluginCatalogStore
  private let selector: PluginSelectorStack

  init(plugin: PluginProcess, store: PluginCatalogStore) {
    self.plugin = plugin
    self.store = store
    self.selector = PluginSelectorStack([plugin.manifest.selector])
  }

  var identifier: String { "plugin:\(plugin.identifier)" }
  var displayName: String { plugin.manifest.name }
  var priority: Int { plugin.manifest.priority }
  func priority(in context: AppContext) -> Int {
    priority + (selector.specificity(in: selectorContext(for: context)) ?? 0)
  }
  var capabilities: FlashSourceCapabilities {
    // Each capability group is gated on the matching manifest opt-in so a
    // plugin only advertises what it declares. `.jumpTargets` follows `hints`
    // because hint selection is exclusive (highest-priority provider wins, no
    // fallback) — an empty-returning plugin must not displace the core AX walk.
    var caps: FlashSourceCapabilities = []
    if plugin.manifest.providesHints { caps.insert(.jumpTargets) }
    if plugin.manifest.providesCandidates {
      caps.formUnion([.candidates, .appActivation])
    }
    caps.formUnion(Self.sourceActionCapabilities(plugin.manifest.actions))
    if !plugin.manifest.navigationSchemes.isEmpty {
      caps.insert(.navigationRoutes)
    }
    return caps
  }
  var activationPolicy: FlashSourceActivationPolicy {
    let manifestBundles = Set(plugin.manifest.onlyBundleIDs)
    return manifestBundles.isEmpty ? .always : .bundleIDs(manifestBundles)
  }
  /// Hints are always a live wire request now — never cache a prepared
  /// model of plugin targets.
  var readinessPolicy: FlashSourceReadinessPolicy {
    plugin.manifest.providesHints ? .volatile : .continuous
  }
  var resultsAreVolatile: Bool { plugin.manifest.providesHints }
  var fallsBackOnEmptyDiscovery: Bool {
    plugin.manifest.hints?.fallbackOnEmpty ?? false
  }
  var candidateSourceLabels: [String] { plugin.manifest.candidateSources }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    plugin.manifest.candidateSourceDescriptors
  }
  /// Manifest validation guarantees all-warm or all-live, so the adapter
  /// classifies whole: a live plugin never serves warm catalogs and only
  /// participates in explicitly scoped queries.
  var servesLiveCandidates: Bool {
    plugin.manifest.sources.contains(where: \.live)
  }
  var navigationSchemes: Set<String> { Set(plugin.manifest.navigationSchemes) }
  var queryEvaluatorIdentifier: String { identifier }
  var queryEvaluationPriority: Int { plugin.manifest.priority }
  var queryEvaluationSurfaces: Set<QueryEvaluationSurface> {
    plugin.manifest.providesQueryEvaluation ? [.flashlight] : []
  }
  var queryEvaluationPrefixes: Set<String> {
    Set(plugin.manifest.query?.prefixes ?? [])
  }

  func supports(_ context: AppContext) -> Bool {
    guard selector.matches(selectorContext(for: context)) else { return false }
    return plugin.manifest.providesHints
      || plugin.manifest.providesCandidates
      || plugin.manifest.providesQueryEvaluation
      || !plugin.manifest.actions.isEmpty
      || !plugin.manifest.navigationSchemes.isEmpty
  }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    plugin.discoverTargets(
      context: context,
      timeout: Double(FlashTunables.flashlightLiveQueryTimeoutMs) / 1_000)
  }

  /// Warm candidates are a synchronous host-memory read of the push-based
  /// catalog store — the plugin published them earlier (or hasn't, and the
  /// read is an authoritative empty).
  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    _ = environment
    _ = scope
    guard !servesLiveCandidates else { return [] }
    return store.rows(for: plugin.identifier)
  }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    _ = environment
    guard servesLiveCandidates else {
      DispatchQueue.main.async { completion([]) }
      return
    }
    let startedNs = DispatchTime.now().uptimeNanoseconds
    plugin.search(
      matching: text,
      scope: scope,
      timeoutMs: FlashTunables.flashlightLiveQueryTimeoutMs
    ) { [identifier = identifier] candidates in
      let elapsedMs = Int(
        (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
      FlashLog.trace(
        "[candidate_finder] plugin_search source=\(identifier) "
          + "ms=\(elapsedMs) count=\(candidates?.count ?? -1)")
      completion(candidates ?? [])
    }
  }

  func evaluateQuery(
    _ request: QueryEvaluationRequest,
    in environment: FlashSourceEnvironment,
    completion: @escaping ([Candidate]) -> Void
  ) {
    _ = environment
    guard queryEvaluationSurfaces.contains(request.surface) else {
      completion([])
      return
    }
    plugin.evaluate(request, completion: completion)
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    _ = environment
    // The plugin owns the location-changing side effect. The host raises the
    // returned target pid after a successful resolve; pre-activating here
    // makes failed resolves look like successful app-only opens.
    plugin.perform(
      kind: "resolve",
      params: ["row": PluginWireCodec.candidateJSON(candidate)]
    ) { outcome in
      switch outcome {
      case .performed(let pid, let navigationURL, _):
        completion(.resolved(pid: pid, navigationURL: navigationURL))
      case .unhandled, .failed:
        completion(.unresolved)
      }
    }
  }

  func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    _ = environment
    guard
      plugin.manifest.supportsAction(
        action.wireName,
        context: selectorContext(for: context))
    else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    var params: [String: Any] = [
      "name": action.wireName,
      "context": PluginWireCodec.contextJSON(context),
    ]
    if !action.wireExtras.isEmpty {
      params["args"] = action.wireExtras
    }
    plugin.perform(kind: "action", params: params) { outcome in
      completion(Self.sourceActionResult(from: outcome))
    }
  }

  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    _ = environment
    plugin.perform(kind: "navigate", params: ["url": url.absoluteString]) { outcome in
      completion(Self.sourceActionResult(from: outcome))
    }
  }

  /// Trichotomy → source-action tri-state. `.failed` (including timeout and
  /// crash coercions) must never fall through to a keystroke fallback.
  private static func sourceActionResult(from outcome: PluginPerformOutcome) -> SourceActionResult {
    switch outcome {
    case .performed(let pid, let navigationURL, _):
      return .performed(pid: pid, navigationURL: navigationURL)
    case .unhandled:
      return .unhandled
    case .failed:
      return .failed
    }
  }

  private func selectorContext(for context: AppContext) -> PluginSelectorContext {
    PluginSelectorContext(bundleID: context.bundleIdentifier)
  }

  private static func sourceActionCapabilities(_ actions: [String]) -> FlashSourceCapabilities {
    var caps: FlashSourceCapabilities = []
    for action in actions {
      switch action {
      case "tab_select":
        caps.insert(.tabSelection)
      case "tab_next", "tab_prev", "tab_previous", "tab_first", "tab_last":
        caps.insert(.tabNavigation)
      case "tab_new":
        caps.insert(.tabCreation)
      case "tab_close":
        caps.insert(.tabClosing)
      case "tab_move_previous", "tab_move_next":
        caps.insert(.tabReorder)
      case "pane_next", "pane_previous":
        caps.insert(.paneNavigation)
      case "pane_split_vertical", "pane_split_horizontal":
        caps.insert(.paneSplitting)
      case "pane_close":
        caps.insert(.paneClosing)
      case "tab_reopen":
        caps.insert(.tabReopen)
      case "scroll_top", "scroll_bottom":
        caps.insert(.scrollExtremes)
      case "app_reload":
        caps.insert(.reload)
      case "resource_archive":
        caps.insert(.resourceArchiving)
      case "resource_next", "resource_previous":
        caps.insert(.resourceNavigation)
      default:
        break
      }
    }
    return caps
  }
}
