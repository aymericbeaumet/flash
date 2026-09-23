import XCTest

@testable import flash

/// The keyboard tap's swallow decision is the single most security-sensitive
/// branch in the input path: get it wrong in one direction and NORMAL leaks
/// keys to the focused app; wrong in the other and INSERT (or a command-line
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
    // The command line owns the key window and types into its own field — the
    // tap must pass it through untouched.
    XCTAssertFalse(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .commandLine))
  }

  func testNativeSurfacePassesUnmappedInputButSwallowsMappings() {
    for inputMode: OverlayInputMode in [.normal, .hints, .commandLine] {
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
        flashMode: .insert,
        inputMode: .normal,
        hasMapping: true,
        nativeSurfaceOwnsKeyboard: true))
  }

  func testInsertModeSwallowsOnlyForAHintSession() {
    // INSERT is invisible to the tap — keys flow straight to the focused app —
    // until a hint session opens over it: the labels must reach the hints.
    for inputMode: OverlayInputMode in [.passive, .normal, .commandLine] {
      XCTAssertFalse(
        KeyboardCaptureTap.shouldSwallow(flashMode: .insert, inputMode: inputMode),
        "insert mode should not swallow (inputMode=\(inputMode))")
    }
    XCTAssertTrue(KeyboardCaptureTap.shouldSwallow(flashMode: .insert, inputMode: .hints))
  }

  func testPassiveInputNeverSwallows() {
    for flashMode: FlashMode in [.normal, .insert] {
      XCTAssertFalse(KeyboardCaptureTap.shouldSwallow(flashMode: flashMode, inputMode: .passive))
    }
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
