import AppKit
import ApplicationServices
import FlashCore

/// Runtimes that build their accessibility tree only when an assistive
/// client asks — Chromium (browsers, Electron and CEF apps) and Flutter
/// (`AppTraits.needsAccessibilityWake`) — ship it off by default (Chromium
/// documents a perceptible CPU/memory cost when it is on). Setting
/// `AXEnhancedUserInterface = true` or `AXManualAccessibility = true` on the
/// app element is the public signal they watch for.
///
/// Waking lazily at first walk doesn't help: the tree is built
/// asynchronously after the attribute is set, so the first `discover()` sees
/// an empty tree. Setting these attributes proactively (at Flash startup for
/// already-running apps, and on `didLaunchApplicationNotification` for new
/// ones) gives the tree time to populate before the user ever triggers Flash.
/// Reading each app's traits here also warms the `AppTraits` cache off main.
///
/// Belt-and-suspenders: `AccessibilityProvider.discover` sets the same
/// attributes on every walk of such an app.
enum AccessibilityWaker {
  /// Sends the wake attributes for every currently running app whose runtime
  /// needs them. AX IPCs run on `queue` because Chromium can take tens of ms
  /// to ack the attribute write under load and we don't want the main thread
  /// paying that cost.
  static func wakeAllRunningApps(on queue: DispatchQueue) {
    for app in NSWorkspace.shared.runningApplications {
      maybeWake(app: app, on: queue)
    }
  }

  /// Sends wake attributes for a specific running app whose runtime needs
  /// them. Used both at app start and on `didLaunchApplicationNotification`.
  static func maybeWake(app: NSRunningApplication, on queue: DispatchQueue) {
    let bundleIdentifier = app.bundleIdentifier
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    queue.async {
      guard AppTraits.of(bundleIdentifier: bundleIdentifier, pid: pid).needsAccessibilityWake
      else { return }
      let appEl = AXApp.make(pid: pid)
      let trueRef = kCFBooleanTrue as CFTypeRef
      _ = AXUIElementSetAttributeValue(
        appEl, "AXEnhancedUserInterface" as CFString, trueRef)
      _ = AXUIElementSetAttributeValue(
        appEl, "AXManualAccessibility" as CFString, trueRef)
    }
  }
}
