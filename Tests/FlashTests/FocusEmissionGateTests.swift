import XCTest

@testable import flash

final class FocusEmissionGateTests: XCTestCase {
  /// The same app reported twice in a row — by the workspace notification
  /// and by the key-path reconcile — is one focus change; a different app
  /// each time is three.
  func testEmitsOncePerChangeOfFocusedApp() {
    var gate = FocusEmissionGate()
    XCTAssertTrue(gate.shouldEmit(pid: 2))
    XCTAssertFalse(gate.shouldEmit(pid: 2))
    XCTAssertTrue(gate.shouldEmit(pid: 1))
    XCTAssertTrue(gate.shouldEmit(pid: 2))
    XCTAssertTrue(gate.shouldEmit(pid: 1))
    XCTAssertEqual(gate.lastEmittedPID, 1)
  }
}
