import XCTest

@testable import flash

final class AXEventBatchingTests: XCTestCase {
  /// Observer callbacks arrive on a background thread; every event still
  /// bumps the pid's dirty token exactly once, in order, on main.
  func testEnqueuedEventsDrainOnMainAndBumpDirtyTokens() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid: pid_t = 4242
    let drained = expectation(description: "batch drained on main")

    DispatchQueue.global().async {
      for _ in 0..<3 {
        monitor.enqueueAXEvent(
          AppMonitor.PendingAXEvent(
            pid: pid, notification: "AXLayoutChanged",
            observedElementIsFocusedWindow: false, observedWindow: nil))
      }
      // Ordered behind the single drain the first enqueue armed.
      DispatchQueue.main.async { drained.fulfill() }
    }

    wait(for: [drained], timeout: 2)
    XCTAssertEqual(monitor.dirtyTokens[pid], 3)
  }

  func testSecondBurstArmsANewDrain() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid: pid_t = 4243
    for round in 1...2 {
      let drained = expectation(description: "round \(round)")
      DispatchQueue.global().async {
        monitor.enqueueAXEvent(
          AppMonitor.PendingAXEvent(
            pid: pid, notification: "AXValueChanged",
            observedElementIsFocusedWindow: false, observedWindow: nil))
        DispatchQueue.main.async { drained.fulfill() }
      }
      wait(for: [drained], timeout: 2)
      XCTAssertEqual(monitor.dirtyTokens[pid], UInt64(round))
    }
  }
}
