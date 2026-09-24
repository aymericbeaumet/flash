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

  func testNormalModeNeverSwallowsKeyWindowSurfaces() {
    // The command line owns the key window and types into its own field — the
    // tap must pass it through untouched.
    XCTAssertFalse(KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .commandLine))
  }

  func testNativeSurfacePassesUnmappedInputButSwallowsMappings() {
    for flashMode: FlashMode in [.normal, .insert] {
      for inputMode: OverlayInputMode in [.normal, .passive, .commandLine] {
        XCTAssertEqual(
          decide(flashMode: flashMode, inputMode: inputMode, nativeSurfaceSuspended: true),
          .swallowIfNativeSurfaceKeyIsMapped)
      }
    }
    XCTAssertEqual(
      decide(flashMode: .normal, inputMode: .normal, aboutWindowVisible: true, aboutOwns: true),
      .swallowIfNativeSurfaceKeyIsMapped)
  }

  /// The pure decision over the whole state table: NORMAL swallows every key,
  /// INSERT only a modified chord a mapping claims, a hint session every key
  /// in either base mode, a terminal popup nothing.
  func testTapDecisionTable() {
    XCTAssertEqual(decide(flashMode: .normal, inputMode: .normal), .swallow)
    XCTAssertEqual(decide(flashMode: .normal, inputMode: .normal, chord: true), .swallow)
    XCTAssertEqual(decide(flashMode: .normal, inputMode: .commandLine), .pass)
    XCTAssertEqual(decide(flashMode: .insert, inputMode: .passive), .pass)
    XCTAssertEqual(
      decide(flashMode: .insert, inputMode: .passive, chord: true), .swallowIfInsertChordIsMapped)
    for flashMode: FlashMode in [.normal, .insert] {
      XCTAssertEqual(decide(flashMode: flashMode, inputMode: .hints), .swallow)
      XCTAssertEqual(decide(flashMode: flashMode, inputMode: .hints, terminal: true), .pass)
    }
    // The About window yields to a hint session over it: an open hint session
    // keeps every key even while the window is shown.
    XCTAssertEqual(
      decide(flashMode: .normal, inputMode: .hints, aboutWindowVisible: true, aboutOwns: false),
      .swallow)
    // Shown but not owning (activation in flight): INSERT stays transparent.
    XCTAssertEqual(
      decide(
        flashMode: .insert, inputMode: .passive, chord: true, aboutWindowVisible: true,
        aboutOwns: false),
      .pass)
  }

  /// A bare Escape closes a shown hover preview in either base mode; the
  /// command line and a hint session keep their own Escape.
  func testEscapeClosesAHoverPreview() {
    for flashMode: FlashMode in [.normal, .insert] {
      let inputMode: OverlayInputMode = flashMode == .normal ? .normal : .passive
      XCTAssertEqual(
        decide(flashMode: flashMode, inputMode: inputMode, escape: true, preview: true),
        .closeEphemeralPopup)
      XCTAssertNotEqual(
        decide(flashMode: flashMode, inputMode: inputMode, escape: true, preview: false),
        .closeEphemeralPopup)
    }
    XCTAssertEqual(
      decide(flashMode: .normal, inputMode: .commandLine, escape: true, preview: true), .pass)
    XCTAssertEqual(
      decide(flashMode: .insert, inputMode: .hints, escape: true, preview: true), .swallow)
    XCTAssertEqual(
      decide(flashMode: .normal, inputMode: .normal, escape: true, preview: true, terminal: true),
      .pass)
  }

  private func decide(
    flashMode: FlashMode, inputMode: OverlayInputMode, chord: Bool = false,
    escape: Bool = false, preview: Bool = false,
    terminal: Bool = false, aboutWindowVisible: Bool = false, aboutOwns: Bool = false,
    nativeSurfaceSuspended: Bool = false
  ) -> KeyboardCaptureTap.Decision {
    KeyboardCaptureTap.decide(
      isTerminal: terminal, flashMode: flashMode, inputMode: inputMode,
      aboutWindowVisible: aboutWindowVisible, aboutWindowOwnsKeyboard: aboutOwns,
      nativeSurfaceSuspended: nativeSurfaceSuspended, isModifiedChord: chord,
      isBareEscape: escape, ephemeralPopupShown: preview)
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

  /// Secure input (a focused password field) hides keys from the tap, so a
  /// hint session opened under it takes the key window instead: typed labels
  /// then reach Flash, never the password field.
  func testASessionOpenedUnderSecureInputUsesTheKeyWindow() {
    XCTAssertEqual(
      KeyboardCaptureTap.sessionCapture(tapInstalled: true, secureInputEnabled: false), .tap)
    XCTAssertEqual(
      KeyboardCaptureTap.sessionCapture(tapInstalled: true, secureInputEnabled: true), .keyWindow)
    for secure in [false, true] {
      XCTAssertEqual(
        KeyboardCaptureTap.sessionCapture(tapInstalled: false, secureInputEnabled: secure),
        .keyWindow, "without a tap the key window is the only capture")
    }
    XCTAssertEqual(KeyboardCaptureTap.SessionCapture.keyWindow.rawValue, "key_window")
  }

  /// The overlay routes hint keys through the tap only for a tap session;
  /// NORMAL stays on the tap whatever the last session used.
  func testTheTapOwnsHintsOnlyForATapSession() {
    let panel = OverlayPanel()
    panel.keyboardCaptureActive = true
    defer { panel.inputMode = .passive }
    panel.inputMode = .hints
    panel.hintSessionCapture = .tap
    XCTAssertTrue(panel.tapCapturesInput)
    panel.hintSessionCapture = .keyWindow
    XCTAssertFalse(panel.tapCapturesInput)
    panel.inputMode = .normal
    XCTAssertTrue(panel.tapCapturesInput)
    panel.inputMode = .commandLine
    XCTAssertFalse(panel.tapCapturesInput)
    panel.keyboardCaptureActive = false
    panel.inputMode = .normal
    XCTAssertFalse(panel.tapCapturesInput)
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
