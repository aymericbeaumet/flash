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
  private let lock = NSLock()
  private var activeSourcesByID: [String: FlashSource] = [:]
  private var runningApplications: [NSRunningApplication] = []
  private var openConfig: Config.Open

  init(
    descriptors: [SourceDescriptor]? = nil,
    openConfig: Config.Open = .init(),
    terminalBundleIDs: Set<String> = TmuxProvider.terminalBundles,
    runningApplications: [NSRunningApplication]? = nil,
    runningApplicationsProvider: (() -> [NSRunningApplication])? = nil
  ) {
    let initialRunningApplications =
      runningApplications ?? runningApplicationsProvider?() ?? NSWorkspace.shared.runningApplications
    if let runningApplicationsProvider {
      self.runningApplicationsProvider = runningApplicationsProvider
    } else if runningApplications != nil {
      self.runningApplicationsProvider = { initialRunningApplications }
    } else {
      self.runningApplicationsProvider = { NSWorkspace.shared.runningApplications }
    }
    self.terminalBundleIDs = terminalBundleIDs
    self.openConfig = openConfig
    self.descriptors =
      descriptors
      ?? [
        SourceDescriptor(identifier: "app", activationPolicy: .always) {
          ApplicationSource(ignoredApps: openConfig.ignoredApps)
        },
        SourceDescriptor(identifier: "accessibility", activationPolicy: .always) {
          AccessibilityProvider()
        },
        SourceDescriptor(identifier: "tmux", activationPolicy: .terminalBundles) {
          TmuxProvider()
        },
        SourceDescriptor(
          identifier: "firefox-tabs",
          activationPolicy: .bundleIDs(BrowserTabSources.firefoxBundleIdentifiers)
        ) {
          FirefoxTabsSource()
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
        SourceDescriptor(
          identifier: "slack",
          activationPolicy: .bundleIDs(SlackSource.bundleIdentifiers)
        ) {
          SlackSource()
        },
      ]
    refreshRunningApplications(initialRunningApplications)
  }

  func updateOpenConfig(_ openConfig: Config.Open) {
    lock.lock()
    self.openConfig = openConfig
    let appSource = activeSourcesByID["app"] as? ApplicationSource
    lock.unlock()
    appSource?.updateIgnoredApps(openConfig.ignoredApps)
  }

  var sources: [FlashSource] {
    lock.lock()
    defer { lock.unlock() }
    return activeSourcesByID.values.sorted { lhs, rhs in
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
    return sources
      .filter { $0.capabilities.contains(.jumpTargets) && $0.supports(context) }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.identifier < rhs.identifier
      }
  }

  func continuousSources(for context: AppContext) -> [FlashSource] {
    chain(for: context).filter { $0.readinessPolicy == .continuous }
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
    for source in sourceSnapshot {
      if let item = source.candidate(matching: target, in: env) {
        return CandidateFinder.prepare(item)
      }
    }
    return nil
  }

  func candidate(forProcessID pid: pid_t) -> Candidate? {
    refreshRunningApplications()
    let env = environment
    for source in sources where source.identifier == "app" {
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
      where source.capabilities.contains(.documentURL)
    {
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

  func source(identifier: String) -> FlashSource? {
    lock.lock()
    defer { lock.unlock() }
    return activeSourcesByID[identifier]
  }

  private func performSourceAction(
    capability: FlashSourceCapabilities,
    context: AppContext,
    completion: @escaping (SourceActionResult) -> Void,
    action: @escaping (FlashSource, FlashSourceEnvironment, @escaping (SourceActionResult) -> Void)
      -> Void
  ) {
    refreshRunningApplications()
    let env = environment
    let sourceSnapshot = sources.filter {
      $0.capabilities.contains(capability) && $0.supports(context)
    }
    guard !sourceSnapshot.isEmpty else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }

    func attempt(_ index: Int) {
      guard index < sourceSnapshot.count else {
        completion(.unhandled)
        return
      }
      let source = sourceSnapshot[index]
      action(source, env) { result in
        if result.didPerform {
          completion(result)
        } else {
          attempt(index + 1)
        }
      }
    }
    attempt(0)
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
