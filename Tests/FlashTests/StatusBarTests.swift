import AppKit
import XCTest

@testable import flash

final class StatusBarTests: XCTestCase {
  func testStatusBarFontSizeIsLargerThanOverlayDefault() {
    XCTAssertEqual(OverlayPanel.statusBarFontSize(overlayFontSize: 12), 14)
    XCTAssertEqual(OverlayPanel.statusBarFontSize(overlayFontSize: 10), 13)
  }

  func testStatusBarFrameUsesMenuOrNotchBandHeight() {
    let frame = OverlayPanel.statusBarFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      panelFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      fontSize: 13)

    XCTAssertEqual(frame, CGRect(x: 0, y: 1079, width: 1728, height: 38))
  }

  func testStatusBarFrameFallsBackToReadableFontHeight() {
    let frame = OverlayPanel.statusBarFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      panelFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      fontSize: 13)

    XCTAssertEqual(frame, CGRect(x: 0, y: 777, width: 1000, height: 23))
  }

  func testStatusLeftAndRightTextDoNotUseTmuxFramePipes() {
    XCTAssertEqual(OverlayPanel.statusLeftText(modeText: "NORMAL"), "NORMAL")
    XCTAssertEqual(
      OverlayPanel.statusRightDisplayText("#[fg=colour178]Sat Jun 13 09:08"),
      "#[fg=colour178]Sat Jun 13 09:08")
    XCTAssertEqual(OverlayPanel.statusRightDisplayText(""), "")
  }

  func testDefaultTemplateRendersActiveAppModeAndRightSections() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    let model = FlashStatusBarTemplateEngine.render(
      template: .default,
      context: FlashStatusBarContext(
        activeAppName: "Safari",
        activeBundleIdentifier: "com.apple.Safari",
        modeLabel: "NORMAL",
        now: now,
        calendar: calendar),
      dynamicValues: [
        "agent": "#[fg=colour178]Cdx",
        "battery": "#[range=user|bat fg=colour178]82%#[norange]",
      ])

    XCTAssertEqual(model.appText, "Safari")
    XCTAssertEqual(model.modeText, "NORMAL")
    XCTAssertTrue(model.rightText.contains("#[fg=colour178]Cdx"))
    XCTAssertTrue(model.rightText.contains("#[fg=colour178]82%"))
    XCTAssertFalse(model.rightText.contains("range=user"))
  }

  func testStatusTemplateCanReadPluginState() {
    let template = FlashStatusBarTemplate(
      sections: [
        FlashStatusBarTemplateSection(
          id: "ready",
          placement: .trailing,
          source: .plugin(.readyCount)),
        FlashStatusBarTemplateSection(
          id: "errors",
          placement: .trailing,
          source: .plugin(.errorCount)),
      ],
      trailingSeparator: "/")

    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: FlashStatusBarContext(
        pluginSnapshots: [
          pluginSnapshot(id: "ok", state: "ready", lastError: nil),
          pluginSnapshot(id: "bad", state: "failed", lastError: "boom"),
        ]))

    XCTAssertEqual(model.rightText, "1/1")
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

  func testCommandPromptFontSizeIsSmallerThanStatusBar() {
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 14), 13)
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 13), 12)
  }

  func testCommandPromptFrameIsCenteredInVisibleScreen() {
    let frame = OverlayPanel.commandPromptFrame(
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      panelFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      prompt: ":open firefox",
      fontSize: 13)

    XCTAssertEqual(frame.width, 360)
    XCTAssertEqual(frame.height, 32)
    XCTAssertEqual(frame.midX, 864)
    XCTAssertEqual(frame.midY, 539.5)
  }

  func testStatusBarPlacesActiveAppAfterModeButton() {
    let panel = OverlayPanel()
    panel.modeLabels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    panel.setStatusBarModel(
      FlashStatusBarModel(
        appText: "Safari",
        modeText: "NORMAL",
        rightText: "#[fg=colour178]Sat Jun 13 09:08"))
    panel.updateModeBadge(text: "NORMAL", visible: true, captureInput: false, style: .normal)

    XCTAssertGreaterThan(panel.statusAppLabel.frame.minX, panel.modeBadgeButtonLayer.frame.maxX)
    XCTAssertEqual(panel.modeBadgeLabel.alignmentMode, .center)
  }

  func testStatusBarUsesCurvedScreenEdgePadding() {
    XCTAssertEqual(OverlayPanel.statusBarEdgePadding, 28)
  }

  func testStatusBarYieldsToNativeSystemBarAtTopEdge() {
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [(
        scale: 2,
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)
      )],
      unionFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      mainFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      mainScale: 2,
      mainVisibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079))

    XCTAssertTrue(
      OverlayPanel.statusBarShouldYieldToSystemMenu(
        point: CGPoint(x: 800, y: 1100),
        snapshot: snapshot,
        modeBadgeVisible: true,
        commandPromptVisible: false,
        candidateFinderResultsVisible: false,
        transientContentVisible: false))
    XCTAssertTrue(
      OverlayPanel.statusBarShouldYieldToSystemMenu(
        point: CGPoint(x: 800, y: 1100),
        snapshot: snapshot,
        modeBadgeVisible: true,
        commandPromptVisible: true,
        candidateFinderResultsVisible: false,
        transientContentVisible: false))
  }

  func testCandidateFinderResultsRenderBelowCenteredCommandPrompt() {
    let y = OverlayPanel.candidateFinderResultsY(
      commandPromptFrame: CGRect(x: 684, y: 523.5, width: 360, height: 32),
      height: 120,
      minimumY: 10)

    XCTAssertEqual(y, 397.5)
  }

  func testCandidateFinderResultsClampToVisibleArea() {
    let y = OverlayPanel.candidateFinderResultsY(
      commandPromptFrame: CGRect(x: 82, y: 80, width: 180, height: 38),
      height: 120,
      minimumY: 10)

    XCTAssertEqual(y, 10)
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

    let text = FlashStatusBarRenderer.rightStatus(
      agent: "#[fg=colour178]Cdx#[fg=colour245] 90%↻3h",
      battery: "#[range=user|bat-prefs fg=colour178]82%#[norange]",
      ip: "#[range=user|net-prefs fg=red]no internet#[norange]",
      now: now,
      calendar: calendar)

    XCTAssertEqual(
      text,
      "#[fg=colour178]Cdx#[fg=colour245] 90%↻3h#[fg=colour245] · "
        + "#[fg=colour178]82%#[fg=colour245] · "
        + "#[fg=red]no internet#[fg=colour245] · "
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

  private func pluginSnapshot(
    id: String,
    state: String,
    lastError: String?
  ) -> PluginStatusSnapshot {
    PluginStatusSnapshot(
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
      candidateCount: 0,
      snapshotAgeMs: nil,
      restartCount: 0,
      lastError: lastError,
      lastLog: nil,
      cpuPercent: nil,
      memoryBytes: nil,
      bundleIDs: [],
      volatile: false,
      priority: 0,
      commands: [])
  }
}
