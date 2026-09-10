import AppKit
import XCTest

@testable import flash

final class StatusBarTests: XCTestCase {
  private func renderStatusBar(
    _ panel: OverlayPanel,
    width: CGFloat = 1_440,
    notch: CGRect? = nil
  ) {
    let screenFrame = CGRect(x: 0, y: 0, width: width, height: 900)
    let visibleFrame = CGRect(x: 0, y: 0, width: width, height: 875)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [(scale: 2, frame: screenFrame, visibleFrame: visibleFrame, notch: notch)],
      unionFrame: screenFrame,
      mainFrame: screenFrame,
      mainScale: 2,
      mainVisibleFrame: visibleFrame,
      nativeStatusBarFallbackHeight: 25)
    panel.configureModeBadge(panelFrame: screenFrame, screenSnapshot: snapshot)
  }

  func testStatusBarFontSizeIsConstant() {
    XCTAssertEqual(OverlayPanel.statusBarFontSize(overlayFontSize: 12), 13)
    XCTAssertEqual(OverlayPanel.statusBarFontSize(overlayFontSize: 10), 13)
    XCTAssertEqual(OverlayPanel.statusBarFontSize(overlayFontSize: 24), 13)
  }

  func testModeIndicatorUsesStatusBarFontSize() {
    XCTAssertEqual(OverlayPanel.modeIndicatorFontSize(statusBarFontSize: 13), 13)
  }

  func testStatusBarHeightUsesExactPerScreenReservedBand() {
    let height = OverlayPanel.statusBarHeight(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)

    XCTAssertEqual(height, 38)
  }

  func testStatusBarHeightFallsBackToSystemThicknessWhenNativeBandIsAbsent() {
    let height = OverlayPanel.statusBarHeight(
      screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)

    XCTAssertEqual(height, 22)
  }

  func testStatusBarHeightUsesMeasuredNativeMenuHeightWhenFoldedBandIsAbsent() {
    let height = OverlayPanel.statusBarHeight(
      screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      fontSize: 13,
      fallbackNativeStatusBarHeight: 30)

    XCTAssertEqual(height, 30)
  }

  func testStatusBarHeightUsesLargerNativeBandWhenBothMeasurementsExist() {
    let height = OverlayPanel.statusBarHeight(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1093),
      fontSize: 13,
      fallbackNativeStatusBarHeight: 30)

    XCTAssertEqual(height, 30)
  }

  func testStatusBarFrameUsesExactPerScreenNativeStatusBarHeight() {
    let frame = OverlayPanel.statusBarFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      panelFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      fontSize: 13)

    XCTAssertEqual(
      frame.height,
      OverlayPanel.nativeStatusBarHeight(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)))
    XCTAssertEqual(frame.maxY, 1117)
  }

  func testSegmentsCaptureLinkMarkers() {
    let segs = FlashStatusBarRenderer.segments(
      from: "#[link=https://example.com]Open#[nolink] x")
    XCTAssertEqual(segs.count, 2)
    XCTAssertEqual(segs[0].text, "Open")
    XCTAssertEqual(segs[0].link, "https://example.com")
    XCTAssertEqual(segs[1].text, " x")
    XCTAssertNil(segs[1].link)
  }

  func testLinkMarkersAreStrippedFromRenderedText() {
    // The markers must never render as literal glyphs.
    let attributed = FlashStatusBarRenderer.attributedStatusString(
      from: "#[link=https://x]Hi#[nolink]",
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium))
    XCTAssertEqual(attributed.string, "Hi")
  }

  func testLinkRunsMeasureOnlyLinkedTextOffsetPastPrefix() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let (runs, total) = FlashStatusBarRenderer.linkRuns(
      from: "ab#[link=https://x]CD#[nolink]", font: font)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].url, "https://x")
    XCTAssertGreaterThan(runs[0].xOffset, 0)  // shifted right past "ab"
    XCTAssertGreaterThan(runs[0].width, 0)
    XCTAssertGreaterThan(total, runs[0].width)  // total includes the prefix
  }

  func testSegmentsCaptureNamedPopupMarkersWithoutAffectingLinks() {
    let segs = FlashStatusBarRenderer.segments(
      from: "#[popup=quota]#[link=https://example.com]Quota#[nolink]#[nopopup] x")

    XCTAssertEqual(segs.count, 2)
    XCTAssertEqual(segs[0].text, "Quota")
    XCTAssertEqual(segs[0].popup, "quota")
    XCTAssertEqual(segs[0].link, "https://example.com")
    XCTAssertEqual(segs[1].text, " x")
    XCTAssertNil(segs[1].popup)
    XCTAssertNil(segs[1].link)
  }

  func testPopupWrappedModePillKeepsItsHoverName() {
    XCTAssertEqual(
      FlashStatusBarRenderer.segments(
        from: "#[popup=mode-help]#[pill]NORMAL#[nopill]#[nopopup] · rest"
      )
      .first(where: \.pill)?.popup,
      "mode-help")
    XCTAssertNil(
      FlashStatusBarRenderer.segments(
        from: "#[pill]NORMAL#[nopill] #[popup=rest]rest#[nopopup]"
      )
      .first(where: \.pill)?.popup)
  }

  func testPopupRunsMergeAdjacentStyledSegmentsAndIgnoreUnknownDefinitions() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let (runs, total) = FlashStatusBarRenderer.popupRuns(
      from: "ab#[popup=quota]#[fg=colour178]CD#[bold]EF#[nopopup]gh#[popup=missing]ij#[nopopup]",
      font: font,
      popupTexts: ["quota": "#[fg=colour178,bold]Claude#[default]\n5-hour 75% remaining"])

    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].name, "quota")
    XCTAssertEqual(runs[0].content, "#[fg=colour178,bold]Claude#[default]\n5-hour 75% remaining")
    XCTAssertGreaterThan(runs[0].xOffset, 0)
    XCTAssertGreaterThan(runs[0].width, 0)
    XCTAssertGreaterThan(total, runs[0].xOffset + runs[0].width)
  }

  func testInlinePopupContentTravelsWithDynamicVisibleText() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let raw =
      "a#[popup=inline:%23%5Bfg%3Dcolour178%2Cbold%5DPreview%23%5Bdefault%5D%20body]#[link=https://example.com]Story#[nolink]#[nopopup]z"

    let rendered = FlashStatusBarRenderer.attributedStatusString(from: raw, font: font)
    let (popupRuns, total) = FlashStatusBarRenderer.popupRuns(
      from: raw,
      font: font,
      popupTexts: [:])
    let (linkRuns, _) = FlashStatusBarRenderer.linkRuns(from: raw, font: font)

    XCTAssertEqual(rendered.string, "aStoryz")
    XCTAssertEqual(popupRuns.count, 1)
    XCTAssertTrue(popupRuns[0].name.hasPrefix("inline-"))
    XCTAssertEqual(
      popupRuns[0].name,
      FlashStatusBarRenderer.popupRuns(from: raw, font: font, popupTexts: [:]).runs.first?.name)
    XCTAssertEqual(
      popupRuns[0].content,
      "#[fg=colour178,bold]Preview#[default] body")
    XCTAssertGreaterThan(popupRuns[0].xOffset, 0)
    XCTAssertGreaterThan(total, popupRuns[0].xOffset + popupRuns[0].width)
    XCTAssertEqual(linkRuns.count, 1)
    XCTAssertEqual(linkRuns[0].url, "https://example.com")
  }

  func testInlinePopupContentOverridesNamedTemplateOnlyForItsSpan() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let raw =
      "#[popup=inline:current%20preview]one#[nopopup] "
      + "#[popup=story]two#[nopopup]"

    let (runs, _) = FlashStatusBarRenderer.popupRuns(
      from: raw,
      font: font,
      popupTexts: ["story": "configured details"])

    XCTAssertEqual(runs.map(\.content), ["current preview", "configured details"])
  }

  func testMalformedAndOversizedInlinePopupBodiesArePassive() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let malformed = FlashStatusBarRenderer.popupRuns(
      from: "#[popup=inline:%ZZ]visible#[nopopup]",
      font: font,
      popupTexts: [:])
    let oversizedBody = String(repeating: "a", count: 16_385)
    let oversized = FlashStatusBarRenderer.popupRuns(
      from: "#[popup=inline:\(oversizedBody)]visible#[nopopup]",
      font: font,
      popupTexts: [:])

    XCTAssertTrue(malformed.runs.isEmpty)
    XCTAssertTrue(oversized.runs.isEmpty)
    XCTAssertEqual(
      FlashStatusBarRenderer.attributedStatusString(
        from: "#[popup=inline:%ZZ]visible#[nopopup]",
        font: font
      ).string,
      "visible")
  }

  func testPopupLayoutKeepsExactPaddingOnEveryEdge() {
    let layout = OverlayPanel.statusBarPopupLayout(
      textSize: CGSize(width: 137.25, height: 48.5),
      padding: 10,
      borderWidth: 1)

    XCTAssertEqual(layout.popupSize, CGSize(width: 159.25, height: 70.5))
    XCTAssertEqual(layout.labelFrame, CGRect(x: 11, y: 11, width: 137.25, height: 48.5))
    XCTAssertEqual(layout.labelFrame.minX - 1, 10)
    XCTAssertEqual(layout.labelFrame.minY - 1, 10)
    XCTAssertEqual(layout.popupSize.width - layout.labelFrame.maxX - 1, 10)
    XCTAssertEqual(layout.popupSize.height - layout.labelFrame.maxY - 1, 10)
  }

  func testPopupFrameIsCenteredBelowPointerAndClampedToVisibleScreen() {
    let centred = OverlayPanel.statusBarPopupFrame(
      pointer: CGPoint(x: 500, y: 700),
      popupSize: CGSize(width: 200, height: 100),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
      offset: 8)
    XCTAssertEqual(centred, CGRect(x: 400, y: 592, width: 200, height: 100))

    let clamped = OverlayPanel.statusBarPopupFrame(
      pointer: CGPoint(x: -1_190, y: 900),
      popupSize: CGSize(width: 1_400, height: 100),
      visibleFrame: CGRect(x: -1_200, y: 0, width: 1_200, height: 800),
      offset: 8)
    XCTAssertEqual(clamped, CGRect(x: -1_200, y: 700, width: 1_200, height: 100))
  }

  func testPopupRectsHonorRightAlignmentAndPanelCoordinates() {
    let panel = OverlayPanel()
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let regions = panel.statusPopupRects(
      raw: "x#[popup=quota]YY#[nopopup]",
      popupTexts: ["quota": "details"],
      font: font,
      labelFrame: CGRect(x: 600, y: 4, width: 300, height: 20),
      alignment: .right,
      barFrame: CGRect(x: 20, y: 760, width: 960, height: 40),
      panelFrame: CGRect(x: -1_000, y: -200, width: 2_000, height: 1_000))

    XCTAssertEqual(regions.count, 1)
    XCTAssertEqual(regions[0].name, "quota")
    XCTAssertEqual(regions[0].content, "details")
    XCTAssertEqual(regions[0].rect.maxX, -80, accuracy: 0.001)
    XCTAssertEqual(regions[0].rect.minY, 560, accuracy: 0.001)
    XCTAssertEqual(regions[0].rect.height, 40, accuracy: 0.001)
  }

  func testStatusBarHintRegionsIncludePopupOnlySegmentsAndPreferClicksOnOverlap() {
    let hoverRect = CGRect(x: 10, y: 760, width: 30, height: 24)
    let clickRect = CGRect(x: 60, y: 760, width: 40, height: 24)
    let url = URL(string: "https://example.com")!

    let regions = OverlayPanel.statusBarHintRegions(
      links: [(rect: clickRect, url: url)],
      popups: [
        StatusBarPopupRegion(rect: hoverRect, name: "memory", content: "Memory details"),
        StatusBarPopupRegion(rect: clickRect, name: "article", content: "Article preview"),
      ])

    XCTAssertEqual(regions.count, 2)
    XCTAssertEqual(regions[0], StatusBarHintRegion(rect: hoverRect, action: .hover("memory")))
    XCTAssertEqual(regions[1], StatusBarHintRegion(rect: clickRect, action: .click(url)))
  }

  func testAnimatedSpansRenderHiddenInBaseAndFullInEffectRuns() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let raw = "ac #[breathing]82%#[nobreathing] rest"
    // The base render keeps the glyphs (identical measurement) but paints
    // the animated span at foreground alpha 0.
    let base = FlashStatusBarRenderer.attributedStatusStringHidingAnimatedSpans(
      from: raw, font: font)
    XCTAssertEqual(base.string, "ac 82% rest")
    let full = FlashStatusBarRenderer.attributedStatusString(from: raw, font: font)
    XCTAssertEqual(base.size().width, full.size().width, accuracy: 0.001)
    let spanColor =
      base.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
    XCTAssertEqual(spanColor?.alphaComponent ?? -1, 0, accuracy: 0.001)
    let staticColor =
      base.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertEqual(staticColor?.alphaComponent ?? -1, 1, accuracy: 0.001)

    // The effect runs carry the same span at full colour, measured at the
    // right offset, with the right flags.
    let (runs, _) = FlashStatusBarRenderer.effectRuns(from: raw, font: font)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].text.string, "82%")
    XCTAssertTrue(runs[0].breathing)
    XCTAssertFalse(runs[0].blink)
    let prefixWidth = FlashStatusBarRenderer.attributedStatusString(
      from: "ac ", font: font
    ).size().width
    XCTAssertEqual(runs[0].xOffset, prefixWidth, accuracy: 0.001)
    let runColor =
      runs[0].text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertEqual(runColor?.alphaComponent ?? -1, 1, accuracy: 0.001)

    // A static string produces no runs and an untouched base.
    XCTAssertTrue(FlashStatusBarRenderer.effectRuns(from: "plain", font: font).runs.isEmpty)
  }

  func testEffectOpacityAnimationSamplesTheCurveOracle() {
    let layer = CALayer()
    let breathing = FlashStatusBarRenderer.effectOpacityAnimation(
      blink: false, breathing: true, anchoredTo: layer)
    XCTAssertEqual(breathing.duration, 10, accuracy: 0.001)
    XCTAssertEqual(breathing.repeatCount, .infinity)
    let values = breathing.values as? [CGFloat] ?? []
    XCTAssertFalse(values.isEmpty)
    // The keyframes are samples of effectAlphaMultiplier — the pure curve
    // stays the single oracle. Check the extremes the curve tests pin.
    XCTAssertEqual(values.min() ?? -1, 0.76, accuracy: 0.01)
    XCTAssertEqual(values.max() ?? -1, 1.0, accuracy: 0.01)
    // Anchored to the period grid of the shared clock.
    XCTAssertEqual(
      breathing.beginTime.truncatingRemainder(dividingBy: 10), 0, accuracy: 0.001)

    let blink = FlashStatusBarRenderer.effectOpacityAnimation(
      blink: true, breathing: false, anchoredTo: layer)
    XCTAssertEqual(blink.duration, 1, accuracy: 0.001)
    XCTAssertEqual(blink.values as? [Double] ?? [], [1.0, 0.15])
    XCTAssertEqual(blink.calculationMode, .discrete)
  }

  func testParsesMonitorScope() {
    XCTAssertEqual(ConfigLoader.parse("").statusBar.monitor, .all)
    XCTAssertEqual(
      ConfigLoader.parse(
        """
        [statusbar]
        monitor = "primary"
        """
      ).statusBar.monitor, .primary)
    // Invalid value is diagnosed and left at the default.
    let bad = ConfigLoader.parse(
      """
      [statusbar]
      monitor = "left"
      """)
    XCTAssertEqual(bad.statusBar.monitor, .all)
    XCTAssertTrue(bad.loadingDiagnostics.contains { $0.message.contains("statusbar.monitor") })
  }

  func testParsesNamedPopupTemplatesAndPopupStyle() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      popup_fg = "#ECEFF4"
      popup_bg = "#2E3440"
      popup_border = "#4C566A"
      popup_border_size = 2
      popup_corner_radius = 9
      popup_padding = 10
      popup_max_width = 420
      popup_offset = 7

      [statusbar.popup]
      quota = '''#[fg=#EBCB8B,bold]Claude#[default]
      #{flash.source.quota}'''

      [statusbar.sources.quota]
      command = ["/tmp/quota.sh", "--details=claude"]
      """)

    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
    XCTAssertEqual(c.statusBar.popupStyle.foreground, "#ECEFF4")
    XCTAssertEqual(c.statusBar.popupStyle.background, "#2E3440")
    XCTAssertEqual(c.statusBar.popupStyle.borderColor, "#4C566A")
    XCTAssertEqual(c.statusBar.popupStyle.borderWidth, 2)
    XCTAssertEqual(c.statusBar.popupStyle.cornerRadius, 9)
    XCTAssertEqual(c.statusBar.popupStyle.padding, 10)
    XCTAssertEqual(c.statusBar.popupStyle.maxWidth, 420)
    XCTAssertEqual(c.statusBar.popupStyle.offset, 7)
    let popup = c.statusBar.popups["quota"]
    XCTAssertEqual(
      popup?.template,
      "#[fg=#EBCB8B,bold]Claude#[default]\n#{flash.source.quota}")
    XCTAssertTrue(popup?.program.dependencies.values.contains("flash.source.quota") == true)
  }

  func testInvalidPopupStyleIsDiagnosedAndKeepsDefaults() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      popup_fg = "colour178"
      popup_border_size = -1
      popup_max_width = 20
      """)

    XCTAssertEqual(c.statusBar.popupStyle, Config.StatusBar.PopupStyle())
    XCTAssertEqual(c.loadingDiagnostics.count, 3)
    XCTAssertTrue(c.loadingDiagnostics.allSatisfy { $0.message.contains("statusbar.popup_") })
  }

  func testPopupTemplateRenderingPreservesNewlinesAndDynamicValues() {
    let model = FlashStatusBarTemplateEngine.render(
      template: Config.StatusBar.defaultTemplate,
      popupTemplates: [
        "quota": FlashStatusBarTemplate(
          template: "#[fg=colour178]Claude#[default]\n#{flash.source.quota}")
      ],
      context: FlashStatusBarContext(),
      dynamicValues: ["quota": "5-hour 75% remaining\n7-day 70% remaining"])
    XCTAssertEqual(
      model.popupDocuments["quota"]?.map(\.text).joined(),
      "Claude\n5-hour 75% remaining\n7-day 70% remaining")
    XCTAssertEqual(
      model.popupDocuments["quota"]?.first(where: { !$0.text.isEmpty })?.foreground, .palette(178))
  }

  func testPopupTemplateRenderingTrimsOnlyBoundaryNewlines() {
    let model = FlashStatusBarTemplateEngine.render(
      template: Config.StatusBar.defaultTemplate,
      popupTemplates: [
        "details": FlashStatusBarTemplate(template: "\n\nFirst line\n\nLast line\n")
      ],
      context: FlashStatusBarContext())
    XCTAssertEqual(model.popupDocuments["details"]?.map(\.text).joined(), "First line\n\nLast line")
  }

  func testDynamicPopupValueChangesTheModelWhileVisibleTextStaysFixed() {
    let template = FlashStatusBarTemplate(template: "#[align=right,popup=metrics]SYS#[nopopup]")
    let popups = ["metrics": FlashStatusBarTemplate(template: "#{flash.source.metrics}")]
    let first = FlashStatusBarTemplateEngine.render(
      template: template, popupTemplates: popups,
      context: FlashStatusBarContext(), dynamicValues: ["metrics": "CPU 12%\nMEM 34%"])
    let second = FlashStatusBarTemplateEngine.render(
      template: template, popupTemplates: popups,
      context: FlashStatusBarContext(), dynamicValues: ["metrics": "CPU 56%\nMEM 78%"])
    XCTAssertEqual(first.rightDocument, second.rightDocument)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(second.popupDocuments["metrics"]?.map(\.text).joined(), "CPU 56%\nMEM 78%")
  }

  func testVisiblePopupRefreshesContentInPlaceAtTheLatestPointer() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [(scale: 2, frame: screenFrame, visibleFrame: visibleFrame, notch: nil)],
      unionFrame: screenFrame,
      mainFrame: screenFrame,
      mainScale: 2,
      mainVisibleFrame: visibleFrame,
      nativeStatusBarFallbackHeight: 25)
    let panel = OverlayPanel()
    let firstPointer = CGPoint(
      x: visibleFrame.midX - 80,
      y: visibleFrame.midY - 20)
    let secondPointer = CGPoint(
      x: visibleFrame.midX + 80,
      y: visibleFrame.midY + 20)
    let popup = panel.statusPopupController
    defer { panel.hideStatusBarPopup() }

    panel.refreshStatusBarPopup(
      popups: [
        StatusBarPopupRegion(
          rect: screenFrame,
          name: "metrics",
          content: "CPU 12%\nMEM 34%")
      ],
      at: firstPointer,
      screenSnapshot: snapshot)
    let firstFrame = popup.frame

    panel.refreshStatusBarPopup(
      popups: [
        StatusBarPopupRegion(
          rect: screenFrame,
          name: "metrics",
          content: "CPU 56%\nMEM 78%")
      ],
      at: secondPointer,
      screenSnapshot: snapshot)

    XCTAssertTrue(panel.statusPopupController === popup, "a refresh must reuse the visible surface")
    XCTAssertTrue(popup.isVisible)
    XCTAssertEqual(panel.activeStatusBarPopupName, "metrics")
    XCTAssertEqual(panel.activeStatusBarPopupContent, "CPU 56%\nMEM 78%")
    XCTAssertEqual(
      popup.content,
      "CPU 56%\nMEM 78%")
    XCTAssertEqual(popup.frame.size, firstFrame.size)
    XCTAssertEqual(
      popup.frame.midX - firstFrame.midX,
      secondPointer.x - firstPointer.x,
      accuracy: 0.001)
    XCTAssertEqual(
      popup.frame.midY - firstFrame.midY,
      secondPointer.y - firstPointer.y,
      accuracy: 0.001)

    let padding = CGFloat(panel.statusBarPopupStyle.padding)
    let border = CGFloat(panel.statusBarPopupStyle.borderWidth)
    let label = popup.terminalView.frame
    XCTAssertEqual(label.minX - border, padding, accuracy: 0.001)
    XCTAssertEqual(label.minY - border, padding, accuracy: 0.001)
    XCTAssertEqual(popup.frame.width - label.maxX - border, padding, accuracy: 0.001)
    XCTAssertEqual(popup.frame.height - label.maxY - border, padding, accuracy: 0.001)

    let anchor = StatusBarPopupRegion(
      rect: CGRect(x: secondPointer.x - 5, y: secondPointer.y - 5, width: 10, height: 10),
      name: "metrics", content: "CPU 56%\nMEM 78%")
    panel.refreshStatusBarPopup(popups: [anchor], at: secondPointer, screenSnapshot: snapshot)
    let insidePopup = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
    XCTAssertFalse(anchor.rect.contains(insidePopup))
    for _ in 0..<2 {
      panel.refreshStatusBarPopup(popups: [anchor], at: insidePopup, screenSnapshot: snapshot)
      XCTAssertFalse(popup.isVisible, "the popup body must not retain or revive the preview")
      XCTAssertNil(panel.activeStatusBarPopupName)
    }
  }

  func testParsesNamedCyclingSources() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{flash.source.news} #{flash.source.other}"
      [statusbar.sources.news]
      command = ["/bin/sh", "~/hn.sh"]
      cycle_interval = 60
      [statusbar.sources.other]
      command = ["/bin/sh", "~/x.sh", "--flag"]
      cycle_interval = 90
      """)
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
    XCTAssertEqual(c.statusBar.sources["news"]?.cycleIntervalSeconds, 60)
    XCTAssertEqual(c.statusBar.sources["other"]?.cycleIntervalSeconds, 90)
    XCTAssertEqual(c.statusBar.sources["other"]?.command, ["/bin/sh", "~/x.sh", "--flag"])
    XCTAssertEqual(c.statusBar.template.sourceNames, ["news", "other"])
  }

  func testParsesStatusBarInterval() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      interval = 30
      """)
    XCTAssertEqual(c.statusBar.refreshIntervalSeconds, 30)
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)

    // tmux's `status-interval 0` convention: polling off entirely.
    let off = ConfigLoader.parse(
      """
      [statusbar]
      interval = 0
      """)
    XCTAssertEqual(off.statusBar.refreshIntervalSeconds, 0)

    let invalid = ConfigLoader.parse(
      """
      [statusbar]
      interval = -3
      """)
    XCTAssertEqual(invalid.statusBar.refreshIntervalSeconds, 5)
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("statusbar.interval") })
  }

  func testParsesPerSourceRefreshIntervals() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{flash.source.quota} #{flash.source.clock} #{flash.source.news}"
      [statusbar.sources.quota]
      command = ["/bin/sh", "~/bin/quota.sh", "--claude"]
      interval = 30
      [statusbar.sources.clock]
      command = ["/bin/sh", "-lc", "date"]
      interval = 10
      [statusbar.sources.news]
      command = ["/bin/sh", "~/bin/hn.sh"]
      interval = 300
      cycle_interval = 45
      """)
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
    XCTAssertEqual(
      c.statusBar.sources["quota"],
      FlashStatusBarSourceDefinition(
        command: ["/bin/sh", "~/bin/quota.sh", "--claude"], intervalSeconds: 30))
    XCTAssertEqual(
      c.statusBar.sources["clock"],
      FlashStatusBarSourceDefinition(
        command: ["/bin/sh", "-lc", "date"], intervalSeconds: 10))
    XCTAssertEqual(
      c.statusBar.sources["news"],
      FlashStatusBarSourceDefinition(
        command: ["/bin/sh", "~/bin/hn.sh"], intervalSeconds: 300, cycleIntervalSeconds: 45))
  }

  func testInvalidPerSourceRefreshIntervalDiagnoses() {
    for option in ["interval = -1", "interval = \"abc\"", "cycle_interval = 0"] {
      let c = ConfigLoader.parse(
        """
        [statusbar.sources.bad]
        command = ["/bin/sh", "~/bin/x.sh"]
        \(option)
        """)
      XCTAssertTrue(
        c.loadingDiagnostics.contains { $0.message.contains("statusbar.sources.bad.") },
        "expected a diagnostic for \(option)")
      XCTAssertNil(c.statusBar.sources["bad"])
    }
  }

  func testSourceRefreshIntervalsResolveAtConfigurationLoad() {
    for (global, override, expected) in [(5, nil, 5), (5, 30, 30), (0, nil, 0), (0, 30, 30)] {
      let c = ConfigLoader.parse(
        """
        [statusbar]
        interval = \(global)
        [statusbar.sources.clock]
        command = ["date"]
        \(override.map { "interval = \($0)" } ?? "")
        """)
      XCTAssertTrue(c.loadingDiagnostics.isEmpty)
      XCTAssertEqual(c.statusBar.sources["clock"]?.intervalSeconds, Double(expected))
      XCTAssertNil(c.statusBar.sources["clock"]?.cycleIntervalSeconds)
    }
  }

  func testCycleRefreshKeepsVisibleLineAcrossReorderingUntilItsDeadline() {
    var cycle = FlashStatusBarCycleState(
      lines: ["one", "two", "three"], periodSeconds: 10, now: 100)

    cycle.refresh(lines: ["new", "one", "two", "three"], periodSeconds: 10, now: 104)
    XCTAssertEqual(cycle.visibleLine, "one")
    XCTAssertEqual(cycle.nextRotationAt, 110)
    XCTAssertFalse(cycle.advanceIfDue(now: 109.999))

    XCTAssertTrue(cycle.advanceIfDue(now: 110))
    XCTAssertEqual(cycle.visibleLine, "two")
    XCTAssertEqual(cycle.nextRotationAt, 120)
  }

  func testCycleRefreshKeepsRemovedLineStaleUntilScheduledRotation() {
    var cycle = FlashStatusBarCycleState(
      lines: ["one", "two"], periodSeconds: 10, now: 100)

    cycle.refresh(lines: ["new", "other"], periodSeconds: 10, now: 105)
    XCTAssertEqual(cycle.visibleLine, "one")
    XCTAssertTrue(cycle.needsRotationTimer)

    XCTAssertTrue(cycle.advanceIfDue(now: 110))
    XCTAssertEqual(cycle.visibleLine, "new")
  }

  func testOverdueCycleTickPreservesOriginalCadenceWithoutDrift() {
    var cycle = FlashStatusBarCycleState(
      lines: ["one", "two", "three"], periodSeconds: 10, now: 100)

    XCTAssertTrue(cycle.advanceIfDue(now: 112))
    XCTAssertEqual(cycle.visibleLine, "two")
    XCTAssertEqual(cycle.nextRotationAt, 120)

    XCTAssertTrue(cycle.advanceIfDue(now: 121))
    XCTAssertEqual(cycle.visibleLine, "three")
    XCTAssertEqual(cycle.nextRotationAt, 130)

    XCTAssertFalse(cycle.advanceIfDue(now: 151))
    XCTAssertEqual(cycle.visibleLine, "three")
    XCTAssertEqual(cycle.nextRotationAt, 160)
  }

  func testCyclesAdvanceIndependentlyFromTheirOwnDeadlines() {
    var fast = FlashStatusBarCycleState(
      lines: ["fast 1", "fast 2"], periodSeconds: 5, now: 100)
    var slow = FlashStatusBarCycleState(
      lines: ["slow 1", "slow 2"], periodSeconds: 30, now: 100)

    XCTAssertTrue(fast.advanceIfDue(now: 105))
    XCTAssertFalse(slow.advanceIfDue(now: 105))
    XCTAssertEqual(fast.visibleLine, "fast 2")
    XCTAssertEqual(slow.visibleLine, "slow 1")
    XCTAssertEqual(fast.nextRotationAt, 110)
    XCTAssertEqual(slow.nextRotationAt, 130)
  }

  func testFullPaletteHexAndNamedColorsParse() {
    let segments = FlashStatusBarRenderer.segments(
      from: "#[fg=colour31]a#[fg=#5E81AC]b#[fg=green]c#[fg=default]d#[bg=nonsense]e")
    XCTAssertEqual(segments[0].foreground, .palette(31))
    XCTAssertEqual(segments[1].foreground, .rgb(0x5E81AC))
    XCTAssertEqual(segments[2].foreground, .palette(2))
    XCTAssertEqual(segments[3].foreground, .defaultForeground)
    // An unknown bg word stays default-background (no phantom grey fill).
    XCTAssertEqual(segments.last?.text, "de")
    XCTAssertEqual(segments.last?.background, .defaultBackground)
  }

  func testStyleSegmentParserHonoursItalicsUnderlineDimReverseBackground() {
    let segments = FlashStatusBarRenderer.segments(
      from: "#[fg=colour178,bg=colour0,bold,italics,underscore]Hi"
        + "#[reverse]Lo#[noreverse,nounderscore,noitalics,nobold]Done")
    XCTAssertEqual(segments.count, 3)
    let hi = segments[0]
    XCTAssertEqual(hi.text, "Hi")
    XCTAssertEqual(hi.foreground, .colour178)
    XCTAssertEqual(hi.background, .colour0)
    XCTAssertTrue(hi.bold)
    XCTAssertTrue(hi.italics)
    XCTAssertTrue(hi.underline)
    XCTAssertFalse(hi.reverse)

    let lo = segments[1]
    XCTAssertEqual(lo.text, "Lo")
    XCTAssertTrue(lo.reverse)

    let done = segments[2]
    XCTAssertEqual(done.text, "Done")
    XCTAssertFalse(done.bold)
    XCTAssertFalse(done.italics)
    XCTAssertFalse(done.underline)
    XCTAssertFalse(done.reverse)
  }

  func testInsertModeButtonPaletteUsesBlueBackgroundLitFromTheTop() {
    XCTAssertEqual(
      OverlayPanel.insertPalette.topCG, OverlayPanel.lifted(OverlayPanel.nordFrost2, by: 0.12).cgColor)
    XCTAssertEqual(OverlayPanel.insertPalette.bottomCG, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(OverlayPanel.insertPalette.foregroundCG, OverlayPanel.nordPolarNight0CG)
  }

  func testCommandModeButtonPaletteUsesHighlightedBackgroundLitFromTheTop() {
    XCTAssertEqual(
      OverlayPanel.commandPaletteValue.topCG,
      OverlayPanel.lifted(OverlayPanel.nordAuroraPurple, by: 0.12).cgColor)
    XCTAssertEqual(OverlayPanel.commandPaletteValue.bottomCG, OverlayPanel.nordAuroraPurpleCG)
    XCTAssertEqual(OverlayPanel.commandPaletteValue.foregroundCG, OverlayPanel.nordPolarNight0CG)
  }

  func testCommandPromptFontSizeIsLargeEnoughForCenteredInput() {
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 14), 14)
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 13), 14)
  }

  func testCommandPromptFrameUsesGoldenRatioComplementWidthAndTopOffset() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1079)
    let statusBarFrame = OverlayPanel.statusBarFrame(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      panelFrame: screenFrame,
      fontSize: 13)
    let frame = OverlayPanel.commandPromptFrame(
      visibleFrame: visibleFrame,
      screenFrame: screenFrame,
      statusBarFrame: statusBarFrame,
      panelFrame: screenFrame,
      prompt: ":open firefox",
      fontSize: 14)
    let topBoundary = min(statusBarFrame.minY, visibleFrame.maxY)

    XCTAssertEqual(
      frame.width / screenFrame.width,
      OverlayPanel.commandPromptWidthFraction,
      accuracy: 0.001)
    XCTAssertEqual(frame.height, 38)
    XCTAssertEqual(frame.midX, 864, accuracy: 0.001)
    XCTAssertEqual(
      (topBoundary - frame.maxY) / visibleFrame.height,
      OverlayPanel.commandPromptTopOffsetFraction,
      accuracy: 0.001)
  }

  func testModePillWidthIsOwnedOnlyByConfiguredLabels() {
    let labels = Config.Mode.Labels(normal: "N", insert: "INSERT", command: "COMMAND")
    let configuredWidth = OverlayPanel.modeBadgeWidth(
      labels: labels,
      currentText: labels.normal,
      fontSize: 13)
    let transientWidth = OverlayPanel.modeBadgeWidth(
      labels: labels,
      currentText: "UNCONFIGURED TRANSIENT MODE TEXT",
      fontSize: 13)

    XCTAssertEqual(transientWidth, configuredWidth)
  }

  func testStatusBarUsesCurvedScreenEdgePadding() {
    XCTAssertEqual(OverlayPanel.statusBarEdgePadding, 13)
  }

  func testStatusBarReanchorsToUnionFrameOnScreenParameterChange() {
    // Repro for the status bar vanishing when an external monitor is
    // unplugged: the panel spans the union of all screens and the bar is
    // anchored inside it, but nothing re-laid-it-out on a display change, so
    // it was left stranded on the old (larger) union's coordinates. The
    // re-anchor must snap the panel back onto the current union frame.
    let panel = OverlayPanel()
    panel.modeLabels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    panel.updateModeBadge(text: "NORMAL", visible: true, captureInput: false, style: .normal)

    // Strand the panel on a stale, wrong frame (as if a monitor it spanned was
    // just removed). A small on-screen rect is never constrained away.
    panel.setFrame(CGRect(x: 0, y: 0, width: 10, height: 10), display: false)
    XCTAssertNotEqual(panel.frame, OverlayPanel.unionScreenFrame())

    panel.statusBarDidChangeScreenParameters()

    XCTAssertEqual(panel.frame, OverlayPanel.unionScreenFrame())
    XCTAssertTrue(panel.modeBadgeVisible)
  }

  func testCommandPromptLayerHasWindowSeparatingShadow() {
    let panel = OverlayPanel()

    XCTAssertFalse(panel.commandPromptLayer.masksToBounds)
    XCTAssertGreaterThan(panel.commandPromptLayer.shadowOpacity, 0)
    XCTAssertGreaterThan(panel.commandPromptLayer.shadowRadius, 0)
  }

  func testPersistentStatusBarIsPlainWindowBelowNativeMenuBar() {
    // The bar is an ordinary elevated window (`.floating`): above the focused
    // app's normal windows, but well below the native menu bar (app menus at
    // `.mainMenu`/24, extras at `.statusBar`/25) so the menu bar wins the
    // z-order and expands on top of Flash. Not jammed against the menu-bar band
    // at `.mainMenu - 1`, where it competed with the system menu bar for clicks.
    XCTAssertEqual(
      OverlayPanel.windowLevelForOverlayContent(
        inputMode: .normal,
        commandPromptVisible: false,
        candidateFinderResultsVisible: false,
        transientContentVisible: false
      ).rawValue,
      OverlayPanel.persistentStatusWindowLevel.rawValue)
    XCTAssertEqual(
      OverlayPanel.persistentStatusWindowLevel.rawValue,
      NSWindow.Level.floating.rawValue)
    XCTAssertGreaterThan(
      OverlayPanel.persistentStatusWindowLevel.rawValue,
      NSWindow.Level.normal.rawValue)
    XCTAssertLessThan(
      OverlayPanel.persistentStatusWindowLevel.rawValue,
      NSWindow.Level.mainMenu.rawValue)
  }

  func testTransientSurfacesUseElevatedOverlayWindowLevel() {
    XCTAssertEqual(
      OverlayPanel.windowLevelForOverlayContent(
        inputMode: .commandLine,
        commandPromptVisible: true,
        candidateFinderResultsVisible: false,
        transientContentVisible: false
      ).rawValue,
      OverlayPanel.transientOverlayWindowLevel.rawValue)
  }

  func testCandidateFinderResultsRenderBelowCenteredCommandPrompt() {
    let y = OverlayPanel.candidateFinderResultsY(
      commandPromptFrame: CGRect(x: 644, y: 520.5, width: 440, height: 38),
      height: 120,
      minimumY: 10)

    XCTAssertEqual(y, 394.5)
  }

  func testCandidateFinderResultsClampToVisibleArea() {
    let y = OverlayPanel.candidateFinderResultsY(
      commandPromptFrame: CGRect(x: 82, y: 80, width: 180, height: 38),
      height: 120,
      minimumY: 10)

    XCTAssertEqual(y, 10)
  }

  func testCandidateFinderMaxVisibleRowsNeverIntrudeIntoThePrompt() {
    // 520.5 prompt minY, 10 minimumY, 6 gap, 7 vertical padding × 2:
    // available = 520.5 - 6 - 10 - 14 = 490.5 → with 18pt rows + 2pt gaps
    // each extra row costs 20pt after the first: (490.5 + 2) / 20 = 24 rows.
    let rows = OverlayPanel.candidateFinderMaxVisibleRows(
      commandPromptFrame: CGRect(x: 644, y: 520.5, width: 440, height: 38),
      minimumY: 10,
      rowHeight: 18,
      lineSpacing: 2,
      verticalPadding: 7)
    XCTAssertEqual(rows, 24)

    // The clamped row count must produce a panel that fits between the
    // prompt and the bottom margin — the overlap this guards against.
    let height = CGFloat(rows) * 18 + CGFloat(rows - 1) * 2 + 7 * 2
    XCTAssertLessThanOrEqual(height, 520.5 - 6 - 10)

    // One more row would have overlapped.
    let tallerHeight = CGFloat(rows + 1) * 18 + CGFloat(rows) * 2 + 7 * 2
    XCTAssertGreaterThan(tallerHeight, 520.5 - 6 - 10)
  }

  func testCandidateFinderMaxVisibleRowsFloorsAtOneRow() {
    // A prompt hugging the screen bottom still shows the top match.
    let rows = OverlayPanel.candidateFinderMaxVisibleRows(
      commandPromptFrame: CGRect(x: 82, y: 12, width: 180, height: 38),
      minimumY: 10,
      rowHeight: 18,
      lineSpacing: 2,
      verticalPadding: 7)
    XCTAssertEqual(rows, 1)
  }

  func testCandidateFinderResultsWidthStartsAtCommandPromptWidth() {
    let width = OverlayPanel.candidateFinderResultsWidth(
      commandPromptWidth: 1_068,
      longestLineCharacterCount: 8,
      fontSize: 14,
      maximumWidth: 1_600)

    XCTAssertEqual(width, 1_068)
  }

  func testCandidateFinderResultsUseLargerTextAndRoomierRows() {
    XCTAssertEqual(OverlayPanel.candidateFinderFontSize(overlayFontSize: 11), 12)
    XCTAssertEqual(OverlayPanel.candidateFinderFontSize(overlayFontSize: 13), 14)
    XCTAssertEqual(OverlayPanel.candidateFinderHorizontalPadding, 8)
    XCTAssertEqual(OverlayPanel.candidateFinderVerticalPadding, 7)
    XCTAssertEqual(OverlayPanel.candidateFinderLineSpacing, 2)
  }

  func testCandidateFinderResultsWidthIsPinnedToPromptWidth() {
    // The panel must stay a fixed width — a long candidate title used to
    // widen the whole flashlight surface under the cursor, which reads
    // as a stutter even when the work is cheap. Long rows truncate
    // inside the panel instead.
    let short = OverlayPanel.candidateFinderResultsWidth(
      commandPromptWidth: 1_068,
      longestLineCharacterCount: 10,
      fontSize: 14,
      maximumWidth: 1_600)
    let long = OverlayPanel.candidateFinderResultsWidth(
      commandPromptWidth: 1_068,
      longestLineCharacterCount: 200,
      fontSize: 14,
      maximumWidth: 1_600)
    XCTAssertEqual(short, 1_068)
    XCTAssertEqual(long, 1_068)
    // The width is exactly the prompt's, regardless of content or the screen
    // cap: the prompt is already clamped to the visible region, and the two
    // stacked boxes must share an edge to read as one surface, so
    // `maximumWidth` no longer trims it.
    let wide = OverlayPanel.candidateFinderResultsWidth(
      commandPromptWidth: 2_000,
      longestLineCharacterCount: 200,
      fontSize: 14,
      maximumWidth: 1_600)
    XCTAssertEqual(wide, 2_000)
  }

  func testSystemStatusBarSpaceReservationRemovesMenuBarAutoHide() {
    let current: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
    let enabled = AppDelegate.systemStatusBarSpaceReservationPresentationOptions(
      current: current,
      enabled: true)
    let disabled = AppDelegate.systemStatusBarSpaceReservationPresentationOptions(
      current: enabled,
      enabled: false)

    XCTAssertFalse(enabled.contains(.autoHideMenuBar))
    XCTAssertTrue(enabled.contains(.autoHideDock))
    XCTAssertFalse(disabled.contains(.autoHideMenuBar))
    XCTAssertTrue(disabled.contains(.autoHideDock))
  }

  func testStatusBarLinkClickAcceptsStationaryAndSmallJitter() {
    // A release at (or within the slop of) the press point is a click.
    XCTAssertTrue(
      StatusBarClickView.isClick(
        from: CGPoint(x: 100, y: 12), to: CGPoint(x: 100, y: 12)))
    XCTAssertTrue(
      StatusBarClickView.isClick(
        from: CGPoint(x: 100, y: 12), to: CGPoint(x: 103, y: 14)))
  }

  func testStatusBarLinkClickRejectsDrag() {
    // A release dragged past the slop opens nothing.
    XCTAssertFalse(
      StatusBarClickView.isClick(
        from: CGPoint(x: 100, y: 12), to: CGPoint(x: 140, y: 12)))
    XCTAssertFalse(
      StatusBarClickView.isClick(
        from: CGPoint(x: 100, y: 12), to: CGPoint(x: 100, y: 30)))
  }

  func testCandidateFinderResultsKeepBestMatchOnTop() {
    let panel = OverlayPanel()
    panel.setCandidateFinderResults(
      items: [
        CandidateDisplayItem(title: "best", isSelected: true),
        CandidateDisplayItem(title: "second", isSelected: false),
        CandidateDisplayItem(title: "third", isSelected: false),
      ],
      emptyText: "none")

    XCTAssertEqual(panel.candidateFinderResultsMeasurementText, "> best\n  second\n  third")
  }

  func testCandidateFinderResultsRenderEverySuppliedSuggestion() {
    let panel = OverlayPanel()
    let items = (0..<10).map { index in
      CandidateDisplayItem(title: "item \(index)", isSelected: index == 0)
    }

    panel.setCandidateFinderResults(items: items, emptyText: "none")

    XCTAssertEqual(panel.candidateFinderResultsMeasurementText.split(separator: "\n").count, 10)
  }

  func testCandidateFinderResultsHeightHasNoTrailingRowGap() {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let rowHeight = OverlayPanel.candidateFinderResultRowHeight(font: font)

    XCTAssertEqual(
      OverlayPanel.candidateFinderResultsHeight(
        lineCount: 3,
        font: font,
        lineSpacing: OverlayPanel.candidateFinderLineSpacing),
      rowHeight * 3 + OverlayPanel.candidateFinderLineSpacing * 2)
  }

  func testCandidateFinderResultRowHeightFitsAppleEmojiFont() throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let emojiFont = try XCTUnwrap(CandidateEmojiSupport.emojiFont(forCandidateFontSize: 13))
    XCTAssertLessThan(emojiFont.pointSize, font.pointSize)

    let emojiHeight = ceil(emojiFont.ascender - emojiFont.descender + emojiFont.leading)

    XCTAssertGreaterThanOrEqual(
      OverlayPanel.candidateFinderResultRowHeight(font: font), emojiHeight)
  }

  func testCandidateFinderResultRowHeightStaysCompactForSmallerEmojiFont() throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let monoHeight = ceil(font.ascender - font.descender + font.leading)
    _ = try XCTUnwrap(CandidateEmojiSupport.emojiFont(forCandidateFontSize: 13))

    XCTAssertEqual(OverlayPanel.candidateFinderResultRowHeight(font: font), monoHeight)
  }

  func testCandidateFinderResultRowsUseAppleEmojiFontForRenderableGlyphs() {
    let line = OverlayPanel.candidateFinderResultAttributedLine(
      item: CandidateDisplayItem(
        title: "[emojis.glyphs] 🙏 person with folded hands",
        highlightedRanges: [18..<22],
        isSelected: true),
      marker: "> ",
      fontSize: 13)
    let ns = line.string as NSString
    let range = ns.range(of: "🙏")
    let font = try? XCTUnwrap(
      line.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)

    XCTAssertEqual(font?.familyName, "Apple Color Emoji")
  }

  func testCandidateFinderResultRowsDoNotUseEmojiFontForUnsupportedSymbols() {
    let line = OverlayPanel.candidateFinderResultAttributedLine(
      item: CandidateDisplayItem(
        title: "[emojis.glyphs] 🕲 no piracy",
        highlightedRanges: [],
        isSelected: false),
      marker: "  ",
      fontSize: 13)
    let ns = line.string as NSString
    let range = ns.range(of: "🕲")
    let font = try? XCTUnwrap(
      line.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)

    XCTAssertNotEqual(font?.familyName, "Apple Color Emoji")
  }

  func testRightStatusComposesTmuxStatusRightOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_781_334_480)
    let template = FlashStatusBarTemplate(
      template:
        "#[align=right]#{flash.source.agent} · #{flash.source.battery} · #{flash.date}")
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(now: now, calendar: calendar),
      dynamicValues: [
        "agent": "#[fg=colour178]Cdx#[default] 90%↻3h",
        "battery": "#[range=user|bat-prefs,fg=colour178]82%#[norange]",
      ])
    XCTAssertTrue(model.rightDocument.map(\.text).joined().hasPrefix("Cdx 90%↻3h · 82% · "))
    XCTAssertEqual(model.rightDocument.first(where: { $0.text == "82%" })?.range, "bat-prefs")
  }

  func testClickRangesBecomeActionableSegments() {
    // tmux's status-line mouse model, made real: the span names an action
    // (resolved via [statusbar.click]); the markers render zero glyphs.
    let segments = FlashStatusBarRenderer.segments(
      from: "#[range=user|bat-prefs fg=colour178]82%#[norange] rest")
    XCTAssertEqual(segments[0].text, "82%")
    XCTAssertEqual(segments[0].range, "bat-prefs")
    XCTAssertEqual(segments[0].foreground, .palette(178))
    XCTAssertEqual(segments[1].text, " rest")
    XCTAssertNil(segments[1].range)

    // The clickable run rides the URL plumbing as a sentinel scheme.
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let (runs, _) = FlashStatusBarRenderer.linkRuns(
      from: "#[range=user|bat-prefs]82%#[norange]", font: font)
    XCTAssertEqual(runs.count, 1)
    let url = URL(string: runs[0].url)
    XCTAssertEqual(url.flatMap(FlashStatusBarRenderer.rangeActionName(from:)), "bat-prefs")
  }

  func testStatusBarClickActionsParse() {
    let c = ConfigLoader.parse(
      """
      [statusbar.click]
      "bat-prefs" = "x-apple.systempreferences:com.apple.preference.battery"
      "quota" = ["flash", "help_show"]
      """)
    XCTAssertTrue(c.loadingDiagnostics.isEmpty, "\(c.loadingDiagnostics.map(\.message))")
    XCTAssertEqual(
      c.statusBar.clickActions["bat-prefs"],
      .url("x-apple.systempreferences:com.apple.preference.battery"))
    guard case .command = c.statusBar.clickActions["quota"] else {
      return XCTFail("expected a command action")
    }
    // Defaults ship the battery binding (the power plugin emits the span).
    XCTAssertEqual(
      ConfigLoader.parse("").statusBar.clickActions["bat-prefs"],
      .url("x-apple.systempreferences:com.apple.preference.battery"))

    let invalid = ConfigLoader.parse(
      """
      [statusbar.click]
      "x" = 5
      """)
    XCTAssertTrue(
      invalid.loadingDiagnostics.contains { $0.message.contains("statusbar.click.x") })
  }

  func testTmuxStatusSegmentsParseForegroundBoldAndClickRanges() {
    let segments = FlashStatusBarRenderer.segments(
      from: "#[fg=colour178 bold]Cdx#[fg=colour245 nobold] 80% "
        + "#[fg=colour196]12%↻1h#[fg=colour245] · "
        + "#[range=user|cal fg=colour178]Sat Jun 13 09:08#[norange]")

    XCTAssertEqual(
      segments,
      [
        FlashStatusTextSegment(text: "Cdx", foreground: .colour178, bold: true),
        FlashStatusTextSegment(text: " 80% ", foreground: .colour245, bold: false),
        FlashStatusTextSegment(text: "12%↻1h", foreground: .colour196, bold: false),
        FlashStatusTextSegment(text: " · ", foreground: .colour245, bold: false),
        FlashStatusTextSegment(
          text: "Sat Jun 13 09:08", foreground: .colour178, bold: false, range: "cal"),
      ])
  }

  func testTmuxStatusSegmentsLatchBreathingAndBlinkBetweenMarkers() {
    let segments = FlashStatusBarRenderer.segments(
      from: "#[fg=colour178]Cdx #[breathing]80%#[nobreathing] "
        + "#[blink]LOW#[noblink] tail")

    XCTAssertEqual(
      segments,
      [
        FlashStatusTextSegment(text: "Cdx ", foreground: .colour178),
        FlashStatusTextSegment(text: "80%", foreground: .colour178, breathing: true),
        FlashStatusTextSegment(text: " ", foreground: .colour178),
        FlashStatusTextSegment(text: "LOW", foreground: .colour178, blink: true),
        FlashStatusTextSegment(text: " tail", foreground: .colour178),
      ])
  }

  func testBreathingEffectAlphaRidesSubtleSinusoidBetween76And100Percent() {
    let breathing = FlashStatusTextSegment(text: "82%", foreground: .colour178, breathing: true)
    // 0.0 s — sine starts at 0, alpha lands at the midpoint of the
    // [0.76, 1.0] band: (0.76 + 1.0) / 2 = 0.88.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 0.0),
      0.88,
      accuracy: 0.001)
    // 2.5 s — quarter cycle in (period 10 s), sine peaks at 1, alpha
    // at 1.0 (full opacity, like the end of an inhale).
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 2.5),
      1.0,
      accuracy: 0.001)
    // 7.5 s — three-quarter cycle, sine bottoms at -1, alpha at the
    // dim trough (0.76).
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 7.5),
      0.76,
      accuracy: 0.001)
    // Two full cycles in (20 s) — phase wraps back to 0, alpha back to
    // the midpoint. Confirms the modulo-period math keeps the curve
    // stationary over time.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 20.0),
      0.88,
      accuracy: 0.001)
  }

  func testBreathingAlphaStaysWithinSubtleBandForEveryPhase() {
    let breathing = FlashStatusTextSegment(text: "82%", foreground: .colour178, breathing: true)
    // Sweep two full periods at 1/60 s granularity and assert every
    // sample stays inside the documented band — guards against future
    // changes to the curve that would widen the swing past "subtle".
    var sample: TimeInterval = 0
    while sample < 20.0 {
      let alpha = FlashStatusBarRenderer.effectAlphaMultiplier(
        segment: breathing, currentTime: sample)
      XCTAssertGreaterThanOrEqual(alpha, 0.76 - 0.0001)
      XCTAssertLessThanOrEqual(alpha, 1.0 + 0.0001)
      sample += 1.0 / 60.0
    }
  }

  func testBlinkEffectFlipsBetweenSolidAndDim() {
    let blink = FlashStatusTextSegment(text: "!", foreground: .colour196, blink: true)
    // 0.0 s — within the on-half of the 1 s square wave.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: blink, currentTime: 0.0),
      1.0,
      accuracy: 0.001)
    // 0.6 s — in the off-half; alpha dips to 0.15.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: blink, currentTime: 0.6),
      0.15,
      accuracy: 0.001)
  }

  func testStaticSegmentsReportAlphaUnchanged() {
    let plain = FlashStatusTextSegment(text: "·", foreground: .colour245)
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: plain, currentTime: 0.0),
      1.0,
      accuracy: 0.001)
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: plain, currentTime: 12_345.6),
      1.0,
      accuracy: 0.001)
  }

}
