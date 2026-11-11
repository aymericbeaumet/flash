import AppKit
import XCTest

@testable import flash

final class CommandTargetDeliveryTests: XCTestCase {
  private func makeDelegate() -> AppDelegate {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    return delegate
  }

  func testCapturedInsertionSurvivesMappingRefreshDuringFocusHandoff() {
    let delegate = makeDelegate()
    var pending: (() -> Void)?
    var delivered = false
    delegate.scheduleCommandTargetDelivery(
      targetIsActive: { true }, schedule: { pending = $0 }, deliver: { delivered = true })
    delegate.refreshEffectiveMappings(for: "com.flash.native-fixture")
    delegate.resetPendingNormalSequence(reason: "mapping_scope")
    pending?()
    XCTAssertTrue(delivered)
  }

  func testClosingTheSessionCancelsCapturedInsertion() {
    let delegate = makeDelegate()
    var pending: (() -> Void)?
    var delivered = false
    delegate.scheduleCommandTargetDelivery(
      targetIsActive: { true }, schedule: { pending = $0 }, deliver: { delivered = true })
    delegate.resetCommandLineState()
    pending?()
    XCTAssertFalse(delivered)
  }

  func testReplacementSessionDeliversOnlyItsOwnSelection() {
    let delegate = makeDelegate()
    var pending: [() -> Void] = []
    var delivered: [String] = []
    delegate.scheduleCommandTargetDelivery(
      targetIsActive: { true }, schedule: { pending.append($0) },
      deliver: { delivered.append("old") })
    delegate.resetCommandLineState()
    delegate.scheduleCommandTargetDelivery(
      targetIsActive: { true }, schedule: { pending.append($0) },
      deliver: { delivered.append("new") })
    for callback in pending { callback() }
    XCTAssertEqual(delivered, ["new"])
  }

  func testCapturedInsertionDoesNotFollowFocusToAnotherApp() {
    let delegate = makeDelegate()
    var pending: (() -> Void)?
    var delivered = false
    delegate.scheduleCommandTargetDelivery(
      targetIsActive: { false }, schedule: { pending = $0 }, deliver: { delivered = true })
    pending?()
    XCTAssertFalse(delivered)
  }
}
