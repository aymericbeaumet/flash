import XCTest

@testable import flash

final class IdleActivationTests: XCTestCase {
  /// INSERT with Flash active sends every passed key, Command chords
  /// included, to Flash: it hands activation back unless a surface of its
  /// own or a physical click owns it.
  func testInsertWhileActiveHandsActivationBack() {
    func handsBack(
      active: Bool = true, mode: Mode = .insert, about: Bool = false, hints: Bool = false,
      click: Bool = false
    ) -> Bool {
      IdleActivation.handsBack(
        flashActive: active, mode: mode, aboutWindowVisible: about, hintSessionActive: hints,
        pointerClickPending: click)
    }
    XCTAssertTrue(handsBack())
    XCTAssertFalse(handsBack(active: false), "nothing to give back")
    XCTAssertFalse(handsBack(mode: .normal), "the tap takes NORMAL's keys whoever is active")
    XCTAssertFalse(handsBack(about: true), "About is Flash's own window")
    XCTAssertFalse(handsBack(hints: true), "a hint session may read keys through the key window")
    XCTAssertFalse(handsBack(click: true), "the click moves activation itself")
    XCTAssertFalse(
      handsBack(mode: .terminal(restoreTo: .insert, returnPID: 1)), "a focused popup types")
    XCTAssertFalse(handsBack(mode: .command(restoreTo: .insert)), "the command line types")
  }
}
