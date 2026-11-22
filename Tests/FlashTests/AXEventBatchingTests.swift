import ApplicationServices
import XCTest

@testable import flash

final class AXEventBatchingTests: XCTestCase {
  func testObserverTeardownRevokesAlreadyQueuedEvents() throws {
    let monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    let pid = getpid()
    var observer: AXObserver?
    XCTAssertEqual(AXObserverCreate(pid, AppMonitor.observerCallback, &observer), .success)
    let context = AppMonitor.ObserverContext(monitor: monitor, pid: pid, bundleIdentifier: nil)
    monitor.observers[pid] = AppMonitor.ObserverEntry(
      observer: try XCTUnwrap(observer), appElement: AXUIElementCreateApplication(pid),
      context: context, notifications: [])
    monitor.enqueueAXEvent(
      AppMonitor.PendingAXEvent(
        context: context, notification: "AXLayoutChanged",
        observedElementIsFocusedWindow: false, observedWindow: nil))

    monitor.teardownAllObservers()
    // A callback that had already started may enqueue after source removal.
    monitor.enqueueAXEvent(
      AppMonitor.PendingAXEvent(
        context: context, notification: "AXLayoutChanged",
        observedElementIsFocusedWindow: false, observedWindow: nil))
    monitor.drainAXEvents()

    XCTAssertNil(monitor.dirtyTokens[pid], "a queued callback from a removed observer is obsolete")
    XCTAssertFalse(monitor.modelScheduler.hasRefresh(pid: pid))
  }

  /// Observer callbacks arrive on a background thread; every event still
  /// bumps the pid's dirty token exactly once, in order, on main.
  func testEnqueuedEventsDrainOnMainAndBumpDirtyTokens() {
    let registry = SourceRegistry(descriptors: [], runningApplications: [])
    let monitor = AppMonitor(registry: registry, config: .default)
    let pid: pid_t = 4242
    let context = AppMonitor.ObserverContext(monitor: monitor, pid: pid, bundleIdentifier: nil)
    let drained = expectation(description: "batch drained on main")

    DispatchQueue.global().async {
      for _ in 0..<3 {
        monitor.enqueueAXEvent(
          AppMonitor.PendingAXEvent(
            context: context, notification: "AXLayoutChanged",
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
    let context = AppMonitor.ObserverContext(monitor: monitor, pid: pid, bundleIdentifier: nil)
    for round in 1...2 {
      let drained = expectation(description: "round \(round)")
      DispatchQueue.global().async {
        monitor.enqueueAXEvent(
          AppMonitor.PendingAXEvent(
            context: context, notification: "AXValueChanged",
            observedElementIsFocusedWindow: false, observedWindow: nil))
        DispatchQueue.main.async { drained.fulfill() }
      }
      wait(for: [drained], timeout: 2)
      XCTAssertEqual(monitor.dirtyTokens[pid], UInt64(round))
    }
  }
}
