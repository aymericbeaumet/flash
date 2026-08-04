import AppKit
import ApplicationServices
import FlashCore

/// Chrome and other Chromium-based browsers ship their accessibility
/// engine OFF by default and only enable it when an assistive
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
  static let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext",
    "com.operasoftware.OperaDeveloper",
  ]

  /// Sends the wake attributes for every currently running app whose
  /// bundle ID is in the Chromium allowlist. AX IPCs run on `queue`
  /// because Chromium can take tens of ms to ack the attribute write
  /// under load and we don't want the main thread paying that cost.
  static func wakeAllRunningApps(on queue: DispatchQueue) {
    for app in NSWorkspace.shared.runningApplications {
      maybeWake(app: app, on: queue)
    }
  }

  /// Sends wake attributes for a specific running app if it matches
  /// the Chromium allowlist. Used both at app start and on
  /// `didLaunchApplicationNotification`.
  static func maybeWake(app: NSRunningApplication, on queue: DispatchQueue) {
    guard let bid = app.bundleIdentifier, chromiumBundleIDs.contains(bid) else { return }
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    queue.async {
      let appEl = AXApp.make(pid: pid)
      let trueRef = kCFBooleanTrue as CFTypeRef
      _ = AXUIElementSetAttributeValue(
        appEl, "AXEnhancedUserInterface" as CFString, trueRef)
      _ = AXUIElementSetAttributeValue(
        appEl, "AXManualAccessibility" as CFString, trueRef)
    }
  }
}
