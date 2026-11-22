import XCTest

@testable import flash

final class NormalModeCommandDeliveryTests: XCTestCase {
  func testUnhandledSourceAfterFocusSwitchCannotActivateOrDeliverToOriginalApp() {
    var focusedPID: Int32 = 42
    var outcomes: [NormalModeCommandOutcome] = []
    var effects: [String] = []
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { focusedPID == 42 }, completion: { outcomes.append($0) })
    let unhandledSourceReply = {
      delivery.perform {
        effects.append("activate original target")
        effects.append("send original binding")
      }
    }
    focusedPID = 99
    unhandledSourceReply()
    focusedPID = 42
    unhandledSourceReply()
    XCTAssertTrue(effects.isEmpty)
    XCTAssertEqual(outcomes, [.noTarget])
  }

  func testFocusSwitchWhileSelectionValidationIsQueuedCancelsOnce() {
    var ownsTarget = true
    var validateReply: ((Bool) -> Void)?
    var outcomes: [NormalModeCommandOutcome] = []
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { ownsTarget }, validate: { validateReply = $0 },
      completion: { outcomes.append($0) })
    delivery.perform { XCTFail("stale AX reply must not send a key") }
    ownsTarget = false
    validateReply?(true)
    validateReply?(true)
    delivery.complete(.chordSent)
    XCTAssertEqual(outcomes, [.noTarget])
  }

  func testChangedSelectionCancelsDeliveryEvenWhenAppStillMatches() {
    var outcomes: [NormalModeCommandOutcome] = []
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { true }, validate: { $0(false) }, completion: { outcomes.append($0) })
    delivery.perform { XCTFail("changed selection must not be copied") }
    XCTAssertEqual(outcomes, [.noTarget])
  }

  func testEveryDelayedStrokeRechecksOwnership() {
    var ownsTarget = true
    var strokes = 0
    var outcomes: [NormalModeCommandOutcome] = []
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { ownsTarget }, completion: { outcomes.append($0) })
    delivery.perform { strokes += 1 }
    ownsTarget = false
    delivery.perform { strokes += 1 }
    delivery.perform { strokes += 1 }
    XCTAssertEqual(strokes, 1)
    XCTAssertEqual(outcomes, [.noTarget])
  }

  func testSuccessfulSourceMayIntentionallyMoveFocus() {
    var ownsTarget = true
    var outcomes: [NormalModeCommandOutcome] = []
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { ownsTarget }, completion: { outcomes.append($0) })
    ownsTarget = false
    delivery.complete(.performed)
    delivery.perform { XCTFail("completed source must never run fallback") }
    delivery.complete(.failed)
    XCTAssertEqual(outcomes, [.performed])
  }

  func testLocalKeyWindowAndNoTapExternalTargetsHaveSeparateOwnership() {
    XCTAssertTrue(
      NormalModeCommandDelivery.owns(
        targetPID: 42, externalPID: 42, flashPID: 1, ownsLocalKeyWindow: false))
    XCTAssertFalse(
      NormalModeCommandDelivery.owns(
        targetPID: 42, externalPID: 99, flashPID: 1, ownsLocalKeyWindow: true))
    XCTAssertTrue(
      NormalModeCommandDelivery.owns(
        targetPID: 1, externalPID: 42, flashPID: 1, ownsLocalKeyWindow: true))
    XCTAssertFalse(
      NormalModeCommandDelivery.owns(
        targetPID: 1, externalPID: 42, flashPID: 1, ownsLocalKeyWindow: false))
  }
}
