import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class TargetFinalizerTests: XCTestCase {
  func testFiltersInvisibleTargetsBeforeLabelsAreAssigned() {
    let visible = CGRect(x: 0, y: 0, width: 200, height: 200)
    let candidates = (0..<700).map { i in
      let frame: CGRect
      if i < 10 {
        frame = CGRect(x: CGFloat(i * 12), y: 20, width: 8, height: 8)
      } else {
        frame = CGRect(x: 1000 + CGFloat(i), y: 1000, width: 8, height: 8)
      }
      return candidate(id: "t\(i)", frame: frame)
    }

    let finalized = TargetFinalizer.finalize(candidates, visibleRegions: [visible])
    XCTAssertEqual(finalized.count, 10)

    let labels = HintAssigner.generateLabels(
      count: finalized.count,
      alphabet: Array("abcdefghijklmnopqrstuvwxyz"))
    XCTAssertEqual(labels.map(\.count).max(), 1)
  }

  func testDedupKeepsSmallerOverlappingTarget() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let large = candidate(
      id: "large",
      frame: CGRect(x: 20, y: 20, width: 120, height: 120),
      priority: 20)
    let small = candidate(
      id: "small",
      frame: CGRect(x: 30, y: 30, width: 30, height: 30),
      priority: 10)

    let finalized = TargetFinalizer.finalize([large, small], visibleRegions: [visible])
    XCTAssertEqual(finalized.map(\.id), ["small"])
  }

  func testDedupTieKeepsHigherPriorityProvider() {
    let visible = CGRect(x: 0, y: 0, width: 300, height: 300)
    let low = candidate(
      id: "low",
      frame: CGRect(x: 20, y: 20, width: 40, height: 40),
      priority: 10,
      providerOrder: 1)
    let high = candidate(
      id: "high",
      frame: CGRect(x: 20, y: 20, width: 40, height: 40),
      priority: 20,
      providerOrder: 0)

    let finalized = TargetFinalizer.finalize([low, high], visibleRegions: [visible])
    XCTAssertEqual(finalized.map(\.id), ["high"])
  }

  private func candidate(
    id: String,
    frame: CGRect,
    priority: Int = 10,
    providerOrder: Int = 0
  ) -> TargetCandidate {
    TargetCandidate(
      target: JumpTarget(id: id, frame: frame, pid: 42, providerID: "test"),
      priority: priority,
      providerOrder: providerOrder,
      ordinal: 0)
  }
}
