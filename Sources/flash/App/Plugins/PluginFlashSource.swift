import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginFlashSource: FlashSource {
  private let plugin: PluginProcess

  init(plugin: PluginProcess) {
    self.plugin = plugin
  }

  var identifier: String { "plugin:\(plugin.identifier)" }
  var displayName: String { plugin.manifest.name }
  var priority: Int { plugin.manifest.priority }
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
    let manifestBundles = Set(plugin.manifest.bundleIDs)
    return manifestBundles.isEmpty ? .always : .bundleIDs(manifestBundles)
  }
  var readinessPolicy: FlashSourceReadinessPolicy {
    plugin.manifest.volatile ? .volatile : .continuous
  }
  var resultsAreVolatile: Bool { plugin.manifest.volatile }
  var candidateSourceLabels: [String] { plugin.manifest.candidateSources }
  var navigationSchemes: Set<String> { Set(plugin.manifest.navigationSchemes) }

  func supports(_ context: AppContext) -> Bool {
    let manifestBundles = plugin.manifest.bundleIDs
    if !manifestBundles.isEmpty {
      return manifestBundles.contains(context.bundleIdentifier)
    }
    if plugin.manifest.providerSupports(bundleID: context.bundleIdentifier) {
      return true
    }
    let event = PluginEvent(
      name: "core:focus.changed",
      payload: [:],
      bundleID: context.bundleIdentifier,
      configPath: nil,
      focused: true)
    return plugin.manifest.subscriptions.contains { $0.matches(event) }
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
    // Flashlight reads this lock-backed snapshot synchronously when the panel
    // opens. Do not replace this with `queryCandidates`; visible command-bar
    // rows must not depend on a session-time plugin RPC.
    plugin.candidates(scope: scope)
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
    // Activate the candidate's owning app on the main thread before
    // the plugin runs its own resolve. Without this step a tmux
    // window pick would correctly run `switch-client` but the
    // terminal app would stay in the background, so the user has
    // to manually click it to see the new window.
    if let pid = candidate.pid,
      let app = NSRunningApplication(processIdentifier: pid)
    {
      DispatchQueue.main.async {
        RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      }
    }
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
    guard plugin.manifest.supportsSourceAction(action.wireName, bundleID: context.bundleIdentifier)
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
