import AppKit
import ApplicationServices
import FlashCore

/// Chrome, other Chromium-based browsers and every Electron app (Slack,
/// Discord, Notion, …) ship their accessibility engine OFF by default and only enable it when an assistive
/// technology asks for it (the cost is real — Chromium documents
/// a perceptible CPU/memory hit when full a11y is on). Setting
/// `AXEnhancedUserInterface = true` or `AXManualAccessibility = true`
/// on the app element is the public signal Chromium watches for.
///
/// Waking lazily at first walk doesn't help: Chrome's a11y tree is
/// built asynchronously after the attribute is set, so the first
/// `discover()` sees an empty tree. Setting these attributes
/// proactively (at Flash startup for already-running Chromium apps,
/// and on `didLaunchApplicationNotification` for new ones) gives the
/// tree time to populate before the user ever triggers Flash.
///
/// Belt-and-suspenders: `AccessibilityProvider.discover` still sets the
/// same attributes on every non-Apple-app walk, so a Chromium variant we
/// didn't recognise here still wakes the first time the user triggers
/// Flash on it. (Apple's native apps are skipped there — the flag is
/// process-sticky and degrades SwiftUI-heavy apps like Notes.)
enum ChromiumAccessibilityWaker {
  /// Sends the wake attributes for every currently running app whose
  /// bundle ID is in the Chromium allowlist. AX IPCs run on `queue`
  /// because Chromium can take tens of ms to ack the attribute write
  /// under load and we don't want the main thread paying that cost.
  static func wakeAllRunningApps(on queue: DispatchQueue) {
    for app in NSWorkspace.shared.runningApplications {
      maybeWake(app: app, on: queue)
    }
  }

  /// Sends wake attributes for a specific running app if it is a Chromium
  /// browser or an Electron app. Used both at app start and on
  /// `didLaunchApplicationNotification`.
  static func maybeWake(app: NSRunningApplication, on queue: DispatchQueue) {
    let bundleIdentifier = app.bundleIdentifier
    let bundleURL = app.bundleURL
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    queue.async {
      guard WebBrowsers.chromium.contains(bundleIdentifier ?? "") || isElectron(bundleURL)
      else { return }
      let appEl = AXApp.make(pid: pid)
      let trueRef = kCFBooleanTrue as CFTypeRef
      _ = AXUIElementSetAttributeValue(
        appEl, "AXEnhancedUserInterface" as CFString, trueRef)
      _ = AXUIElementSetAttributeValue(
        appEl, "AXManualAccessibility" as CFString, trueRef)
    }
  }

  /// Electron apps are Chromium underneath and wake the same way; they are
  /// recognised by the framework they ship rather than by a bundle-id list.
  static func isElectron(_ bundleURL: URL?) -> Bool {
    guard let bundleURL else { return false }
    return FileManager.default.fileExists(
      atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        .path)
  }
}
