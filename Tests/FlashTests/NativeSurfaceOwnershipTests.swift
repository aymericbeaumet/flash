import ApplicationServices
import FlashCore
import XCTest

@testable import flash

final class NativeSurfaceOwnershipTests: XCTestCase {
  /// Distinct AX elements to stand in for menus; never messaged.
  private let menu = AXUIElementCreateApplication(1)
  private let submenu = AXUIElementCreateApplication(2)

  /// A context menu Flash saw open keeps the keyboard until it closes: a
  /// recapture a system event asks for, however late, does not end it.
  func testASurfaceSeenOpenEndsOnlyWithItsClose() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    ownership.menuOpened(pid: 42, menu: menu)
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
    ownership.menuOpened(pid: 42, menu: menu)
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
    ownership.menuOpened(pid: 42, menu: menu)
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

  /// The menus an app reported opening are what `f` walks: Firefox's context
  /// menu is not a child of the application element, so the element the
  /// notification names is the one way to reach it. A submenu closing leaves
  /// the menu it hangs from open, and the keyboard with it.
  func testOpenMenusAreTheNotifiedElementsAndCloseOneByOne() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    ownership.menuOpened(pid: 42, menu: menu)
    ownership.menuOpened(pid: 42, menu: submenu)
    ownership.menuOpened(pid: 42, menu: submenu)
    XCTAssertEqual(ownership.openMenus, [menu, submenu])
    XCTAssertFalse(ownership.menuClosed(submenu), "the parent menu is still open")
    XCTAssertTrue(ownership.isOwned)
    XCTAssertEqual(ownership.openMenus, [menu])
    XCTAssertTrue(ownership.menuClosed(menu), "the last menu closed")
    XCTAssertFalse(ownership.isOwned)
    XCTAssertEqual(ownership.openMenus, [])
  }

  /// A close naming no menu Flash recorded is still the surface going away.
  func testACloseNamingAnUnknownMenuEndsTheSurface() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    ownership.menuOpened(pid: 42, menu: menu)
    XCTAssertTrue(ownership.menuClosed(submenu))
    XCTAssertFalse(ownership.isOwned)
  }
}
