import AppKit
import XCTest

@testable import flash

/// The desktop widget window, its placement, and the surface drawn into it.
final class WidgetWindowTests: XCTestCase {
  func testTheWindowIsAClickThroughDesktopLayerThatNeverTakesFocus() {
    let window = WidgetWindow(
      frame: CGRect(x: 0, y: 0, width: 120, height: 40), sharingType: .readOnly)
    defer { window.close() }
    XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
    XCTAssertLessThan(window.level, .normal)
    XCTAssertTrue(window.ignoresMouseEvents)
    XCTAssertFalse(window.canBecomeKey)
    XCTAssertFalse(window.canBecomeMain)
    XCTAssertEqual(window.styleMask, [.borderless, .nonactivatingPanel])
    XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces, .stationary, .ignoresCycle])
    XCTAssertFalse(
      window.collectionBehavior.contains(.fullScreenAuxiliary),
      "a full-screen app covers the desktop and its widgets")
    XCTAssertFalse(window.isOpaque)
    XCTAssertFalse(window.hasShadow)
    XCTAssertEqual(window.sharingType, .readOnly)
    let hidden = WidgetWindow(frame: .zero, sharingType: .none)
    defer { hidden.close() }
    XCTAssertEqual(hidden.sharingType, .none)
  }

  func testEveryAnchorPlacesTheWidgetGapPointsInFromItsEdges() {
    let usable = CGRect(x: 100, y: 50, width: 1000, height: 800)
    let size = CGSize(width: 100, height: 50)
    let gap = CGSize(width: 24, height: 30)
    let expected: [(Config.Widget.Anchor, CGPoint)] = [
      (.topLeft, CGPoint(x: 124, y: 770)),
      (.topCentre, CGPoint(x: 550, y: 770)),
      (.topRight, CGPoint(x: 976, y: 770)),
      (.centreLeft, CGPoint(x: 124, y: 425)),
      (.centre, CGPoint(x: 550, y: 425)),
      (.centreRight, CGPoint(x: 976, y: 425)),
      (.bottomLeft, CGPoint(x: 124, y: 80)),
      (.bottomCentre, CGPoint(x: 550, y: 80)),
      (.bottomRight, CGPoint(x: 976, y: 80)),
    ]
    XCTAssertEqual(expected.count, Config.Widget.Anchor.allCases.count)
    for (anchor, origin) in expected {
      XCTAssertEqual(
        WidgetPlacement.frame(anchor: anchor, gap: gap, size: size, usable: usable),
        CGRect(origin: origin, size: size), anchor.rawValue)
    }
  }

  func testPlacementStaysInsideTheUsableFrameAndKeepsTheTopLeftOfAnOversizedWidget() {
    let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 100, height: 50)
    XCTAssertEqual(
      WidgetPlacement.frame(
        anchor: .topLeft, gap: CGSize(width: 4_000, height: 4_000), size: size, usable: usable),
      CGRect(x: 900, y: 0, width: 100, height: 50))
    XCTAssertEqual(
      WidgetPlacement.frame(
        anchor: .bottomRight, gap: CGSize(width: 4_000, height: 4_000), size: size,
        usable: usable),
      CGRect(x: 0, y: 750, width: 100, height: 50))
    let huge = CGSize(width: 1_200, height: 900)
    XCTAssertEqual(
      WidgetPlacement.frame(anchor: .bottomRight, gap: .zero, size: huge, usable: usable),
      CGRect(x: 0, y: -100, width: 1_200, height: 900))
  }

  func testDisplaysAreSelectedPrimaryAllOrNumberedLeftToRight() {
    func layout(_ id: CGDirectDisplayID, _ frame: CGRect) -> WindowScreenLayout {
      WindowScreenLayout(id: id, frame: frame, usableFrame: frame)
    }
    let primary = layout(1, CGRect(x: 0, y: 0, width: 1440, height: 900))
    let left = layout(2, CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    let right = layout(3, CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    let layouts = [primary, left, right]
    func ids(_ selection: Config.Widget.Screen) -> [CGDirectDisplayID] {
      WidgetPlacement.screens(selection, layouts: layouts, widget: "w").map(\.id)
    }
    XCTAssertEqual(ids(.primary), [1])
    XCTAssertEqual(ids(.all), [1, 2, 3])
    XCTAssertEqual(ids(.index(1)), [2])
    XCTAssertEqual(ids(.index(2)), [1])
    XCTAssertEqual(ids(.index(3)), [3])

    let logged = expectation(description: "out-of-range display logged")
    let sink = FlashLog.addSink(minLevel: .debug) { record in
      if record.source == "core:WidgetPlacement", record.message.contains("no display 4 name=w") {
        logged.fulfill()
      }
    }
    defer { FlashLog.removeSink(sink) }
    XCTAssertEqual(ids(.index(4)), [], "a display past the last one shows nothing")
    wait(for: [logged], timeout: 2)
  }

  func testTheFlashBarBandIsNotUsable() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 830)
    let reserved = WindowMover.usableFrame(
      screenFrame: screen, visibleFrame: visible, statusBarReservesSpace: true, fontSize: 13,
      fallbackNativeStatusBarHeight: 24)
    let size = CGSize(width: 200, height: 100)
    let top = WidgetPlacement.frame(
      anchor: .topRight, gap: CGSize(width: 24, height: 24), size: size, usable: reserved)
    XCTAssertEqual(top.maxY, 900 - 24 - 24, "below the bar band, the gap under it")
    let bottom = WidgetPlacement.frame(
      anchor: .bottomLeft, gap: CGSize(width: 24, height: 24), size: size, usable: reserved)
    XCTAssertEqual(bottom.minY, 70 + 24, "above the Dock")
    let unreserved = WindowMover.usableFrame(
      screenFrame: screen, visibleFrame: visible, statusBarReservesSpace: false, fontSize: 13)
    XCTAssertEqual(
      WidgetPlacement.frame(
        anchor: .topRight, gap: CGSize(width: 24, height: 24), size: size, usable: unreserved
      ).maxY, 900 - 24)
  }

  func testTheSurfaceStacksLinesOnItsCellGridAndDrawsOnlyContent() throws {
    let lines = StatusFormatDocument.parse(
      StatusFormatProgram.compile(source: "CPU 12%%\n#[align=right]#[fg=red]right")
        .evaluate(expandTime: true),
      lineBreaksResetAlignment: true
    ).lines()
    var widget = Config.Widget()
    widget.padding = 10
    widget.lineSpacing = 4
    let surface = WidgetSurface()
    let size = surface.render(lines: lines, widget: widget, scale: 2)
    let font = StatusWidgetFont.font(name: "", size: 13)
    let metrics = WidgetSurface.metrics(lines: lines, widget: widget, font: font)
    XCTAssertEqual(metrics.columns, 7, "an auto-sized widget fits its widest line")
    XCTAssertEqual(size, metrics.size)
    XCTAssertEqual(size.width, ceil(7 * metrics.cellWidth + 20))
    XCTAssertEqual(size.height, ceil(2 * metrics.lineHeight + 4 + 20))
    let drawn = surface.runLayers.filter { !$0.container.isHidden }
    XCTAssertEqual(
      drawn.map { ($0.text.string as? NSAttributedString)?.string }, ["CPU 12%", "right"],
      "blank padding cells get no layer")
    let first = drawn[0].container.frame
    let second = drawn[1].container.frame
    XCTAssertEqual(first.minX, 10)
    XCTAssertEqual(first.maxY, size.height - 10, accuracy: 0.001)
    XCTAssertEqual(second.minX, 10 + 2 * metrics.cellWidth, accuracy: 0.001, "right-aligned")
    XCTAssertEqual(first.minY - second.maxY, 4, accuracy: 0.001)
    let text = try XCTUnwrap(drawn[0].text.string as? NSAttributedString)
    let colour = try XCTUnwrap(
      text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    XCTAssertEqual(
      colour, FlashStatusTextColor.nsColor(.rgb(0xD8DEE9)), "default text takes the widget's fg")
    XCTAssertEqual(
      drawn[0].container.sublayers?.count, 1, "a plain run holds only its text layer")
    XCTAssertEqual(surface.backgroundLayer.cornerRadius, 8)
    XCTAssertEqual(WidgetSurface.color("#2E344000")?.alphaComponent, 0)
    XCTAssertEqual(
      WidgetSurface.color("#FF000080")?.alphaComponent ?? 0, 128 / 255, accuracy: 0.001)
    XCTAssertNil(WidgetSurface.color("#GG0000"))
  }

  func testTheControllerPlacesOneWindowPerDisplayOnceItHasLines() throws {
    let display = WindowScreenLayout(
      id: 7, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    var reported: [(String, Bool)] = []
    let controller = WidgetController(
      setVisible: { reported.append(($0, $1)) }, screenLayouts: { _, _ in [display] })
    defer { controller.stop() }
    var widget = Config.Widget()
    widget.anchor = .topRight
    widget.hideFromCapture = true
    controller.apply(
      widgets: ["w": widget], statusBarReservesSpace: true, statusBarMonitor: .all,
      screenCapture: .show)
    func windows() -> [[String: Any]] {
      controller.diagnostics()["windows"] as? [[String: Any]] ?? []
    }
    XCTAssertEqual(windows().count, 1)
    XCTAssertEqual(windows().first?["ordered_in"] as? Bool, false, "no lines, nothing shown")
    controller.show("w", lines: StatusFormatDocument.parse("hello").lines())
    let frame = try XCTUnwrap(windows().first?["frame"] as? [Double])
    XCTAssertEqual(frame[0] + frame[2], 1440 - 24, accuracy: 0.5)
    XCTAssertEqual(frame[1] + frame[3], 870 - 24, accuracy: 0.5)
    XCTAssertEqual(windows().first?["level"] as? Int, WidgetWindow.desktopLevel.rawValue)
    controller.show("unknown", lines: StatusFormatDocument.parse("x").lines())
    XCTAssertEqual(windows().count, 1)
    controller.apply(
      widgets: [:], statusBarReservesSpace: true, statusBarMonitor: .all, screenCapture: .show)
    XCTAssertEqual(windows().count, 0)
    XCTAssertTrue(reported.isEmpty, "a widget starts visible; nothing occluded it")
  }
}
