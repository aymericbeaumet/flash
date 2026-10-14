import XCTest

@testable import flash

final class NativeSurfaceOwnershipTests: XCTestCase {
  /// A context menu Flash saw open keeps the keyboard until it closes: a
  /// recapture a system event asks for, however late, does not end it.
  func testASurfaceSeenOpenEndsOnlyWithItsClose() {
    var ownership = NativeSurfaceOwnership()
    ownership.begin()
    ownership.menuOpened()
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
    ownership.menuOpened()
    XCTAssertFalse(ownership.isOwned)
    XCTAssertFalse(ownership.recaptureRequested(windowActive: true))
    XCTAssertTrue(ownership.recaptureRequested(windowActive: false))
  }
}
