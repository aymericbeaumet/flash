import AppKit
import Foundation
import os

/// Live cache of every running application, keyed by bundle ID + by
/// lowercased localized name, so a hotkey can switch to an app in O(1)
/// without touching Launch Services on the hot path.
///
/// Why this exists: the user's old setup (karabiner -> `open -a Foo`)
/// spawned a shell on every keypress, hit Launch Services to resolve
/// the bundle, then dispatched AppleEvents — the whole chain ate
/// 50-200 ms per switch. With a pre-populated `NSRunningApplication`
/// reference in hand, `.activate()` is a single IPC and feels
/// instantaneous.
///
/// The cache is seeded once from `NSWorkspace.shared.runningApplications`,
/// then maintained from launch / terminate notifications so newly
/// opened apps become switch-able the moment macOS posts the
/// notification (no polling).
final class AppActivationCache {

  private var byBundleID: [String: NSRunningApplication] = [:]
  /// Lowercase localized name -> bundle ID. `localizedName` is what
  /// the user types in their skhdrc (`open -a "Safari"`), so we
  /// resolve via this map first; bundle ID fallback handles the
  /// `open -a com.apple.Safari` case.
  private var nameToBundleID: [String: String] = [:]
  private var lock = os_unfair_lock_s()

  private var launchObserver: NSObjectProtocol?
  private var terminateObserver: NSObjectProtocol?

  func start() {
    seedFromWorkspace()
    let nc = NSWorkspace.shared.notificationCenter
    launchObserver = nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
      {
        self?.register(app)
      }
    }
    terminateObserver = nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
      {
        self?.unregister(app)
      }
    }
  }

  func stop() {
    let nc = NSWorkspace.shared.notificationCenter
    if let o = launchObserver { nc.removeObserver(o) }
    if let o = terminateObserver { nc.removeObserver(o) }
    launchObserver = nil
    terminateObserver = nil
  }

  private func seedFromWorkspace() {
    for app in NSWorkspace.shared.runningApplications {
      register(app)
    }
  }

  private func register(_ app: NSRunningApplication) {
    guard let id = app.bundleIdentifier else { return }
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    byBundleID[id] = app
    if let name = app.localizedName?.lowercased() {
      nameToBundleID[name] = id
    }
  }

  private func unregister(_ app: NSRunningApplication) {
    guard let id = app.bundleIdentifier else { return }
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    byBundleID.removeValue(forKey: id)
    if let name = app.localizedName?.lowercased() {
      // Only drop the name mapping if it still points at this bundle.
      // Two apps can share a localized name (rare but possible — e.g.,
      // two "Slack"s while one is stuck terminating); leave the live
      // mapping in place.
      if nameToBundleID[name] == id {
        nameToBundleID.removeValue(forKey: name)
      }
    }
  }

  /// Resolve `target` (bundle ID OR localized name) to a running app
  /// from the cache, if any.
  private func cachedApp(for target: String) -> NSRunningApplication? {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    if let app = byBundleID[target], !app.isTerminated { return app }
    if let id = nameToBundleID[target.lowercased()],
      let app = byBundleID[id], !app.isTerminated
    { return app }
    return nil
  }

  /// Switch to the named/identified app. If it's already running, the
  /// cached `NSRunningApplication.activate()` raises its frontmost
  /// window — this is the fast path and runs entirely on the hot key
  /// callback thread. If it's not running, fall back to Launch
  /// Services to locate + spawn the app (slower, async).
  func activate(target: String) {
    if let app = cachedApp(for: target) {
      app.activate()
      return
    }
    launchByName(target)
  }

  /// Cold-launch path. Hit only the first time the user invokes a
  /// hotkey for an app that wasn't already running.
  private func launchByName(_ target: String) {
    let ws = NSWorkspace.shared
    // Prefer bundle ID resolution (works regardless of localization).
    if let url = ws.urlForApplication(withBundleIdentifier: target) {
      ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    // Fall back to scanning a few Applications dirs. Avoids
    // mdfind/Spotlight, which is slow + grants-dependent.
    let bundleName = target.hasSuffix(".app") ? target : "\(target).app"
    let candidates = [
      "/Applications", "/System/Applications",
      "/System/Applications/Utilities",
      "\(NSHomeDirectory())/Applications",
    ]
    for dir in candidates {
      let candidate = "\(dir)/\(bundleName)"
      if FileManager.default.fileExists(atPath: candidate) {
        ws.openApplication(
          at: URL(fileURLWithPath: candidate),
          configuration: NSWorkspace.OpenConfiguration())
        return
      }
    }
  }
}
