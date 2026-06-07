import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginFlashSource: FlashSource {
  private let plugin: PluginProcess

  init(plugin: PluginProcess) {
    self.plugin = plugin
  }

  var identifier: String { "plugin.\(plugin.identifier)" }
  var displayName: String { plugin.manifest.name }
  var priority: Int { plugin.manifest.priority }
  var capabilities: FlashSourceCapabilities {
    [
      .jumpTargets, .candidates, .appActivation, .tabSelection, .tabCreation, .tabNavigation,
      .tabClosing,
    ]
  }
  var activationPolicy: FlashSourceActivationPolicy {
    let manifestBundles = Set(plugin.manifest.bundleIDs)
    return manifestBundles.isEmpty ? .always : .bundleIDs(manifestBundles)
  }
  var readinessPolicy: FlashSourceReadinessPolicy {
    plugin.manifest.volatile ? .volatile : .continuous
  }
  var resultsAreVolatile: Bool { plugin.manifest.volatile }

  func supports(_ context: AppContext) -> Bool {
    let manifestBundles = plugin.manifest.bundleIDs
    if !manifestBundles.isEmpty {
      return manifestBundles.contains(context.bundleIdentifier)
    }
    let event = PluginEvent(
      name: "focus.changed",
      payload: [:],
      bundleID: context.bundleIdentifier,
      configPath: nil,
      focused: true)
    return plugin.manifest.events.isEmpty || plugin.manifest.events.contains { $0.matches(event) }
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

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(
      name: "tab_select",
      context: context,
      extra: ["index": index],
      completion: completion)
  }

  func tabNext(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_next", context: context, extra: [:], completion: completion)
  }

  func tabPrev(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_prev", context: context, extra: [:], completion: completion)
  }

  func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_new", context: context, extra: [:], completion: completion)
  }

  func tabClose(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_close", context: context, extra: [:], completion: completion)
  }
}
