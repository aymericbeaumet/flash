import AppKit
import FlashCore

/// The one place Flash activates itself or changes its activation policy
/// (guardrail-enforced; `main.swift` sets the launch policy). In the test
/// runner every call does nothing: an `xctest` process that activates takes
/// the keyboard from the app the user is typing in, and its windows are
/// transparent, so the keys vanish.
enum AppActivation {
  /// False inside XCTest.
  static let allowed = NSClassFromString("XCTestCase") == nil

  /// `NSApp.activate()` from macOS 14; `activate(ignoringOtherApps: true)`,
  /// its macOS 13 equivalent, before (`ActivationModel`).
  static func activate() {
    guard allowed else { return }
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  static func activate(ignoringOtherApps: Bool) {
    guard allowed else { return }
    NSApp.activate(ignoringOtherApps: ignoringOtherApps)
  }

  /// Flash's own activation, handed over by `source` (cooperative since
  /// macOS 14; macOS 13, which has no handover, takes it with
  /// `activateIgnoringOtherApps`); false when declined or in the test runner.
  @discardableResult
  static func activate(
    from source: NSRunningApplication, options: NSApplication.ActivationOptions = []
  ) -> Bool {
    guard allowed else { return false }
    if #available(macOS 14.0, *) {
      return NSRunningApplication.current.activate(from: source, options: options)
    }
    return NSRunningApplication.current.activate(options: ActivationModel.forced.options(options))
  }

  /// Flash's own activation, asked directly; false when declined or in the
  /// test runner.
  @discardableResult
  static func activateDirectly(options: NSApplication.ActivationOptions = []) -> Bool {
    guard allowed else { return false }
    return NSRunningApplication.current.activate(options: options)
  }

  static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
    guard allowed else { return }
    NSApp.setActivationPolicy(policy)
  }
}
