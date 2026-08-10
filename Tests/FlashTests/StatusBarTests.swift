import AppKit
import XCTest

@testable import flash

final class StatusBarTests: XCTestCase {
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

  func testStatusLeftAndRightTextDoNotUseTmuxFramePipes() {
    XCTAssertEqual(OverlayPanel.statusLeftText(modeText: "NORMAL"), "NORMAL")
    XCTAssertEqual(
      OverlayPanel.statusRightDisplayText("#[fg=colour178]Sat Jun 13 09:08"),
      "#[fg=colour178]Sat Jun 13 09:08")
    XCTAssertEqual(OverlayPanel.statusRightDisplayText(""), "")
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

  func testStatusTextAnimatedDetectsEffectMarkersOnly() {
    XCTAssertFalse(OverlayPanel.statusTextAnimated("#[fg=colour178]82%"))
    XCTAssertTrue(OverlayPanel.statusTextAnimated("#[breathing]82%#[nobreathing]"))
    XCTAssertTrue(OverlayPanel.statusTextAnimated("#[blink]retry#[noblink]"))
    XCTAssertTrue(OverlayPanel.statusTextAnimated("#[breathe]x"))
  }

  func testEffectTickRefreshesAnimatedTextWithoutRecomputingStatusBarLayout() throws {
    let panel = OverlayPanel()
    panel.modeBadgeVisible = true
    panel.statusRightText = "#[breathing]82%#[nobreathing]"
    panel.statusRightLabel.frame = CGRect(x: 100, y: 4, width: 240, height: 17)
    let originalFrame = panel.statusRightLabel.frame
    let originalSublayers = panel.contentLayer.sublayers

    panel.refreshStatusBarEffects(currentTime: 2.5)
    let bright = try XCTUnwrap(panel.statusRightLabel.string as? NSAttributedString)
    let brightColor = try XCTUnwrap(
      bright.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

    panel.refreshStatusBarEffects(currentTime: 7.5)
    let dim = try XCTUnwrap(panel.statusRightLabel.string as? NSAttributedString)
    let dimColor = try XCTUnwrap(
      dim.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

    XCTAssertEqual(brightColor.alphaComponent, 1.0, accuracy: 0.001)
    XCTAssertEqual(dimColor.alphaComponent, 0.80, accuracy: 0.001)
    XCTAssertEqual(panel.statusRightLabel.frame, originalFrame)
    XCTAssertEqual(
      panel.contentLayer.sublayers?.map(ObjectIdentifier.init),
      originalSublayers?.map(ObjectIdentifier.init))
  }

  func testSplitLeftRegionKeepsModePillSeparateFromTrailingStyledRun() {
    // Plain `#{mode}` left bucket → all pill, no trailing run.
    let plain = OverlayPanel.splitLeftRegion("NORMAL")
    XCTAssertEqual(plain.pill, "NORMAL")
    XCTAssertEqual(plain.trailing, "")

    // `#{mode}` followed by styled content → the first `#[…]` marker is
    // the boundary; everything after it keeps its own styling instead of
    // leaking the bold mode-pill palette.
    let mixed = OverlayPanel.splitLeftRegion(
      "NORMAL#[fg=colour245] · #[fg=colour178]HN#[fg=colour245] story")
    XCTAssertEqual(mixed.pill, "NORMAL")
    XCTAssertEqual(mixed.trailing, "#[fg=colour245] · #[fg=colour178]HN#[fg=colour245] story")
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

  func testParsesCycleToken() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{cycle:~/hn.sh} #{cycle=90:~/x.sh --flag}"
      """)
    let vars = c.statusBar.template.variables
    guard
      case .cycle(_, let defaultPeriod)? =
        vars.first(where: { $0.token == "cycle:~/hn.sh" })?.source
    else { return XCTFail("expected a cycle variable") }
    XCTAssertEqual(defaultPeriod, 60)
    guard
      case .cycle(_, let customPeriod)? =
        vars.first(where: { $0.token == "cycle=90:~/x.sh --flag" })?.source
    else { return XCTFail("expected a cycle=90 variable") }
    XCTAssertEqual(customPeriod, 90)
    // Cycle runs a subprocess (a command section) and is also its own
    // cycleSections bucket.
    XCTAssertEqual(c.statusBar.template.commandSections.count, 2)
    XCTAssertEqual(c.statusBar.template.cycleSections.count, 2)
  }

  func testDefaultTemplateRendersModeAndRightSections() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let template = Config.StatusBar.defaultTemplate

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        activeAppName: "Safari",
        activeBundleIdentifier: "com.apple.Safari",
        modeLabel: "NORMAL",
        now: now,
        calendar: calendar))

    XCTAssertEqual(model.appText, "")
    XCTAssertEqual(model.modeText, "NORMAL")
    XCTAssertEqual(model.rightText, "#[fg=colour178]Thu May 28 20:26")
    XCTAssertFalse(model.rightText.contains("ip-status"))
    XCTAssertFalse(model.rightText.contains("range=user"))
  }

  func testStatusTemplateCanReadPluginState() {
    let template = FlashStatusBarTemplate(
      template: "#[align=right]#{plugin:ready_count}/#{plugin:error_count}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "ready",
          token: "plugin:ready_count",
          source: .plugin(.readyCount)),
        FlashStatusBarTemplateVariable(
          id: "errors",
          token: "plugin:error_count",
          source: .plugin(.errorCount)),
      ])

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        pluginStatuses: [
          pluginStatus(id: "ok", state: "ready", lastError: nil),
          pluginStatus(id: "bad", state: "failed", lastError: "boom"),
        ]))

    XCTAssertEqual(model.rightText, "1/1")
  }

  func testStatusTemplateCanReadPluginStatusSegment() {
    let template = FlashStatusBarTemplate(
      template: "#[align=right]#{plugin:system.battery}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "battery",
          token: "plugin:system.battery",
          source: .plugin(.statusSegment(pluginID: "system", name: "battery")))
      ])

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        pluginStatuses: [
          pluginStatus(
            id: "system",
            state: "ready",
            lastError: nil,
            statusSegments: [
              "battery": "#[range=user|bat-prefs fg=colour178]82%#[norange]"
            ])
        ]))

    XCTAssertEqual(model.rightText, "#[fg=colour178]82%")
  }

  func testMissingPluginStatusSegmentRendersEmpty() {
    let template = FlashStatusBarTemplate(
      template: "#[align=right]#{plugin:system.battery}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "battery",
          token: "plugin:system.battery",
          source: .plugin(.statusSegment(pluginID: "system", name: "battery")))
      ])

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        pluginStatuses: [
          pluginStatus(id: "system", state: "ready", lastError: nil)
        ]))

    XCTAssertEqual(model.rightText, "")
  }

  func testAlignMarkersRouteToLeftCentreRightBuckets() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]L#[align=centre]C#[align=right]R",
      variables: [])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext())
    XCTAssertEqual(model.modeText, "L")
    XCTAssertEqual(model.appText, "C")
    XCTAssertEqual(model.rightText, "R")
  }

  func testStatusTemplateIgnoresNewlinesWhenRendering() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]L\n#[align=centre]C\r\n#[align=right]R",
      variables: [])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext())
    XCTAssertEqual(model.modeText, "L")
    XCTAssertEqual(model.appText, "C")
    XCTAssertEqual(model.rightText, "R")
  }

  func testTmuxStatusVariablesRenderKnownHostValuesAndEmptyUnsupportedValues() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#H #{host_short} #{hostname} #{user} #{uid} #{pid} #{window_name}#S",
      variables: [])

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        hostName: "macbook.local",
        userName: "ab",
        userID: 501,
        processID: 4242))

    XCTAssertEqual(model.modeText, "macbook.local macbook macbook.local ab 501 4242 ")
  }

  func testAmericanCenterAliasMatchesBritishCentre() {
    let template = FlashStatusBarTemplate(
      template: "#[align=center]C",
      variables: [])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext())
    XCTAssertEqual(model.appText, "C")
  }

  func testStyleMarkersFlowIntoCurrentAlignmentBucket() {
    let template = FlashStatusBarTemplate(
      template: "#[align=right]#[fg=colour245]styled",
      variables: [])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext())
    XCTAssertEqual(model.rightText, "#[fg=colour245]styled")
    XCTAssertTrue(model.modeText.isEmpty)
  }

  func testDoubleHashEscapesLiteralPound() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]##count##: 42",
      variables: [])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext())
    XCTAssertEqual(model.modeText, "#count#: 42")
  }

  func testTokenTruncationHeadKeepsFirstNChars() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#{=4:mode}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode",
          token: "mode",
          source: .sdk(.modeLabel))
      ])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(modeLabel: "COMMAND"))
    XCTAssertEqual(model.modeText, "COMM")
  }

  func testTokenTruncationTailKeepsLastNChars() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#{=-4:mode}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode",
          token: "mode",
          source: .sdk(.modeLabel))
      ])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(modeLabel: "COMMAND"))
    XCTAssertEqual(model.modeText, "MAND")
  }

  func testTokenTruncationLeavesShortValueUntouched() {
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#{=10:mode}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode",
          token: "mode",
          source: .sdk(.modeLabel))
      ])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(modeLabel: "NORMAL"))
    XCTAssertEqual(model.modeText, "NORMAL")
  }

  func testTokenTruncationEllipsisGlyphCountsTowardBudget() {
    // `=4…` → 3 visible characters + the ellipsis glyph = 4 cells wide.
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.parseTokenTruncation("=4…:mode").truncation,
      .head(4, ellipsis: true))
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#{=4…:mode}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode", token: "mode", source: .sdk(.modeLabel))
      ])
    let model = FlashStatusBarTemplateEngine.render(
      template: template, context: FlashStatusBarContext(modeLabel: "COMMAND"))
    XCTAssertEqual(model.modeText, "COM…")
  }

  func testTokenTruncationAsciiDotsAreAcceptedAsEllipsis() {
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.parseTokenTruncation("=4...:mode").truncation,
      .head(4, ellipsis: true))
  }

  func testTokenTruncationLeavesShortValueWithoutEllipsis() {
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "NORMAL", truncation: .head(10, ellipsis: true)),
      "NORMAL")
  }

  func testTokenTruncationCountsVisibleCharsNotStyleMarkers() {
    // Markers pass through without counting; the kept run keeps its
    // formatting and the ellipsis inherits the still-open style.
    let styled = "#[fg=colour178]HN#[fg=colour245] #[italics]hello world#[noitalics]"
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(styled, truncation: .head(6, ellipsis: true)),
      "#[fg=colour178]HN#[fg=colour245] #[italics]he…")
    // A bare `#` (not `#[`) is an ordinary visible character.
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "C# rocks", truncation: .head(2, ellipsis: false)),
      "C#")
  }

  func testTokenTruncationTailKeepsTrailingVisibleWindowWithLeadingEllipsis() {
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "abcdef", truncation: .tail(4, ellipsis: true)),
      "…def")
  }

  func testTokenTruncationDropsWhitespaceAdjacentToEllipsis() {
    // When the trim lands on a space the glyph sits flush against the text —
    // no "foo …". `=5…` keeps 4 visible cells ("foo" + the dropped space),
    // and the trailing space is removed before the glyph is appended.
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "foo bar", truncation: .head(5, ellipsis: true)),
      "foo…")
    // Tail side: the leading space is dropped before the glyph is prepended.
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "bar foo", truncation: .tail(5, ellipsis: true)),
      "…foo")
    // Multiple adjacent spaces are all trimmed.
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.applyTruncation(
        "ab   cd", truncation: .head(6, ellipsis: true)),
      "ab…")
  }

  func testEllipsisTruncationAppliesToStyledScriptValueAtRender() {
    // A `#{=N…:script:…}` wrapper trims the resolved (styled) command
    // output to N visible cells, keeping markers and ellipsising the rest.
    let template = FlashStatusBarTemplate(
      template: "#[align=left]#{mode} · #{=8…:script:/tmp/hn.sh}",
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode", token: "mode", source: .sdk(.modeLabel)),
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.script:/tmp/hn.sh",
          token: "script:/tmp/hn.sh",
          source: .command(.script("/tmp/hn.sh"))),
      ])
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(modeLabel: "NORMAL"),
      dynamicValues: [
        "statusbar.template.script:/tmp/hn.sh":
          "#[fg=colour178]HN#[fg=colour245] hello world"
      ])
    // "HN hello" = 8 visible cells → "HN hell" (7) + "…", markers intact.
    XCTAssertEqual(model.modeText, "NORMAL · #[fg=colour178]HN#[fg=colour245] hell…")
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

  func testInsertModeButtonPaletteUsesBlueBackground() {
    XCTAssertEqual(OverlayPanel.insertPalette.topCG, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(OverlayPanel.insertPalette.bottomCG, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(OverlayPanel.insertPalette.foregroundCG, OverlayPanel.nordPolarNight0CG)
  }

  func testCommandModeButtonPaletteUsesHighlightedBackground() {
    XCTAssertEqual(OverlayPanel.commandPaletteValue.topCG, OverlayPanel.nordAuroraPurpleCG)
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

  func testStatusBarHidesActiveAppAndUsesConstantModeFont() {
    let panel = OverlayPanel()
    panel.modeLabels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    panel.setStatusBarModel(
      FlashStatusBarModel(
        appText: "",
        modeText: "NORMAL",
        rightText: "#[fg=colour178]Sat Jun 13 09:08"))
    panel.updateModeBadge(text: "NORMAL", visible: true, captureInput: false, style: .normal)

    XCTAssertTrue(panel.statusAppLabel.isHidden)
    XCTAssertEqual(panel.modeBadgeLabel.alignmentMode, .center)
    XCTAssertEqual(
      panel.modeBadgeLabel.fontSize,
      OverlayPanel.modeIndicatorFontSize(statusBarFontSize: 13))
    XCTAssertEqual(
      panel.statusRightLabel.fontSize,
      OverlayPanel.statusBarFontSize(overlayFontSize: 12))
  }

  func testStatusBarUsesCurvedScreenEdgePadding() {
    XCTAssertEqual(OverlayPanel.statusBarEdgePadding, 13)
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
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = 2026
    components.month = 6
    components.day = 13
    components.hour = 7
    components.minute = 8
    let now = components.date!
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "#[align=left]#{mode}#[align=right]#{script:~/bin/agent-status.sh}#[fg=colour245] · #{script:~/bin/battery-status.sh}#[fg=colour245] · #{date}"
      """)

    let text = FlashStatusBarTemplateEngine.render(
      template: config.statusBar.template,
      context: FlashStatusBarContext(now: now, calendar: calendar),
      dynamicValues: statusBarCommandValues(
        template: config.statusBar.template,
        agent: "#[fg=colour178]Cdx#[fg=colour245] 90%↻3h",
        battery: "#[range=user|bat-prefs fg=colour178]82%#[norange]")
    ).rightText

    XCTAssertEqual(
      text,
      "#[fg=colour178]Cdx#[fg=colour245] 90%↻3h#[fg=colour245] · "
        + "#[fg=colour178]82%#[fg=colour245] · "
        + "#[fg=colour178]Sat Jun 13 07:08")
  }

  func testClickRangeMarkersAreStrippedBeforeRendering() {
    XCTAssertEqual(
      FlashStatusBarRenderer.stripClickRanges(
        from: "#[range=user|bat-prefs fg=colour178]82%#[norange]"),
      "#[fg=colour178]82%")
  }

  func testTmuxStatusSegmentsParseForegroundAndBoldMarkersWithoutClickRanges() {
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
        FlashStatusTextSegment(text: "Sat Jun 13 09:08", foreground: .colour178, bold: false),
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

  func testBreathingEffectAlphaRidesSubtleSinusoidBetween80And100Percent() {
    let breathing = FlashStatusTextSegment(text: "82%", foreground: .colour178, breathing: true)
    // 0.0 s — sine starts at 0, alpha lands at the midpoint of the
    // [0.80, 1.0] band: (0.80 + 1.0) / 2 = 0.90.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 0.0),
      0.90,
      accuracy: 0.001)
    // 2.5 s — quarter cycle in (period 10 s), sine peaks at 1, alpha
    // at 1.0 (full opacity, like the end of an inhale).
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 2.5),
      1.0,
      accuracy: 0.001)
    // 7.5 s — three-quarter cycle, sine bottoms at -1, alpha at the
    // dim trough (0.80).
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 7.5),
      0.80,
      accuracy: 0.001)
    // Two full cycles in (20 s) — phase wraps back to 0, alpha back to
    // the midpoint. Confirms the modulo-period math keeps the curve
    // stationary over time.
    XCTAssertEqual(
      FlashStatusBarRenderer.effectAlphaMultiplier(segment: breathing, currentTime: 20.0),
      0.90,
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
      XCTAssertGreaterThanOrEqual(alpha, 0.80 - 0.0001)
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

  func testModelNeedsEffectsTickDetectsBreathingOrBlinkInAnyRegion() {
    XCTAssertFalse(
      FlashStatusBarController.modelNeedsEffectsTick(
        FlashStatusBarModel(appText: "Cdx 80%", modeText: "INSERT", rightText: "14:32")))

    XCTAssertTrue(
      FlashStatusBarController.modelNeedsEffectsTick(
        FlashStatusBarModel(
          appText: "",
          modeText: "INSERT",
          rightText: "#[breathing]82%#[nobreathing]")))

    XCTAssertTrue(
      FlashStatusBarController.modelNeedsEffectsTick(
        FlashStatusBarModel(
          appText: "#[blink]LOW#[noblink]",
          modeText: "INSERT",
          rightText: "")))
  }

  private func pluginStatus(
    id: String,
    state: String,
    lastError: String?,
    statusSegments: [String: String] = [:]
  ) -> PluginStatus {
    PluginStatus(
      id: id,
      name: id,
      version: "1.0.0",
      description: "",
      origin: "test",
      root: "/tmp/\(id)",
      state: state,
      pid: nil,
      uptimeMs: nil,
      heartbeatAgeMs: nil,
      sourceCount: 0,
      commandCount: 0,
      targetCount: 0,
      discoveryAgeMs: nil,
      restartCount: 0,
      lastError: lastError,
      lastLog: nil,
      cpuPercent: nil,
      memoryBytes: nil,
      onlyBundleIDs: [],
      onlyURLs: [],
      volatile: false,
      priority: 0,
      commands: [],
      statusSegments: statusSegments)
  }

  private func statusBarCommandValues(
    template: FlashStatusBarTemplate,
    agent: String,
    battery: String
  ) -> [String: String] {
    var values: [String: String] = [:]
    for section in template.commandSections {
      guard case .command(let command) = section.source else { continue }
      let argv = command.argv.joined(separator: " ")
      if argv.contains("agent-status.sh") {
        values[section.id] = agent
      } else if argv.contains("battery-status.sh") {
        values[section.id] = battery
      }
    }
    return values
  }
}
