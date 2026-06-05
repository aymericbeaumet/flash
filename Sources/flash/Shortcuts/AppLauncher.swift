import AppKit
import Foundation

/// Launch (or front) an app by display name, bundle ID, or path.
///
/// Implementation philosophy: hand off to Launch Services and trust
/// it. Raycast / Alfred / Spotlight all do this — there is no
/// hand-rolled "is the app running, what's its PID, send a specific
/// Apple Event" dance. `NSWorkspace.openApplication(at:…)` already:
///   - launches the app cold if it isn't running,
///   - or sends it the reopen event if it is (the same event Dock
///     click sends — apps respond by surfacing their main window),
///   - and front-most-activates the target afterwards.
///
/// Two preconditions made this collapse possible:
///   1. `NSAppleEventsUsageDescription` in `Info.plist`. Without it
///      macOS Mojave+ silently blocks the AppleEvents Launch
///      Services dispatches internally — and Messages, FaceTime,
///      and a few others stop showing their main window.
///   2. No hardened-runtime requirement: an ad-hoc / self-signed
///      binary without `com.apple.security.automation.apple-events`
///      can still send the events the Info.plist key authorises.
enum AppLauncher {

  static func activate(target: String) {
    guard let url = resolveURL(for: target) else {
      FlashLog.warn("[app_open] no app found for \"\(target)\"")
      return
    }
    let conf = NSWorkspace.OpenConfiguration()
    // Bring the app to front after the launch / reopen. With this
    // off, openApplication still launches the app but leaves the
    // current frontmost app focused — defeats the point of a
    // switch hotkey.
    conf.activates = true
    // This is a hotkey switch, not a user-initiated document
    // open. Don't pollute Recent Items.
    conf.addsToRecentItems = false
    NSWorkspace.shared.openApplication(
      at: url, configuration: conf, completionHandler: nil)
  }

  /// Resolve `target` to a `.app` URL. Accepts three shapes:
  ///
  ///   - absolute path (`/Applications/Slack.app`) — used as-is
  ///   - bundle ID (`com.tinyspeck.slackmacgap`) — resolved via
  ///     Launch Services (`urlForApplication(withBundleIdentifier:)`)
  ///   - display name (`Slack`) — checked against running apps'
  ///     localized names first (no disk hit when the app is up),
  ///     then a short filesystem scan in the standard install
  ///     locations
  ///
  /// Returns nil when nothing matches. The caller logs a single
  /// warning and stops — silent failure on a wrong `name=` in
  /// config is the kind of bug that wastes hours.
  private static func resolveURL(for target: String) -> URL? {
    if target.hasPrefix("/") {
      return URL(fileURLWithPath: target)
    }
    let ws = NSWorkspace.shared
    if let url = ws.urlForApplication(withBundleIdentifier: target) {
      return url
    }
    let lowered = target.lowercased()
    if let url = ws.runningApplications.first(where: {
      $0.localizedName?.lowercased() == lowered
    })?.bundleURL {
      return url
    }
    let bundleName = target.hasSuffix(".app") ? target : "\(target).app"
    let candidates = [
      "/Applications",
      "/System/Applications",
      "/System/Applications/Utilities",
      "\(NSHomeDirectory())/Applications",
    ]
    for dir in candidates {
      let candidate = "\(dir)/\(bundleName)"
      if FileManager.default.fileExists(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    return nil
  }
}
