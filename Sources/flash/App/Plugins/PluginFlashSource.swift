import AppKit
import Darwin
import FlashCore
import Foundation

/// Thin `FlashSource` adapter over one plugin: candidates are a synchronous
/// read of the host-owned catalog store (first paint never waits on a
/// plugin); evaluate/hints/text_grid/perform pass straight through to the
/// process. No pre-flight, no availability bookkeeping — a stopped plugin's
/// requests settle empty inside `PluginProcess`.
final class PluginFlashSource: FlashSource, FlashQueryEvaluator {
  private let plugin: PluginProcess
  private let store: PluginCatalogStore
  private let selector: PluginSelectorStack
  /// The core commands the manifest declares, read once: the registry's
  /// chain asks for them on every repeated NORMAL mapping.
  let commands: Set<CommandName>

  init(plugin: PluginProcess, store: PluginCatalogStore) {
    self.plugin = plugin
    self.store = store
    self.selector = PluginSelectorStack([plugin.manifest.selector])
    self.commands = plugin.manifest.sourceCommands
  }

  var identifier: String { "plugin:\(plugin.identifier)" }
  /// The plugin answers every `!<bang>` (manifest `bangs` token `*`): its
  /// catalog is where the bang list's rows come from.
  var answersEveryBang: Bool { plugin.manifest.bangs.contains { $0.token == "*" } }
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
    if !plugin.manifest.navigationSchemes.isEmpty {
      caps.insert(.navigationRoutes)
    }
    return caps
  }
  /// Registry-level gate (is any matching app running?); the per-context
  /// selector match happens in `supports(_:)`. A terminal-scoped plugin is
  /// instantiated only while a known terminal emulator runs, and is never
  /// consulted for hints in any other app — which is what keeps the warm
  /// prepared-model path zero-hop outside terminals. A warm catalog the user
  /// reaches by name rather than through the default pool (browser history
  /// and bookmarks: `@history`, `!fh`) is a host-store read whatever
  /// runs, so a plugin declaring one stays active while none of its apps
  /// does; `supports(_:)` still scopes its hints and commands to them.
  var activationPolicy: FlashSourceActivationPolicy {
    if plugin.manifest.selector.onlyTerminals { return .terminalBundles }
    let manifestBundles = Set(plugin.manifest.onlyBundleIDs)
    if manifestBundles.isEmpty || servesNamedCatalog { return .always }
    return .bundleIDs(manifestBundles)
  }
  /// A declared candidate source outside the default location pool.
  private var servesNamedCatalog: Bool {
    plugin.manifest.candidateSourceDescriptors.contains { $0.kind != .locations }
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
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    plugin.manifest.candidateSourceDescriptors
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
      || !commands.isEmpty
      || !plugin.manifest.navigationSchemes.isEmpty
  }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    plugin.discoverTargets(
      context: context,
      timeout: Double(FlashTunables.hintProviderTimeoutMs) / 1_000)
  }

  /// The plugin's text grid of `context` for a letter search; see
  /// `PluginProcess.textGrid`. Asked only of a hint provider for `context`.
  func textGrid(in context: AppContext, completion: @escaping (PluginTextGrid?) -> Void) {
    plugin.textGrid(context: context, completion: completion)
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
    return store.rows(for: plugin.identifier)
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

  /// A core command the manifest declares, asked in an app the selector
  /// matches: the same `perform {kind: "command"}` as the plugin's own
  /// commands, with the argument words a mapping wrote and, because it is a
  /// core command, the focused app as `context`.
  func perform(
    _ command: SourceCommand,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  ) {
    _ = environment
    guard commands.contains(command.name), selector.matches(selectorContext(for: context)) else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let params: [String: Any] = [
      "command": command.name.topic,
      "subcommand": command.name.action,
      "args": command.arguments,
      "context": PluginWireCodec.contextJSON(context),
    ]
    plugin.perform(kind: "command", params: params) { outcome in
      completion(Self.sourceCommandResult(from: outcome))
    }
  }

  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  ) {
    _ = environment
    plugin.perform(kind: "navigate", params: ["url": url.absoluteString]) { outcome in
      completion(Self.sourceCommandResult(from: outcome))
    }
  }

  /// Trichotomy → source-command tri-state. `.failed` (including timeout and
  /// crash coercions) must never fall through to a keystroke fallback.
  private static func sourceCommandResult(from outcome: PluginPerformOutcome) -> SourceCommandResult
  {
    switch outcome {
    case .performed(let pid, let navigationURL, _):
      return .performed(pid: pid, navigationURL: navigationURL)
    case .unhandled:
      return .unhandled
    case .failed(let reason):
      return .failed(reason: reason)
    }
  }

  private func selectorContext(for context: AppContext) -> PluginSelectorContext {
    PluginSelectorContext(bundleID: context.bundleIdentifier)
  }
}
