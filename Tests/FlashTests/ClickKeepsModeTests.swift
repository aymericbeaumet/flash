import AppKit
import FlashCore
import XCTest

@testable import flash

/// No click enters INSERT (AGENTS.md hard constraint 9): a click made with
/// the mouse, by `f` (`mouse target`) or by `F` (`mouse grid`), on a text
/// field, a password field, a terminal or anything else, keeps the mode, and
/// so does a click chain however it ends. INSERT's one way in is
/// `mode insert` (`ModeReducerTests.testInsertHasExactlyOneWayIn`).
final class ClickKeepsModeTests: XCTestCase {
  private typealias Policy = NormalModePointerPolicy

  // MARK: The mouse

  /// Every primary or middle click in NORMAL goes to the app and keeps
  /// NORMAL, whatever it lands on; a right click suspends for its menu.
  func testEveryAppClickKeepsNormal() {
    for hasHints in [false, true] {
      for action in [JumpAction.leftClick, .doubleClick, .tripleClick, .middleClick] {
        XCTAssertEqual(
          Policy.appClickDecision(
            mode: .normal, wasCommandLine: false, hasHints: hasHints, action: action),
          .keepNormal, "\(action)")
        XCTAssertEqual(
          Policy.pointerDecision(
            mode: .normal, overlayInputMode: .normal, hasHints: hasHints,
            activationInFlight: false,
            intent: .click(
              OverlayPointerClick(action: action, location: CGPoint(x: 400, y: 400), modifiers: [])
            ),
            pointIsInMenuBar: false),
          .app(.keepNormal), "\(action)")
      }
      XCTAssertEqual(
        Policy.appClickDecision(
          mode: .normal, wasCommandLine: false, hasHints: hasHints, action: .rightClick),
        .suspendForNativeSurface(dismissHints: hasHints))
    }
  }

  /// A delegate in NORMAL whose mode effects do nothing (they need a running
  /// app) and whose capture runs through the tap, so a recapture orders no
  /// window in.
  private func delegate() -> AppDelegate {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    delegate.overlay.keyboardCaptureActive = true
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    return delegate
  }

  private func drainMain() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)
  }

  /// A click already delivered (its app was frontmost and Flash was not
  /// active), so Flash posts nothing again.
  private func click(_ action: JumpAction) -> OverlayPointerClick {
    OverlayPointerClick(
      action: action, location: CGPoint(x: 400, y: 400), modifiers: [], flashWasActive: false,
      frontmostPIDAtClick: -1)
  }

  /// A primary click into a text field, a password field or a terminal used
  /// to enter INSERT once Accessibility said what was under it. Nothing is
  /// asked any more and the mode stays, the keys after it read by NORMAL.
  func testAPhysicalClickOnATextFieldAPasswordFieldOrATerminalKeepsNormal() {
    for action in [JumpAction.leftClick, .doubleClick, .tripleClick] {
      let delegate = delegate()
      delegate.handleAppPointerDecision(.keepNormal, click: click(action))
      delegate.monitor.geometryQueue.sync {}
      drainMain()
      XCTAssertEqual(delegate.modeStore.mode, .normal, "\(action)")
    }
  }

  // MARK: `f` and `F`

  private func gesture(on target: JumpTarget?, _ action: JumpAction = .leftClick)
    -> AppDelegate.PointerGesture
  {
    AppDelegate.PointerGesture(
      kind: .click(action), point: CGPoint(x: 400, y: 400), modifiers: [], target: target,
      pid: 42)
  }

  /// Inputs as discovery labels them: a text field, a password field, a
  /// terminal's text area and a tmux pane.
  private let inputs = [
    JumpTarget(
      id: "field", frame: CGRect(x: 380, y: 390, width: 200, height: 22), role: "AXTextField",
      pid: 42, isTextInput: true, providerID: "ax"),
    JumpTarget(
      id: "password", frame: CGRect(x: 380, y: 390, width: 200, height: 22),
      role: "AXTextField", pid: 42, isTextInput: true, providerID: "ax"),
    JumpTarget(
      id: "terminal", frame: CGRect(x: 0, y: 0, width: 800, height: 600), role: "AXTextArea",
      pid: 42, isTextInput: true, providerID: "ax"),
    JumpTarget(
      id: "pane", frame: CGRect(x: 390, y: 390, width: 20, height: 20), role: "tmux-pane",
      pid: 42, providerID: "plugin:terminals"),
  ]

  /// `f` on an input and `F` on whatever is under the grid point (no
  /// target): the click goes out and NORMAL stays.
  func testAnFOrFCommitOnAnInputKeepsNormal() {
    for target in inputs + [nil] {
      for action in [JumpAction.leftClick, .doubleClick, .tripleClick] {
        let delegate = delegate()
        delegate.finishPointerGesture(
          gesture(on: target, action), followUp: .finish, wasNormalMode: true)
        drainMain()
        XCTAssertEqual(delegate.modeStore.mode, .normal, "\(target?.id ?? "grid") \(action)")
      }
    }
  }

  /// A chain's click on an input no longer ends it: it goes on in NORMAL,
  /// as after any other click, until Escape ends it, still in NORMAL.
  func testAChainKeepsNormalAfterAClickOnAnInputAndAfterItEnds() {
    for followUp in [AppDelegate.PointerCommitFollowUp.rearmHints, .rearmSticky] {
      for target in inputs {
        let delegate = delegate()
        delegate.finishPointerGesture(gesture(on: target), followUp: followUp, wasNormalMode: true)
        drainMain()
        XCTAssertEqual(delegate.modeStore.mode, .normal, "\(followUp) \(target.id)")
        delegate.cancelOverlay()
        XCTAssertEqual(delegate.modeStore.mode, .normal, "the chain ended")
      }
    }
  }
}
