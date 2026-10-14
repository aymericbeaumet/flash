import FlashCore
import XCTest

@testable import flash

final class NativeSurfaceOwnershipTests: XCTestCase {
  /// A context menu Flash saw open keeps the keyboard until it closes: a
  /// recapture a system event asks for, however late, does not end it.
  func testASurfaceSeenOpenEndsOnlyWithItsClose() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    ownership.menuOpened(pid: 42)
    XCTAssertFalse(ownership.recaptureRequested(windowActive: true))
    XCTAssertFalse(
      ownership.recaptureRequested(windowActive: false), "two seconds in, an app launched")
    XCTAssertTrue(ownership.isOwned)
    ownership.end()
    XCTAssertFalse(ownership.isOwned)
    XCTAssertTrue(ownership.recaptureRequested(windowActive: false))
  }

  /// Without a sighting the bounded window stands in for a close signal, as
  /// it did before: a recapture inside it is skipped, one after it ends the
  /// ownership and proceeds.
  func testASurfaceNeverSeenOpenKeepsTheBoundedWindow() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    XCTAssertFalse(ownership.recaptureRequested(windowActive: true))
    XCTAssertTrue(ownership.isOwned)
    XCTAssertTrue(ownership.recaptureRequested(windowActive: false))
    XCTAssertFalse(ownership.isOwned)
  }

  /// A menu notification with no suspension to attach to changes nothing,
  /// and the window alone still skips a recapture, surface or not.
  func testTheWindowAloneStillSkipsARecapture() {
    var ownership = NativeSurfaceOwnership()
    ownership.menuOpened(pid: 42)
    XCTAssertFalse(ownership.isOwned)
    XCTAssertFalse(ownership.recaptureRequested(windowActive: true))
    XCTAssertTrue(ownership.recaptureRequested(windowActive: false))
  }

  /// `f` over an open context menu walks that menu: the app that opened it
  /// is known only once the menu reported opening, and forgotten with it.
  func testTheOpenMenuNamesItsApp() {
    var ownership = NativeSurfaceOwnership()
    XCTAssertNil(ownership.openMenuPID)
    ownership.begin()
    XCTAssertNil(ownership.openMenuPID, "suspended, but no menu seen yet")
    ownership.menuOpened(pid: 42)
    XCTAssertEqual(ownership.openMenuPID, 42)
    ownership.end()
    XCTAssertNil(ownership.openMenuPID)
  }

  /// The menu owns the keyboard (arrows, Return, type-to-select) until a
  /// hint session starts over it; then the session's keys come to Flash
  /// through the tap. Without the tap Flash could only read keys by becoming
  /// key, which closes the menu, so the menu keeps them.
  func testAHintSessionTakesTheKeyboardFromAMenuOnlyThroughTheTap() {
    XCTAssertTrue(
      NativeSurfaceOwnership.ownsKeyboard(
        owned: true, hintSessionActive: false, activationInFlight: false, tapLive: true))
    XCTAssertFalse(
      NativeSurfaceOwnership.ownsKeyboard(
        owned: true, hintSessionActive: true, activationInFlight: false, tapLive: true))
    XCTAssertFalse(
      NativeSurfaceOwnership.ownsKeyboard(
        owned: true, hintSessionActive: false, activationInFlight: true, tapLive: true))
    XCTAssertTrue(
      NativeSurfaceOwnership.ownsKeyboard(
        owned: true, hintSessionActive: true, activationInFlight: false, tapLive: false))
    XCTAssertFalse(
      NativeSurfaceOwnership.ownsKeyboard(
        owned: false, hintSessionActive: false, activationInFlight: false, tapLive: true))
  }

  /// `f` walks the open menus only when the target is the app whose menu
  /// reported opening and the tap reads keys; otherwise the focused window.
  func testAnActivationWalksTheTargetsOpenMenu() {
    XCTAssertEqual(
      AppContext.WalkRoot.activation(openMenuPID: 42, targetPID: 42, tapLive: true), .openMenus)
    XCTAssertEqual(
      AppContext.WalkRoot.activation(openMenuPID: 42, targetPID: 7, tapLive: true),
      .focusedWindow)
    XCTAssertEqual(
      AppContext.WalkRoot.activation(openMenuPID: 42, targetPID: 42, tapLive: false),
      .focusedWindow)
    XCTAssertEqual(
      AppContext.WalkRoot.activation(openMenuPID: nil, targetPID: 42, tapLive: true),
      .focusedWindow)
  }
}
