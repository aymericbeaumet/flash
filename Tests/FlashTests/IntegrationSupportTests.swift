import CoreGraphics
import FlashCore
import FlashIntegrationTestSupport
import XCTest

final class IntegrationSupportTests: XCTestCase {
  func testTargetMatcherMatchesByNormalizedLabelAndRole() {
    let expected = [
      ExpectedIntegrationTarget(id: "primary", label: " Primary   Action ", role: "AXButton")
    ]
    let actual = [
      target(id: "a", label: "Primary Action", role: "AXButton"),
      target(id: "b", label: "Secondary", role: "AXButton"),
    ]

    let diff = IntegrationTargetMatcher.classify(
      expected: expected,
      actual: actual,
      allowedUnexpectedLabels: ["Secondary"])

    XCTAssertEqual(diff.matches.count, 1)
    XCTAssertTrue(diff.missing.isEmpty)
    XCTAssertTrue(diff.unexpected.isEmpty)
  }

  func testTargetMatcherCanIgnoreUnlabeledUnexpectedTargets() {
    let diff = IntegrationTargetMatcher.classify(
      expected: [],
      actual: [target(id: "row", label: nil, role: "AXRow")],
      ignoreUnlabeledUnexpected: true)

    XCTAssertTrue(diff.unexpected.isEmpty)
  }

  func testTargetMatcherHandlesDuplicateExpectedLabels() {
    let expected = [
      ExpectedIntegrationTarget(id: "first", label: "Duplicate Action", role: "AXButton"),
      ExpectedIntegrationTarget(id: "second", label: "Duplicate Action", role: "AXButton"),
    ]
    let actual = [
      target(id: "a", label: "Duplicate Action", role: "AXButton"),
      target(id: "b", label: "Duplicate Action", role: "AXButton"),
    ]

    let diff = IntegrationTargetMatcher.classify(expected: expected, actual: actual)

    XCTAssertEqual(diff.matches.count, 2)
    XCTAssertTrue(diff.missing.isEmpty)
    XCTAssertTrue(diff.unexpected.isEmpty)
  }

  func testTargetMatcherUsesRectWhenProvided() {
    let expected = [
      ExpectedIntegrationTarget(
        id: "near",
        label: "Near",
        role: "AXButton",
        rect: ExpectedRect(x: 10, y: 10, width: 20, height: 20))
    ]
    let near = target(
      id: "near",
      label: "Near",
      role: "AXButton",
      frame: CGRect(x: 12, y: 12, width: 20, height: 20))
    let far = target(
      id: "far",
      label: "Near",
      role: "AXButton",
      frame: CGRect(x: 300, y: 300, width: 20, height: 20))

    XCTAssertTrue(IntegrationTargetMatcher.targetMatches(expected: expected[0], actual: near))
    XCTAssertFalse(IntegrationTargetMatcher.targetMatches(expected: expected[0], actual: far))
  }

  func testIntegrationTimerWritesJSON() throws {
    let timer = IntegrationTimer()
    timer.mark("start")
    _ = timer.measure("work") { 42 }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-integration-timer-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try timer.writeJSON(to: url)

    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode([IntegrationTimingEvent].self, from: data)
    XCTAssertEqual(decoded.map(\.name), ["start", "work"])
    XCTAssertNotNil(decoded[1].durationMs)
  }

  private func target(
    id: String,
    label: String?,
    role: String?,
    frame: CGRect = CGRect(x: 0, y: 0, width: 20, height: 20)
  ) -> JumpTarget {
    JumpTarget(
      id: id,
      frame: frame,
      role: role,
      accessibilityLabel: label,
      pid: 42,
      providerID: "test")
  }
}
