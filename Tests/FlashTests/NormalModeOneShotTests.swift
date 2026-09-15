import AppKit
import FlashCore
import XCTest

@testable import flash

final class NormalModeOneShotTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testResolvedNormalMappingReturnsToPassthrough() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }

    delegate.overlayDidHandleNormalMode(.flashCommand(.dismissAlert), repeatCount: 1)

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testNativeNormalMappingReturnsToPassthrough() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }

    delegate.dispatchNativeMappingAction(.flashCommand(.dismissAlert))

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testUnresolvedCountOrPrefixDoesNotConsumeNormalEntry() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }

    for pending in ["3", "3g"] {
      delegate.overlay.normalModePending = pending
      delegate.overlayDidHandleNormalMode(nil, repeatCount: 3)
      XCTAssertTrue(delegate.modeStore.mode.isNormal)
    }

    delegate.overlayDidHandleNormalMode(.flashCommand(.dismissAlert), repeatCount: 3)
    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
    XCTAssertEqual(delegate.overlay.normalModePending, "")
  }

  func testPointerMappingKeepsInteractionUntilCancellation() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }

    delegate.overlayDidHandleNormalMode(.flashCommand(.mousePointer), repeatCount: 1)

    XCTAssertTrue(delegate.modeStore.mode.isNormal)
    XCTAssertTrue(delegate.hintSession.pointerModeActive)

    delegate.overlayDidPointer(.exit)

    XCTAssertFalse(delegate.hintSession.isActive)
    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testPersistentNormalKeepsCaptureAfterMappingsAndHintCancellation() {
    let delegate = delegateInNormalMode(persistent: true)
    defer { delegate.overlay.orderOut(nil) }

    delegate.overlayDidHandleNormalMode(.flashCommand(.dismissAlert), repeatCount: 3)
    delegate.dispatchNativeMappingAction(.flashCommand(.dismissAlert))
    delegate.overlayDidHandleNormalMode(.flashCommand(.mousePointer), repeatCount: 1)
    delegate.overlayDidPointer(.exit)

    XCTAssertEqual(delegate.modeStore.mode, .normal(persistent: true))
  }

  func testExternalCommandDoesNotConsumeNormalEntry() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }

    XCTAssertTrue(delegate.handleURLCommand(.dismissAlert))
    delegate.applyModeOverlay()

    XCTAssertEqual(delegate.modeStore.mode, .normal(persistent: false))
  }

  func testMappedNormalEntrySurvivesItsOuterCommandDispatch() {
    for persistent in [true, false] {
      let delegate = delegateInNormalMode()
      defer { delegate.overlay.orderOut(nil) }

      delegate.overlayDidHandleNormalMode(
        .flashCommand(.normalMode(persistent: persistent)), repeatCount: 1)

      XCTAssertEqual(delegate.modeStore.mode, .normal(persistent: persistent))
    }
  }

  func testEmptyAsynchronousDiscoveryEndsOneShotNormal() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.normalActionStarted)
    let token = delegate.activationLifecycle.begin()
    delegate.modeStore.dispatch(.normalActionDispatched(hasTransientInput: true))

    delegate.applyModeOverlay()
    XCTAssertTrue(delegate.modeStore.mode.isNormal)
    XCTAssertTrue(delegate.activationLifecycle.complete(token: token))
    delegate.applyModeOverlay()

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testCancelingDiscoveryEndsOneShotAndInvalidatesItsCompletion() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }
    delegate.modeStore.dispatch(.normalActionStarted)
    let token = delegate.activationLifecycle.begin()
    delegate.modeStore.dispatch(.normalActionDispatched(hasTransientInput: true))

    delegate.cancelOverlay()

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
    XCTAssertFalse(delegate.activationLifecycle.complete(token: token))
  }

  func testOneShotWaitsUntilTheCommitReleasesItsOwnedInput() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }
    delegate.overlayDidHandleNormalMode(.flashCommand(.mousePointer), repeatCount: 1)
    delegate.clearHintSessionState()
    var finishInput: (() -> Void)?
    var appliedOutcome = false
    delegate.performHintCommit {
      finishInput = $0
    } completion: { _ in
      appliedOutcome = true
    }

    XCTAssertTrue(delegate.modeStore.mode.isNormal)
    XCTAssertFalse(appliedOutcome)
    finishInput?()

    XCTAssertTrue(appliedOutcome)
    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testQueuedReplacementRetainsOneShotInteractionOwnership() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }
    delegate.overlayDidHandleNormalMode(.flashCommand(.mousePointer), repeatCount: 1)
    delegate.clearHintSessionState()
    var finishInput: (() -> Void)?
    delegate.performHintCommit {
      finishInput = $0
    } completion: { _ in
      XCTFail("A replaced gesture cannot apply its old mode outcome")
    }

    delegate.enterPointerMode()
    finishInput?()

    XCTAssertTrue(delegate.modeStore.mode.isNormal)
    XCTAssertTrue(delegate.hintSession.pointerModeActive)
    delegate.overlayDidPointer(.exit)
    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testCountedSourceCallbacksRetainTheirTargetAfterNormalExits() {
    let delegate = delegateInNormalMode()
    defer { delegate.overlay.orderOut(nil) }
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    let context = AppContext(
      bundleIdentifier: "test.original", processID: 12345, runningApp: .current,
      frontWindowFrame: .zero, allScreensFrame: .zero)
    var callbacks: [(SourceActionResult) -> Void] = []
    var attemptedPIDs: [pid_t] = []
    var fallbackCount: Int?
    var fallbackTargetPID: pid_t?

    delegate.performTabSourceAction(
      name: "tab_next", repeatCount: 3, contextOverride: context,
      action: { _, context, completion in
        attemptedPIDs.append(context.processID)
        callbacks.append(completion)
      },
      fallback: { context, count in
        fallbackCount = count
        fallbackTargetPID =
          delegate.normalModeKeyDispatchTarget(contextOverride: context)?.processID
      })
    delegate.enterPassthroughMode()
    delegate.normalModeTargetPID = 54321

    callbacks.removeFirst()(.performed(pid: 67890))
    callbacks.removeFirst()(.unhandled)

    XCTAssertEqual(attemptedPIDs, [12345, 12345])
    XCTAssertEqual(fallbackCount, 2)
    XCTAssertEqual(fallbackTargetPID, 12345)
    XCTAssertEqual(delegate.normalModeTargetPID, 54321)
    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  func testLateHandoffCannotExitANewerPersistentNormalEntry() {
    let delegate = delegateInNormalMode(persistent: true)
    defer { delegate.overlay.orderOut(nil) }
    let oldCommand = delegate.normalModePendingCommandToken

    delegate.dispatchNativeMappingAction(.flashCommand(.normalMode(persistent: true)))
    delegate.completeNormalModeHandoff(commandToken: oldCommand, targetPID: nil)

    XCTAssertEqual(delegate.modeStore.mode, .normal(persistent: true))
  }

  func testCurrentPersistentCommandCanStillHandOffKeyboardInput() {
    let delegate = delegateInNormalMode(persistent: true)
    defer { delegate.overlay.orderOut(nil) }

    delegate.completeNormalModeHandoff(
      commandToken: delegate.normalModePendingCommandToken, targetPID: nil)

    XCTAssertEqual(delegate.modeStore.mode, .passthrough)
  }

  private func delegateInNormalMode(persistent: Bool = false) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.keyboardCaptureActive = true
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.enterNormalMode(persistent: persistent)
    return delegate
  }
}
