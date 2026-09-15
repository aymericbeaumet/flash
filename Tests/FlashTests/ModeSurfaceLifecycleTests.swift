import AppKit
import FlashCore
import XCTest

@testable import flash

final class ModeSurfaceLifecycleTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testFinderCancelClosesTheModeFromEveryBase() {
    for origin in [Mode.normal, .passthrough, .disabled] {
      let delegate = delegate(in: origin)
      defer { delegate.overlay.orderOut(nil) }
      delegate.modeStore.dispatch(.openCommand(scope: .finder(all: true)))
      delegate.overlay.inputMode = .candidateFinder

      delegate.overlayDidCancelCandidateFinder()

      XCTAssertEqual(delegate.modeStore.mode, origin.advancedEnabled ? .passthrough : .disabled)
    }
  }

  func testEmptyFinderSubmissionClosesTheMode() {
    let delegate = delegate(in: .normal)
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.openCommand(scope: .finder(all: false)))
    delegate.overlay.inputMode = .candidateFinder

    delegate.overlayDidSubmitCandidateFinder()

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testCandidateEffectClosesFinderBeforeReturningToTheApp() {
    let delegate = delegate(in: .normal)
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.openCommand(scope: .finder(all: true)))
    delegate.overlay.inputMode = .candidateFinder

    delegate.openSourceItem(Candidate(title: "Invalid destination", effect: .openURL("")))

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
    XCTAssertFalse(delegate.overlay.modeBadgeCapturesInput)
  }

  func testCandidateEffectCannotRecapturePassthroughAfterCommandDismissal() {
    for origin in [Mode.passthrough, .disabled] {
      let delegate = delegate(in: origin)
      defer { delegate.overlay.orderOut(nil) }

      delegate.openSourceItem(Candidate(title: "Invalid destination", effect: .openURL("")))

      XCTAssertEqual(delegate.modeStore.mode, origin)
      XCTAssertFalse(delegate.overlay.modeBadgeCapturesInput)
    }
  }

  private func delegate(in mode: Mode) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.keyboardCaptureActive = true
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.modeStore.dispatch(.startup(advancedEnabled: mode.advancedEnabled))
    if mode == .normal { delegate.modeStore.dispatch(.enterNormal(targetPID: nil)) }
    return delegate
  }
}
