import AppKit
import FlashCore
import XCTest

@testable import flash

final class HintSessionPhaseTests: XCTestCase {
  private func hint(_ label: String) -> AssignedHint {
    AssignedHint(
      target: JumpTarget(
        id: label, frame: CGRect(x: 10, y: 10, width: 40, height: 20), role: "AXButton",
        pid: 42, providerID: "test"),
      label: label)
  }

  func testEachPhaseRoutesKeysToExactlyOneInterpreter() {
    var session = HintSession()
    XCTAssertEqual(session.keyRoute, .labels)
    session.phase = .search(.init())
    XCTAssertEqual(session.keyRoute, .search)
    session.phase = .adjusting(hint: hint("a"), point: .zero)
    XCTAssertEqual(session.keyRoute, .adjustment)
    session.phase = .pointer(.init())
    XCTAssertEqual(session.keyRoute, .pointer)
    XCTAssertNil(session.search, "entering one phase leaves the others")
    XCTAssertNil(session.anchor)
  }

  func testLabelTypingNeedsHintsWhileTheOtherPhasesOwnInputRegardless() {
    var session = HintSession()
    XCTAssertFalse(session.isActive)
    session.hints = [hint("a")]
    XCTAssertTrue(session.isActive)
    session.hints = []
    for phase: HintSession.Phase in [
      .search(.init()), .adjusting(hint: hint("a"), point: .zero), .pointer(.init()),
    ] {
      session.phase = phase
      XCTAssertTrue(session.isActive)
    }
  }

  func testOnlyPointerModeCanHoldTheButton() {
    var session = HintSession()
    session.didPressPrimaryButton()
    XCTAssertFalse(session.pointerDragActive)
    XCTAssertNil(session.releasePrimaryButton())

    session.phase = .pointer(.init())
    session.didPressPrimaryButton()
    XCTAssertTrue(session.pointerDragActive)
    // Leaving pointer mode drops the held button with the phase; teardown
    // releases it through `finish`, never twice.
    XCTAssertEqual(session.finish(), [.releasePrimaryButton])
    XCTAssertFalse(session.pointerDragActive)
  }

  func testInsertRoutingNeverOutlivesTheSessionOrWalkThatOwnedTheKeys() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.dispatch(.enterInsert(targetPID: nil))
    delegate.refreshOverlayInputRouting()
    XCTAssertEqual(delegate.overlay.inputMode, .passive)

    // A discovery walk takes the keys, and gives them back when it ends —
    // whichever path ends it, with no re-render call.
    let token = delegate.activationLifecycle.begin()
    XCTAssertEqual(delegate.overlay.inputMode, .hints)
    delegate.activationLifecycle.complete(token: token)
    XCTAssertEqual(delegate.overlay.inputMode, .passive)

    delegate.hintSession.hints = [hint("a")]
    XCTAssertEqual(delegate.overlay.inputMode, .hints)
    delegate.hintSession = HintSession()
    XCTAssertEqual(delegate.overlay.inputMode, .passive, "a stale .hints swallows every key")
  }

  func testTheCapturePathIsFixedPerSessionAndPushedToTheOverlay() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    XCTAssertEqual(HintSession().capture, .tap)

    delegate.hintSession.capture = .keyWindow
    XCTAssertEqual(delegate.overlay.hintSessionCapture, .keyWindow)
    _ = delegate.hintSession.finish()
    XCTAssertEqual(delegate.hintSession.capture, .tap, "the next session decides afresh")
    XCTAssertEqual(delegate.overlay.hintSessionCapture, .tap)
  }

  func testOverlayRoutingAndFocusBorderFollowTheSession() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    let window = CGRect(x: 100, y: 100, width: 400, height: 300)
    delegate.overlay.setActiveWindowBorder(around: window)
    defer { delegate.overlay.setActiveWindowBorder(around: nil) }

    delegate.hintSession.phase = .search(.init())
    XCTAssertEqual(delegate.overlay.hintKeyRoute, .search)
    XCTAssertNil(
      delegate.overlay.activeWindowBorderFrame,
      "the border never stays up under a hint session, whatever re-renders the overlay")
    var withSublayers: [CALayer] = []
    delegate.overlay.appendActiveWindowBorderLayerIfNeeded(to: &withSublayers)
    XCTAssertTrue(withSublayers.isEmpty)

    delegate.hintSession = HintSession()
    XCTAssertEqual(delegate.overlay.hintKeyRoute, .labels)
  }
}
