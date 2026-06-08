import AppKit
import FlashCore
import Foundation

final class ApplicationSource: FlashSource {
  let identifier = "app"
  let displayName = "app"
  let priority = 0
  let capabilities: FlashSourceCapabilities = [.candidates, .appActivation]
  let activationPolicy: FlashSourceActivationPolicy = .always
  private let cacheLock = NSLock()
  private var installedItemsCache: [Candidate]?
  private var ignoredAppMatcher: IgnoredAppMatcher

  init(ignoredApps: [String] = []) {
    self.ignoredAppMatcher = IgnoredAppMatcher(ignoredApps)
  }

  func supports(_ context: AppContext) -> Bool { false }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    []
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    let running = runningAppItems(in: environment)
    switch scope {
    case .running:
      return running
    case .all:
      return CandidateFinder.mergeAppCandidates(
        running: running,
        installed: installedAppItems())
    }
  }

  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    guard let url = resolveURL(for: target, environment: environment) else { return nil }
    let matcher = ignoredAppMatcherSnapshot()
    var pid: pid_t?
    let bundle = Bundle(url: url)
    let bundleIdentifier = bundle?.bundleIdentifier ?? ""
    for app in environment.runningApplications {
      if !bundleIdentifier.isEmpty, app.bundleIdentifier == bundleIdentifier {
        pid = app.processIdentifier
        break
      }
      if app.bundleURL == url {
        pid = app.processIdentifier
        break
      }
    }
    var item = Self.appBundleItem(fromBundleURL: url)
    item.pid = pid
    guard !matcher.contains(item) else { return nil }
    return item
  }

  func candidate(
    forProcessID pid: pid_t,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    guard
      let app = environment.runningApplications.first(where: {
        $0.processIdentifier == pid && !$0.isTerminated
      })
    else { return nil }
    return item(for: app)
  }

  func resolveCandidate(
    _ item: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    // Prefer launching by bundle URL even for already-running apps: this
    // carries the same "reopen" semantics as clicking the Dock icon, so an
    // app with zero open windows (e.g. Messages) gets a fresh window instead
    // of just being raised. `NSRunningApplication.activate` alone never
    // recreates a window.
    if let url = item.url {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      configuration.addsToRecentItems = false
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
        DispatchQueue.main.async {
          completion(.resolved(pid: app?.processIdentifier ?? item.pid))
        }
      }
      return
    }

    if let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) {
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      DispatchQueue.main.async {
        completion(.resolved(pid: pid))
      }
      return
    }

    DispatchQueue.main.async {
      completion(.unresolved)
    }
  }

  func updateIgnoredApps(_ ignoredApps: [String]) {
    cacheLock.lock()
    ignoredAppMatcher = IgnoredAppMatcher(ignoredApps)
    installedItemsCache = nil
    cacheLock.unlock()
  }

  private func ignoredAppMatcherSnapshot() -> IgnoredAppMatcher {
    cacheLock.lock()
    let matcher = ignoredAppMatcher
    cacheLock.unlock()
    return matcher
  }

  private func runningAppItems(in environment: FlashSourceEnvironment) -> [Candidate] {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    let matcher = ignoredAppMatcherSnapshot()
    return environment.runningApplications.compactMap { app in
      guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
      guard app.bundleIdentifier != flashBundleIdentifier else { return nil }
      guard let item = item(for: app), !matcher.contains(item) else { return nil }
      return item
    }
    .sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func item(for app: NSRunningApplication) -> Candidate? {
    let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !name.isEmpty else { return nil }
    return Candidate(
      kind: .app,
      sourceID: identifier,
      source: displayName,
      pid: app.processIdentifier,
      name: name,
      subtitle: "app",
      bundleIdentifier: app.bundleIdentifier ?? "",
      url: app.bundleURL)
  }

  private func resolveURL(
    for target: String,
    environment: FlashSourceEnvironment
  ) -> URL? {
    if target.hasPrefix("/") {
      return URL(fileURLWithPath: target)
    }
    let ws = NSWorkspace.shared
    if let url = ws.urlForApplication(withBundleIdentifier: target) {
      return url
    }
    let lowered = target.lowercased()
    if let url = environment.runningApplications.first(where: {
      $0.localizedName?.lowercased() == lowered
    })?.bundleURL {
      return url
    }
    let bundleName = target.hasSuffix(".app") ? target : "\(target).app"
    for root in Self.applicationSearchRoots() {
      let candidate = root.appendingPathComponent(bundleName)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func applicationSearchRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/System/Applications"),
      URL(fileURLWithPath: "/System/Applications/Utilities"),
      URL(fileURLWithPath: "/System/Library/CoreServices"),
      home.appendingPathComponent("Applications"),
    ]
  }

  private static func scanApplicationBundleCandidates(roots: [URL]) -> [Candidate] {
    var byIdentifier: [String: Candidate] = [:]
    var byPath: [String: Candidate] = [:]
    for root in roots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }

      for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "app" else { continue }
        let item = appBundleItem(fromBundleURL: url)
        if !item.bundleIdentifier.isEmpty {
          byIdentifier[item.bundleIdentifier] = item
        } else {
          byPath[url.path] = item
        }
      }
    }
    return (Array(byIdentifier.values) + Array(byPath.values)).sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func installedAppItems() -> [Candidate] {
    cacheLock.lock()
    let matcher = ignoredAppMatcher
    if let cached = installedItemsCache {
      cacheLock.unlock()
      return cached
    }
    cacheLock.unlock()

    let scanned = Self.scanApplicationBundleCandidates(roots: Self.applicationSearchRoots())
      .filter { !matcher.contains($0) }
    cacheLock.lock()
    if let cached = installedItemsCache {
      cacheLock.unlock()
      return cached
    }
    guard ignoredAppMatcher == matcher else {
      cacheLock.unlock()
      return scanned
    }
    installedItemsCache = scanned
    cacheLock.unlock()
    return scanned
  }

  private static func appBundleItem(fromBundleURL url: URL) -> Candidate {
    let bundle = Bundle(url: url)
    let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary ?? [:]
    let rawName =
      (info["CFBundleDisplayName"] as? String)
      ?? (info["CFBundleName"] as? String)
      ?? url.deletingPathExtension().lastPathComponent
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    return Candidate(
      kind: .app,
      sourceID: "app",
      source: "app",
      pid: nil,
      name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
      subtitle: "app",
      bundleIdentifier: bundle?.bundleIdentifier ?? "",
      url: url)
  }
}

struct IgnoredAppMatcher: Equatable {
  private let entries: Set<String>

  init(_ entries: [String]) {
    self.entries = Set(entries.map(Self.normalize).filter { !$0.isEmpty })
  }

  func contains(_ candidate: Candidate) -> Bool {
    contains(
      title: candidate.name,
      bundleIdentifier: candidate.bundleIdentifier,
      url: candidate.url)
  }

  func contains(title: String, bundleIdentifier: String, url: URL?) -> Bool {
    guard !entries.isEmpty else { return false }
    if entries.contains(Self.normalize(title)) { return true }
    if entries.contains(Self.normalize(bundleIdentifier)) { return true }
    guard let url else { return false }
    if entries.contains(Self.normalize(url.path)) { return true }
    if entries.contains(Self.normalize(url.lastPathComponent)) { return true }
    if entries.contains(Self.normalize(url.deletingPathExtension().lastPathComponent)) {
      return true
    }
    return false
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
