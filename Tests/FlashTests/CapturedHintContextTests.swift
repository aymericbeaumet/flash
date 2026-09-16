import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class CapturedHintContextTests: XCTestCase {
  func testOpaqueContextIdentitySurvivesWireDecode() throws {
    var raw = wireTarget
    raw["context_id"] = "[\"remote\",\"tty\",42,\"$1\",\"@3\",\"%1\"]"
    let target = try XCTUnwrap(PluginWireCodec.target(from: raw, sourceID: "plugin:tmux"))
    XCTAssertEqual(target.contextID, raw["context_id"] as? String)
    XCTAssertEqual(target.capturedTarget(contextPID: 99).contextID, target.contextID)
    XCTAssertEqual(target.capturedTarget(contextPID: 99).pid, 42)
  }

  func testMalformedContextRejectsTheTarget() {
    for value: Any in ["", 42, false, ["identity"]] {
      var raw = wireTarget
      raw["context_id"] = value
      XCTAssertNil(PluginWireCodec.target(from: raw, sourceID: "plugin:tmux"))
    }
  }

  func testUnspecifiedContextRemainsUnspecified() throws {
    var raw = wireTarget
    XCTAssertNil(
      try XCTUnwrap(PluginWireCodec.target(from: raw, sourceID: "plugin:tmux")).contextID)
    raw["context_id"] = NSNull()
    XCTAssertNil(
      try XCTUnwrap(PluginWireCodec.target(from: raw, sourceID: "plugin:tmux")).contextID)
  }

  func testSamePaneLabelInAnotherBackendCannotReplaceTheCapturedPane() {
    let captured = target(context: "server-a/pane-1")
    XCTAssertNil(
      captured.matchingClickPoint(
        preferred: CGPoint(x: 15, y: 15), among: [target(context: "server-b/pane-1")]))
    XCTAssertNil(
      captured.matchingClickPoint(
        preferred: CGPoint(x: 15, y: 15), among: [target(context: nil)]))
  }

  func testContextDisambiguatesIdenticalLinkLabelsInDifferentPanes() {
    let captured = target(context: "server-a/pane-1")
    XCTAssertEqual(
      captured.matchingClickPoint(
        preferred: CGPoint(x: 15, y: 15),
        among: [target(context: "server-a/pane-2"), target(context: "server-a/pane-1")]),
      CGPoint(x: 15, y: 15))
  }

  private func target(context: String?) -> JumpTarget {
    JumpTarget(
      id: "walk-1", frame: CGRect(x: 10, y: 10, width: 20, height: 20),
      role: "tmux-pane", accessibilityLabel: "%1", contextID: context,
      pid: 42, providerID: "plugin:tmux")
  }

  private var wireTarget: [String: Any] {
    [
      "id": "walk-1", "role": "tmux-pane", "label": "%1", "pid": 42,
      "frame": ["x": 10, "y": 10, "width": 20, "height": 20],
    ]
  }
}
