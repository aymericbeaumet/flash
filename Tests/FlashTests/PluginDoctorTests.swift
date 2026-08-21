import XCTest

@testable import flash

final class PluginDoctorTests: XCTestCase {
  private func status(id: String, root: String, state: String = "running") -> PluginStatus {
    PluginStatus(
      id: id, name: id, version: "0.1.0", description: "", origin: "official",
      root: root, state: state, activation: "resident", pid: nil, uptimeMs: nil,
      sourceCount: 0, commandCount: 0, restartCount: 0, lastError: nil,
      lastLog: nil, cpuPercent: nil, memoryBytes: nil, onlyBundleIDs: [],
      priority: 25, commands: [], statusSegments: [:])
  }

  func testHealthyBundledPluginReportsOkWithSandboxMode() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Plugins/media")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path),
      "run from the repo root")
    let report = PluginDoctor.run(statuses: [status(id: "media", root: root.path)])
    XCTAssertEqual(report.issues, 0, report.lines.joined(separator: "\n"))
    let line = try XCTUnwrap(report.lines.first { $0.contains("media") })
    XCTAssertTrue(line.hasPrefix("ok "), line)
    XCTAssertTrue(line.contains("sandbox="), line)
  }

  func testFailedStateAndMissingManifestAreIssues() {
    var parked = status(id: "ghost", root: "/nonexistent/ghost", state: "failed")
    parked.lastError = "boom"
    let report = PluginDoctor.run(statuses: [parked])
    XCTAssertEqual(report.issues, 1)
    let line = report.lines.joined(separator: "\n")
    XCTAssertTrue(line.contains("!! ghost"), line)
    XCTAssertTrue(line.contains("parked failed: boom"), line)
    XCTAssertTrue(line.contains("manifest:"), line)
  }
}
