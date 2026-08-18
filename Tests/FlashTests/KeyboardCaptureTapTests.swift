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

  func testNormalModePassesOnlyEnabledUnmappedModifierChords() {
    XCTAssertFalse(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .normal,
        modifierFlags: .maskCommand,
        hasMapping: false,
        passthroughModifierFlags: [.maskCommand, .maskControl, .maskShift, .maskAlternate]))
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .normal,
        modifierFlags: [.maskCommand, .maskShift],
        hasMapping: true,
        passthroughModifierFlags: [.maskCommand, .maskControl, .maskShift, .maskAlternate]))
    XCTAssertFalse(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .normal,
        modifierFlags: .maskShift,
        hasMapping: false,
        passthroughModifierFlags: [.maskCommand, .maskControl, .maskShift, .maskAlternate]))
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .normal,
        modifierFlags: .maskAlternate,
        hasMapping: false,
        passthroughModifierFlags: [.maskCommand]))
  }

  func testHintsAlwaysSwallowModifiedChords() {
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal,
        inputMode: .hints,
        modifierFlags: .maskControl,
        hasMapping: false,
        passthroughModifierFlags: [.maskCommand, .maskControl, .maskShift, .maskAlternate]))
  }

  func testNormalModeNeverSwallowsKeyWindowSurfaces() {
    // Command-line / candidate-finder own the key window and type into their
    // own fields — the tap must pass those through untouched.
    XCTAssertFalse(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .commandLine))
    XCTAssertFalse(
      KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .candidateFinder))
  }

  func testInsertModeNeverSwallows() {
    // INSERT is invisible to the tap regardless of overlay input mode — keys
    // flow straight to the focused app.
    for inputMode: OverlayInputMode in [.normal, .hints, .commandLine, .candidateFinder] {
      XCTAssertFalse(
        KeyboardCaptureTap.shouldSwallow(flashMode: .insert, inputMode: inputMode),
        "insert mode should never swallow (inputMode=\(inputMode))")
    }
  }
}
