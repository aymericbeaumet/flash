import AppKit
import QuartzCore
import XCTest

@testable import flash

/// The native command editor lives beside the layer-hosting drawing view, so
/// rebuilding Flash's drawing sublayers can never detach AppKit's editor
/// backing layers.
final class OverlayNativeEditorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testTransientRecyclePreservesNativeEditorBackingLayers() throws {
    let panel = OverlayPanel()
    let view = try XCTUnwrap(panel.contentView)
    panel.commandTextField.wantsLayer = true
    panel.configureCommandTextField(
      promptFrame: CGRect(x: 100, y: 450, width: 600, height: 38),
      font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), fontSize: 14)
    defer { panel.hideCommandTextField() }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    CATransaction.flush()

    let editorLayer = try XCTUnwrap(panel.commandTextField.layer)
    let editorParent = try XCTUnwrap(editorLayer.superlayer)
    panel.recycleAll()
    XCTAssertTrue(editorLayer.superlayer === editorParent)
    XCTAssertTrue(editorParent.sublayers?.contains { $0 === editorLayer } == true)
  }

  func testDrawingSurfaceResizesWithThePanelWithoutContainingNativeSubviews() throws {
    let panel = OverlayPanel()
    let container = try XCTUnwrap(panel.contentView)
    let drawingView = try XCTUnwrap(
      container.subviews.first { $0.layer === panel.contentLayer })
    XCTAssertTrue(drawingView.subviews.isEmpty)
    XCTAssertTrue(panel.commandTextField.superview === container)
    XCTAssertFalse(container.layer === panel.contentLayer)
    XCTAssertNil(panel.contentLayer.delegate)

    for frame in [
      CGRect(x: 0, y: 0, width: 1_440, height: 900),
      CGRect(x: -1_920, y: 0, width: 3_360, height: 1_080),
      CGRect(x: 0, y: -900, width: 1_920, height: 1_980),
    ] {
      panel.applyPanelFrame(frame)
      container.layoutSubtreeIfNeeded()
      XCTAssertEqual(drawingView.frame, container.bounds)
      XCTAssertEqual(panel.contentLayer.frame, drawingView.bounds)
      XCTAssertTrue(drawingView.layer === panel.contentLayer)
    }
  }
}
