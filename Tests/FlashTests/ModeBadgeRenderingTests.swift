import AppKit
import XCTest

@testable import flash

final class ModeBadgeRenderingTests: XCTestCase {
  func testOldStatusPublicationsCannotChangeLiveModeLabelOrPaletteOnEitherScreen() throws {
    let panel = OverlayPanel()
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = CGRect(x: -1200, y: 0, width: 1200, height: 800)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [
        (scale: 2, frame: primary, visibleFrame: primary, notch: nil),
        (scale: 1, frame: secondary, visibleFrame: secondary, notch: nil),
      ], unionFrame: primary.union(secondary), mainFrame: primary, mainScale: 2,
      mainVisibleFrame: primary, nativeStatusBarFallbackHeight: 26)
    let staleModel = FlashStatusBarTemplateEngine.render(
      template: .init(template: "#[pill]#{flash.mode}#[nopill] OLD #[pill]OLD#[nopill]"),
      context: .init(modeLabel: "OLD"))

    for labels in [
      Config.Mode.Labels(normal: "READY", insert: " TYPE ", command: "COMMAND"),
      .init(normal: "MODE", insert: "MODE", command: "PROMPT"),
    ] {
      panel.modeLabels = labels
      for (text, style, palette) in [
        (labels.normal, OverlayModeBadgeStyle.normal, OverlayPanel.normalPalette),
        (labels.insert, .insert, OverlayPanel.insertPalette),
        (labels.command, .command, OverlayPanel.commandPaletteValue),
        (labels.terminal, .command, OverlayPanel.commandPaletteValue),
        (labels.normal, .normal, OverlayPanel.normalPalette),
      ] {
        panel.modeBadgeText = text
        panel.modeBadgeStyle = style
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {
          panel.setStatusBarModel(staleModel)
          panel.configureModeBadge(panelFrame: snapshot.unionFrame, screenSnapshot: snapshot)
          XCTAssertEqual(panel.secondaryStatusBars.count, 1)
          for surface in [panel.primaryStatusBarSurface] + panel.secondaryStatusBars {
            let modeIndex = try XCTUnwrap(surface.visibleRuns.firstIndex { $0.segment.isModeLabel })
            let layers = surface.runLayers[modeIndex]
            let attributed = try XCTUnwrap(layers.text.string as? NSAttributedString)
            XCTAssertEqual(attributed.string, label)
            XCTAssertEqual(layers.pill.colors as? [CGColor], [palette.bottomCG, palette.topCG])
            XCTAssertEqual(layers.pill.borderWidth, style == .normal ? 1 : 0)
            XCTAssertEqual(
              layers.pill.borderColor,
              style == .normal ? OverlayPanel.statusModeNormalBorderCG : palette.borderCG)
            let foreground = try XCTUnwrap(
              attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(foreground.cgColor, palette.foregroundCG)
            XCTAssertNil(layers.text.animationKeys())
            XCTAssertNil(layers.outgoing.animationKeys())
            let literals = zip(surface.visibleRuns, surface.runLayers).filter {
              !$0.0.segment.isModeLabel && !$0.0.segment.text.allSatisfy(\.isWhitespace)
            }
            XCTAssertEqual(
              literals.map { ($0.1.text.string as? NSAttributedString)?.string }, [" OLD ", "OLD"])
            surface.setHoverHighlight(surface.runFrames[modeIndex])
            XCTAssertEqual((layers.text.string as? NSAttributedString)?.string, label)
            XCTAssertEqual(layers.pill.colors as? [CGColor], [palette.bottomCG, palette.topCG])
            surface.setHoverHighlight(nil)
          }
        }
      }
    }
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.modeBadgeVisible)
  }
}
