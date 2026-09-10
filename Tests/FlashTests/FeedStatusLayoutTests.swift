import AppKit
import XCTest

@testable import flash

final class FeedStatusLayoutTests: XCTestCase {
  private let articleURL = "https://news.example/article"

  private var feed: String {
    "#[pill]N#[nopill] FEED #[cyc,link=https://news.example/archive,shrink]"
      + String(repeating: "Long article title ", count: 12)
      + "#[noshrink,nolink] (news.example) #[link=\(articleURL)]↗#[nolink,nocyc]"
  }

  func testLongTitleFoldsBeforeNotchAndPreservesSourceAndOutboundArrow() throws {
    let notch = CGRect(x: 400, y: 0, width: 100, height: 26)
    let surface = render(feed + "#[align=right]CPU 10%", notch: notch)
    let arrow = try arrowFrame(surface)
    XCTAssertLessThanOrEqual(arrow.maxX, notch.minX - OverlayPanel.statusBarNotchMargin)
    assertFoldedTitleAndSuffix(surface)
    XCTAssertTrue(surface.layout.text.hasSuffix("CPU 10%"))
  }

  func testLongTitleStopsBeforeActualAbsoluteCentreAndLeavesArrowClickable() throws {
    let surface = render(feed + "#[align=absolute-centre]CENTER#[align=right]CPU 10%")
    let centre = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "CENTER" })
    XCTAssertLessThanOrEqual(try arrowFrame(surface).maxX, surface.runFrames[centre].minX)
    assertFoldedTitleAndSuffix(surface)
    XCTAssertTrue(surface.layout.text.hasSuffix("CPU 10%"))
  }

  func testOrdinaryCentreAlsoReservesRoomBeforeNativeAlignment() throws {
    let surface = render(feed + "#[align=centre]CENTER#[align=right]CPU 10%")
    let centre = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "CENTER" })
    XCTAssertLessThanOrEqual(try arrowFrame(surface).maxX, surface.runFrames[centre].minX)
    assertFoldedTitleAndSuffix(surface)
  }

  private func arrowFrame(_ surface: NativeStatusBarSurface) throws -> CGRect {
    let arrow = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.text == "↗" })
    let frame = surface.runFrames[arrow]
    let link = try XCTUnwrap(
      surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
        .links.first { $0.url.absoluteString == articleURL })
    XCTAssertEqual(link.rect, frame)
    return frame
  }

  private func assertFoldedTitleAndSuffix(_ surface: NativeStatusBarSurface) {
    let text = surface.visibleRuns.map(\.segment.text).joined()
    XCTAssertTrue(text.contains("… (news.example) ↗"), text)
    XCTAssertTrue(text.contains("FEED "))
    XCTAssertTrue(
      surface.visibleRuns.filter { $0.segment.text.contains("…") }.allSatisfy {
        $0.segment.shrink && $0.segment.link == "https://news.example/archive"
      })
  }

  private func render(_ source: String, notch: CGRect? = nil) -> NativeStatusBarSurface {
    let surface = NativeStatusBarSurface()
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 26)
    surface.render(
      document: StatusFormatDocument.parse(source), barFrame: frame,
      screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 900), scale: 2, notch: notch,
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      labels: .init(normal: "N", insert: "INSERT", command: "COMMAND"),
      palette: OverlayPanel.normalPalette, modeStyle: .normal)
    return surface
  }
}
