import AppKit
import ApplicationServices
import FlashCore
import FlashE2EKit
import FlashProviders
import XCTest

/// Live AX integration tests against Firefox. Firefox is the trickiest
/// host Flash supports because:
///   - it has no AppleScript `do JavaScript` bridge, so the
///     BrowserScriptProvider never applies — the AccessibilityProvider
///     IS the implementation.
///   - its accessibility engine is lazy: until something signals
///     "screen reader on", `AXWebArea` exposes only the chrome buttons.
///     `AccessibilityProvider` sets `AXEnhancedUserInterface` and
///     `AXManualAccessibility` to wake it; any regression there
///     silently empties the hint list.
///   - it batches AX IPC differently than Safari/Chrome, which is why
///     the walker has a per-element-attributes single-call fallback.
///
/// The fixture HTML + every assertion lives in `FlashE2EKit` so this
/// xctest target and the standalone `flash-firefox-e2e` CLI runner can
/// never drift. The opt-in here is purely about whether we launch
/// Firefox during `swift test`.
///
/// **Opt-in**: gated on `FLASH_FIREFOX_E2E=1` so a default `swift
/// test` run doesn't launch a browser. Also skipped if Firefox isn't
/// installed or the test runner doesn't have Accessibility permission.
///
/// **AX permission**: the test runner (`xctest` under SwiftPM) needs
/// Accessibility access. Without it, `AXIsProcessTrusted` returns
/// false and these tests skip with a pointer to the standalone runner
/// — the recommended path because it signs with a stable identity
/// whose TCC grant persists across rebuilds.
final class FirefoxIntegrationTests: XCTestCase {

  /// XCTest-backed bridge that forwards `fail(_:)` into `XCTFail` so
  /// each fixture invariant produces a proper test failure (with full
  /// source attribution) instead of being dumped to stdout.
  private final class XCTestRecorder: FirefoxE2ERecorder {
    func pass(_ message: String) {
      // Surfaces in `swift test` output; useful for reading the role
      // histogram and the per-assertion confirmations.
      print("✓ \(message)")
    }
    func fail(_ message: String) {
      XCTFail(message)
    }
  }

  override func setUpWithError() throws {
    guard ProcessInfo.processInfo.environment["FLASH_FIREFOX_E2E"] == "1" else {
      throw XCTSkip(
        "Firefox E2E is opt-in. Set FLASH_FIREFOX_E2E=1 to enable.")
    }
    guard FileManager.default.fileExists(atPath: FirefoxFixture.appPath) else {
      throw XCTSkip("Firefox not installed at \(FirefoxFixture.appPath)")
    }
    // Accessibility TCC is keyed on the *binary*'s cdhash, not on
    // the parent terminal — so granting Alacritty / iTerm / Terminal.app
    // does NOT bubble down to the xctest host. The auto-prompt
    // (`AXIsProcessTrustedWithOptions` with kAXTrustedCheckOptionPrompt)
    // is misleading here: macOS blames the "responsible process"
    // (whatever terminal launched `swift test`), which is usually
    // already granted, so adding it again changes nothing. The fix is
    // to grant `xctest` itself.
    guard AXIsProcessTrusted() else {
      throw XCTSkip(
        """
        Test runner lacks Accessibility permission.

        Recommended: use the standalone runner instead of `swift test`.
        It signs with the stable "Flash Dev" identity, so the TCC grant
        persists across rebuilds:

          ./Scripts/install.sh              # one-time, sets up the signing identity
          ./Scripts/build-firefox-e2e.sh    # builds + signs flash-firefox-e2e
          # then grant accessibility to:
          #   <project>/build/flash-firefox-e2e
          ./build/flash-firefox-e2e

        Why not `swift test`: SwiftPM loads the test bundle through
        `swiftpm-xctest-helper`, whose TCC grant rarely sticks (Xcode
        updates rotate its cdhash, and stale grants linger silently).
        The standalone runner has the same fixture + assertions but
        runs in a binary you control.
        """)
    }
  }

  /// Single headline regression test. Launches Firefox, lets the AX
  /// tree settle, walks via `AccessibilityProvider`, and asserts every
  /// fixture invariant simultaneously. Splitting this across N small
  /// tests would re-launch Firefox per test (~10 s each); the cost
  /// isn't worth it.
  func testFirefoxHintCoverageAndExclusion() throws {
    let firefox: NSRunningApplication
    do {
      firefox = try FirefoxHarness.launchWithFixture()
    } catch FirefoxHarness.LaunchError.notInstalled(let path) {
      throw XCTSkip("Firefox not installed at \(path)")
    } catch FirefoxHarness.LaunchError.noAXWindow {
      throw XCTSkip("Firefox launched but never reported any AX windows within 20s")
    }
    defer { firefox.terminate() }

    firefox.activate(options: [])

    let provider = AccessibilityProvider()
    let context = FirefoxHarness.makeContext(for: firefox)
    let (targets, webAreaFrame) = FirefoxHarness.waitForStableTree(
      provider: provider, context: context, timeout: 20)

    FirefoxAssertions.run(
      targets: targets,
      webAreaFrame: webAreaFrame,
      firefoxPid: firefox.processIdentifier,
      recorder: XCTestRecorder()
    )
  }
}
