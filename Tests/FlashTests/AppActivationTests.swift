import AppKit
import FlashCore
import XCTest

@testable import flash

/// A test run must never take the keyboard from the app the user is typing
/// in: `xctest` activating made its transparent test windows swallow the
/// user's keys while a suite ran beside a live session.
final class AppActivationTests: XCTestCase {
  func testTheTestRunnerNeverActivatesOrChangesItsPolicy() {
    XCTAssertFalse(AppActivation.allowed)
    let app = NSApplication.shared
    let policy = app.activationPolicy()
    AppActivation.setPolicy(.regular)
    XCTAssertEqual(app.activationPolicy(), policy, "the policy a test run starts with stays")
    let wasActive = app.isActive
    AppActivation.activate()
    AppActivation.activate(ignoringOtherApps: true)
    XCTAssertFalse(AppActivation.activateDirectly(options: [.activateAllWindows]))
    if let front = NSWorkspace.shared.frontmostApplication, front != .current {
      XCTAssertFalse(AppActivation.activate(from: front))
    }
    XCTAssertEqual(app.isActive, wasActive, "no request reached AppKit")
  }

  /// macOS 13 has no cooperative handover, and a request without
  /// `activateIgnoringOtherApps` activates nothing while another app is
  /// active; from macOS 14 the option does nothing and requests go out as
  /// asked.
  func testActivationRequestsCarryTheOptionsOfTheRunningMacOS() {
    let options: NSApplication.ActivationOptions = [.activateAllWindows]
    // `activateIgnoringOtherApps`, deprecated where the test bundle builds.
    let ignoringOtherApps = NSApplication.ActivationOptions(rawValue: 1 << 1)
    XCTAssertEqual(ActivationModel.forced.options(options), options.union(ignoringOtherApps))
    XCTAssertEqual(ActivationModel.forced.options([]), ignoringOtherApps)
    XCTAssertEqual(ActivationModel.cooperative.options(options), options)
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    XCTAssertEqual(ActivationModel.current, major >= 14 ? .cooperative : .forced)
  }
}
