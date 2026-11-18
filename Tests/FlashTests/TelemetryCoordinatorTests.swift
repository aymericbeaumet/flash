import XCTest

@testable import flash

final class TelemetryCoordinatorTests: XCTestCase {
  private func exporter(_ coordinator: TelemetryCoordinator, _ telemetry: Config.Telemetry)
    throws -> [String: Any]
  {
    try XCTUnwrap(coordinator.stateJSON(for: telemetry)["exporter"] as? [String: Any])
  }

  /// The exporter follows the configuration: started for an endpoint,
  /// stopped once it is gone, and every reconcile reports the state at once.
  func testTheExporterFollowsTheConfiguration() throws {
    let coordinator = TelemetryCoordinator()
    defer { coordinator.stop() }
    var reports = 0
    coordinator.wire(stateChanged: { reports += 1 }, observedChanged: {})

    let off = Config.default.telemetry
    coordinator.configure(off)
    XCTAssertEqual(reports, 1)
    XCTAssertEqual(try exporter(coordinator, off)["enabled"] as? Bool, false)
    let receiver = try XCTUnwrap(coordinator.stateJSON(for: off)["receiver"] as? [String: Any])
    XCTAssertEqual(receiver["listening"] as? Bool, false)

    let exporting = ConfigLoader.parse(
      """
      [telemetry.exporter]
      endpoint = "https://collector.example"
      """
    ).telemetry
    coordinator.configure(exporting)
    XCTAssertEqual(reports, 2)
    XCTAssertEqual(try exporter(coordinator, exporting)["enabled"] as? Bool, true)
    XCTAssertNotNil(FlashTelemetry.current, "Flash's own telemetry reaches the exporter")

    coordinator.configure(off)
    XCTAssertEqual(reports, 3)
    XCTAssertEqual(try exporter(coordinator, off)["enabled"] as? Bool, false)
    XCTAssertNil(FlashTelemetry.current)
  }

  /// A change the store reports on its own queue is one report on main.
  func testAStoreChangeReportsOnMain() {
    let coordinator = TelemetryCoordinator()
    defer { FlashTelemetry.installStore(nil) }
    let reported = expectation(description: "state changed")
    reported.assertForOverFulfill = false
    coordinator.wire(
      stateChanged: {
        dispatchPrecondition(condition: .onQueue(.main))
        reported.fulfill()
      }, observedChanged: {})
    coordinator.store.record(
      MetricRecord(
        instrument: MetricInstrument(name: "test.coordinator", kind: .gauge), value: 1,
        attributes: [:]),
      scope: MetricRecord.recordedScope)
    wait(for: [reported], timeout: 5)
  }
}
