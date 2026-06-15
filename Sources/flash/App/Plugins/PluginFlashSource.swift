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
    // The candidate/app-activation/tab caps follow `candidates` so a
    // commands-only plugin isn't consulted on every flashlight query.
    var caps: FlashSourceCapabilities = []
    if plugin.manifest.providesHints { caps.insert(.jumpTargets) }
    if plugin.manifest.providesCandidates {
      caps.formUnion([
        .candidates, .appActivation, .tabSelection, .tabCreation, .tabNavigation, .tabClosing,
      ])
    }
    // Scroll extremes / tab reorder piggy-back on hint provision: the
    // plugins that need them (terminal sources like tmux) are exactly
    // the ones that claim hint discovery for their app. Returning
    // `.unhandled` is cheap for plugins that don't implement the
    // matching source actions.
    if plugin.manifest.providesHints {
      caps.formUnion([.scrollExtremes, .tabReorder])
    }
    // `tabReopen` follows candidate provision: browser plugins want it
    // (they're the ones with a closed-tabs history); tmux does not.
    if plugin.manifest.providesCandidates {
      caps.insert(.tabReopen)
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

  func supports(_ context: AppContext) -> Bool {
    let manifestBundles = plugin.manifest.bundleIDs
    if !manifestBundles.isEmpty {
      return manifestBundles.contains(context.bundleIdentifier)
    }
    let event = PluginEvent(
      name: "core:focus.changed",
      payload: [:],
      bundleID: context.bundleIdentifier,
      configPath: nil,
      focused: true)
    return plugin.manifest.subscriptions.isEmpty
      || plugin.manifest.subscriptions.contains { $0.matches(event) }
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
      sourceFilters: request.sourceFilters,
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
      $0.name.localizedCaseInsensitiveContains(target)
        || $0.displayTitle.localizedCaseInsensitiveContains(target)
    }
  }

  func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
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
}
