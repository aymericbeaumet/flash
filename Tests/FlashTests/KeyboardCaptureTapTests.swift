import XCTest

@testable import flash

/// The keyboard tap's swallow decision is the single most security-sensitive
/// branch in the input path: get it wrong in one direction and NORMAL leaks
/// keys to the focused app; wrong in the other and PASSTHROUGH (or a command-line
/// field) goes deaf. These pin the full mode × input-mode matrix.
final class KeyboardCaptureTapTests: XCTestCase {
  func testNormalModeSwallowsBareAndHintInput() {
    XCTAssertTrue(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .normal))
    XCTAssertTrue(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .hints))
  }

  func testNormalModeSwallowsEveryChordMappedOrNot() {
    for hasMapping in [false, true] {
      XCTAssertTrue(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal, inputMode: .normal, hasMapping: hasMapping))
      XCTAssertTrue(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal, inputMode: .hints, hasMapping: hasMapping))
    }
  }

  func testNormalModeNeverSwallowsKeyWindowSurfaces() {
    // Command-line / candidate-finder own the key window and type into their
    // own fields — the tap must pass those through untouched.
    XCTAssertFalse(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .commandLine))
    XCTAssertFalse(
      KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .candidateFinder))
  }

  func testNativeSurfacePassesUnmappedInputButSwallowsMappings() {
    for inputMode: OverlayInputMode in [.normal, .hints, .commandLine, .candidateFinder] {
      XCTAssertFalse(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal,
          inputMode: inputMode,
          nativeSurfaceOwnsKeyboard: true))
    }
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .normal,
        hasMapping: true,
        nativeSurfaceOwnsKeyboard: true))
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .passthrough,
        inputMode: .normal,
        hasMapping: true,
        nativeSurfaceOwnsKeyboard: true))
  }

  func testIdlePassthroughModeNeverSwallows() {
    // An idle overlay cannot claim native typing, including Escape or Ctrl-C.
    for inputMode: OverlayInputMode in [.normal, .hints, .commandLine, .candidateFinder] {
      XCTAssertFalse(
        KeyboardCaptureTap.shouldSwallow(flashMode: .passthrough, inputMode: inputMode),
        "passthrough mode should never swallow (inputMode=\(inputMode))")
    }
  }

  func testDirectHintsCaptureFromEveryBaseModeAndDismissInPlace() {
    for origin in [
      Mode.normal(persistent: false), .normal(persistent: true), .passthrough, .disabled,
    ] {
      XCTAssertTrue(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: origin.flashMode,
          inputMode: origin.overlayInputMode(hasHints: true, activationInFlight: false),
          hasTransientInput: true),
        "A direct hint session must own labels and Escape from \(origin)")
      let (closed, _) = ModeReducer.reduce(
        origin, .leaveMode(hasHints: true, targetPID: nil))
      XCTAssertEqual(closed, origin)
      XCTAssertEqual(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: closed.flashMode,
          inputMode: closed.overlayInputMode(hasHints: false, activationInFlight: false)),
        origin.flashMode == .normal)
    }
  }

  func testDirectHintActivationCapturesBeforeTheLabelsArrive() {
    for origin in [Mode.passthrough, .disabled] {
      XCTAssertTrue(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: origin.flashMode,
          inputMode: origin.overlayInputMode(hasHints: false, activationInFlight: true),
          hasTransientInput: true))
    }
  }

  func testTransientInputCannotCaptureCommandOrNativeSurfaces() {
    for inputMode: OverlayInputMode in [.commandLine, .candidateFinder] {
      XCTAssertFalse(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal, inputMode: inputMode, hasTransientInput: true))
    }
    XCTAssertFalse(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .passthrough, inputMode: .hints, hasTransientInput: true,
        nativeSurfaceOwnsKeyboard: true))
  }

  /// A release whose press NORMAL swallowed must be swallowed too: a terminal
  /// running the Kitty keyboard protocol encodes releases to the pty, so a
  /// stray release types an escape sequence into whatever is running there.
  func testSwallowedPressesSwallowTheirReleases() {
    var keys = KeyboardCaptureTap.SwallowedKeys()
    XCTAssertTrue(keys.isEmpty)
    keys.press(45, swallowed: true)
    XCTAssertTrue(keys.releaseIsSwallowed(45))
    XCTAssertTrue(keys.isEmpty, "a release consumes its pairing")
    XCTAssertFalse(keys.releaseIsSwallowed(45), "a second release is not ours")
  }

  /// A press that reached the app keeps its release, or the app is left with a
  /// key it believes is still held.
  func testPassedPressesKeepTheirReleases() {
    var keys = KeyboardCaptureTap.SwallowedKeys()
    keys.press(45, swallowed: false)
    XCTAssertFalse(keys.releaseIsSwallowed(45))
    // Mode changes mid-keypress do not re-decide: pairing follows the press.
    keys.press(8, swallowed: true)
    keys.press(45, swallowed: false)
    XCTAssertFalse(keys.releaseIsSwallowed(45))
    XCTAssertTrue(keys.releaseIsSwallowed(8))
    XCTAssertTrue(keys.isEmpty)
  }

}
