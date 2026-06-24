import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginFlashSource: FlashSource {
  private let plugin: PluginProcess
  private let selector: PluginSelectorStack

  init(plugin: PluginProcess) {
    self.plugin = plugin
    self.selector = PluginSelectorStack([plugin.manifest.selector])
  }

  var identifier: String { "plugin:\(plugin.identifier)" }
  var displayName: String { plugin.manifest.name }
  var priority: Int { plugin.manifest.priority }
  func priority(in context: AppContext) -> Int {
    priority + (selector.specificity(in: selectorContext(for: context)) ?? 0)
  }
  var capabilities: FlashSourceCapabilities {
    // Each capability group is gated on the matching provider opt-in so a
    // plugin only advertises what it declares. `.jumpTargets` follows `hints`
    // because hint selection is exclusive (highest-priority provider wins, no
    // fallback) — an empty-returning plugin must not displace the core AX walk.
    // Discrete source actions are intentionally not inferred from candidates:
    // a generic candidate plugin should not be asked whether it owns `tab_new`
    // or `app_reload`.
    var caps: FlashSourceCapabilities = []
    if plugin.manifest.providesHints { caps.insert(.jumpTargets) }
    if plugin.manifest.providesCandidates {
      caps.formUnion([.candidates, .appActivation])
    }
    caps.formUnion(Self.sourceActionCapabilities(plugin.manifest.sourceActions))
    if !plugin.manifest.navigationSchemes.isEmpty {
      caps.insert(.navigationRoutes)
    }
    return caps
  }
  var activationPolicy: FlashSourceActivationPolicy {
    let manifestBundles = Set(plugin.manifest.onlyBundleIDs)
    return manifestBundles.isEmpty ? .always : .bundleIDs(manifestBundles)
  }
  var readinessPolicy: FlashSourceReadinessPolicy {
    plugin.manifest.volatile ? .volatile : .continuous
  }
  var resultsAreVolatile: Bool { plugin.manifest.volatile }
  var candidateSourceLabels: [String] { plugin.manifest.candidateSources }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    plugin.manifest.candidateSourceDescriptors
  }
  var navigationSchemes: Set<String> { Set(plugin.manifest.navigationSchemes) }

  func supports(_ context: AppContext) -> Bool {
    guard selector.matches(selectorContext(for: context)) else { return false }
    return plugin.manifest.providesHints
      || plugin.manifest.providesCandidates
      || !plugin.manifest.sourceActions.isEmpty
      || !plugin.manifest.navigationSchemes.isEmpty
  }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    if plugin.manifest.volatile {
      return plugin.discoverTargets(context: context, timeout: 0.5)
    }
    return plugin.targets(for: context)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    // Plugin candidates are pulled, not pushed: the host queries warm plugins
    // via `queryCandidates` when the flashlight opens (and on `@source`/`!`).
    // There is no synchronous snapshot to read here.
    []
  }

  func queryCandidates(
    in environment: FlashSourceEnvironment,
    request: CandidateQuery,
    completion: @escaping ([Candidate]) -> Void
  ) {
    let startedNs = DispatchTime.now().uptimeNanoseconds
    plugin.queryCandidates(
      scope: request.scope,
      query: request.text,
      environment: environment
    ) { [identifier = identifier] candidates in
      let elapsedMs = Int(
        (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
      if candidates.isEmpty {
        // Empty result is the diagnostic-interesting case: distinguish "the
        // plugin isn't ready" from "the plugin ran but has nothing to
        // contribute". The plugin's lifecycle state and snapshot freshness
        // tell the user whether to wait, reload, or check focus events.
        FlashLog.trace(
          "[candidate_finder] plugin_query source=\(identifier) "
            + "ms=\(elapsedMs) count=0 query=\"\(request.text)\"")
      } else {
        FlashLog.trace(
          "[candidate_finder] plugin_query source=\(identifier) "
            + "ms=\(elapsedMs) count=\(candidates.count)")
      }
      completion(candidates)
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    // The plugin owns the location-changing side effect. The host raises the
    // returned target pid after a successful resolve; pre-activating here makes
    // failed resolves look like successful app-only opens.
    plugin.resolveCandidate(candidate, completion: completion)
  }

  func candidate(matching target: String, in environment: FlashSourceEnvironment) -> Candidate? {
    candidates(in: environment, scope: .all).first {
      $0.title.localizedCaseInsensitiveContains(target)
        || $0.displayTitle.localizedCaseInsensitiveContains(target)
    }
  }

  func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard
      plugin.manifest.supportsSourceAction(
        action.wireName,
        context: selectorContext(for: context))
    else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    // The wire format (`SourceActionRequest { name, index }`) is already a
    // single shape on the plugin side, so this method translates the host's
    // typed `SourceAction` into the matching wire fields and posts one
    // `sourceAction` RPC — no per-action dispatch fan-out.
    plugin.invokeSourceAction(
      name: action.wireName,
      context: context,
      extra: action.wireExtras,
      completion: completion)
  }

  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.restoreNavigation(to: url, completion: completion)
  }

  private func selectorContext(for context: AppContext) -> PluginSelectorContext {
    PluginSelectorContext(
      bundleID: context.bundleIdentifier,
      url: selector.usesURL ? NormalModeDispatcher.documentURL(pid: context.processID) : nil)
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
