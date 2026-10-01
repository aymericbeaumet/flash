import AppKit
import XCTest

@testable import flash

final class SystemChangeMonitorsTests: XCTestCase {
  private final class FakeSource: HostEventSource {
    var started = 0
    var stopped = 0
    func start() { started += 1 }
    func stop() { stopped += 1 }
  }

  /// A monitor runs exactly while some plugin listens to its event.
  func testMonitorsRunOnlyWhileAPluginListens() {
    var made: [String: [FakeSource]] = [:]
    func factory(_ event: String) -> () -> any HostEventSource {
      {
        let source = FakeSource()
        made[event, default: []].append(source)
        return source
      }
    }
    let sources = HostEventSources([
      PluginProtocol.networkChangedEvent: factory(PluginProtocol.networkChangedEvent),
      PluginProtocol.volumesChangedEvent: factory(PluginProtocol.volumesChangedEvent),
    ])
    sources.reconcile { _ in false }
    XCTAssertTrue(made.isEmpty, "no listener, no monitor")

    var listening: Set<String> = [PluginProtocol.networkChangedEvent]
    sources.reconcile { listening.contains($0) }
    XCTAssertEqual(sources.runningEvents, [PluginProtocol.networkChangedEvent])
    XCTAssertEqual(made[PluginProtocol.networkChangedEvent]?.first?.started, 1)
    // A reconcile with the same listeners changes nothing.
    sources.reconcile { listening.contains($0) }
    XCTAssertEqual(made[PluginProtocol.networkChangedEvent]?.count, 1)

    listening = [PluginProtocol.volumesChangedEvent]
    sources.reconcile { listening.contains($0) }
    XCTAssertEqual(sources.runningEvents, [PluginProtocol.volumesChangedEvent])
    XCTAssertEqual(made[PluginProtocol.networkChangedEvent]?.first?.stopped, 1)

    sources.stopAll()
    XCTAssertEqual(sources.runningEvents, [])
    XCTAssertEqual(made[PluginProtocol.volumesChangedEvent]?.first?.stopped, 1)
  }

  func testABurstOfChangesIsOneSignal() {
    let queue = DispatchQueue(label: "signal.tests")
    let fired = expectation(description: "one signal for the burst")
    fired.assertForOverFulfill = true
    let signal = CoalescedSignal(id: "test:burst", queue: queue, delayMs: 50) { fired.fulfill() }
    for _ in 0..<20 { signal.signal() }
    wait(for: [fired], timeout: 5)
    // The window closed: the next change is a new signal.
    let again = expectation(description: "a later change signals again")
    let later = CoalescedSignal(id: "test:later", queue: queue, delayMs: 10) { again.fulfill() }
    later.signal()
    wait(for: [again], timeout: 5)
  }

  func testCancellingDropsAPendingSignal() {
    let queue = DispatchQueue(label: "signal.cancel.tests")
    let dropped = expectation(description: "cancelled signal never fires")
    dropped.isInverted = true
    let signal = CoalescedSignal(id: "test:cancel", queue: queue, delayMs: 50) { dropped.fulfill() }
    signal.signal()
    signal.cancel()
    wait(for: [dropped], timeout: 0.3)
  }

  func testVolumeNotificationsCoalesceIntoOneEventAndStopWithTheMonitor() {
    let center = NotificationCenter()
    let fired = expectation(description: "mount burst signals once")
    fired.assertForOverFulfill = true
    var monitor: VolumeChangeMonitor? = VolumeChangeMonitor(center: center, coalesceMs: 50) {
      fired.fulfill()
    }
    monitor?.start()
    for name in VolumeChangeMonitor.notifications { center.post(name: name, object: nil) }
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    wait(for: [fired], timeout: 5)

    monitor?.stop()
    let silent = expectation(description: "a stopped monitor observes nothing")
    silent.isInverted = true
    monitor = VolumeChangeMonitor(center: center, coalesceMs: 10) { silent.fulfill() }
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    wait(for: [silent], timeout: 0.2)
    monitor = nil
  }

  func testNetworkMonitorWatchesAddressesRoutesAndLinksOnly() {
    XCTAssertEqual(
      NetworkChangeMonitor.watchedKeys,
      ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS"])
    let pattern = try? NSRegularExpression(pattern: NetworkChangeMonitor.watchedPatterns[0])
    func watched(_ key: String) -> Bool {
      guard let pattern else { return false }
      let range = NSRange(key.startIndex..., in: key)
      return pattern.firstMatch(in: key, range: range)?.range == range
    }
    XCTAssertTrue(watched("State:/Network/Interface/en0/IPv4"))
    XCTAssertTrue(watched("State:/Network/Interface/utun3/IPv6"))
    XCTAssertTrue(watched("State:/Network/Interface/en0/Link"))
    // Wi-Fi details (network name, signal) are not a network change here.
    XCTAssertFalse(watched("State:/Network/Interface/en0/AirPort"))

    // The dynamic store accepts the registration and releases it cleanly.
    let monitor = NetworkChangeMonitor {}
    monitor.start()
    monitor.stop()
    monitor.stop()
  }
}
