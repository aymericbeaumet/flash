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
      left: "",
      right: "#{plugin:ready_count}/#{plugin:error_count}",
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

  func testCommandPromptFontSizeIsLargeEnoughForCenteredInput() {
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 14), 14)
    XCTAssertEqual(OverlayPanel.commandPromptFontSize(statusBarFontSize: 13), 14)
  }

  func testCommandPromptFrameIsCenteredInVisibleScreen() {
    let frame = OverlayPanel.commandPromptFrame(
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      panelFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      prompt: ":open firefox",
      fontSize: 14)

    XCTAssertEqual(frame.width, 440)
    XCTAssertEqual(frame.height, 38)
    XCTAssertEqual(frame.midX, 864)
    XCTAssertEqual(frame.midY, 539.5)
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

  func testPersistentStatusBarUsesNativeMenuFriendlyWindowLevel() {
    XCTAssertEqual(
      OverlayPanel.windowLevelForOverlayContent(
        inputMode: .normal,
        commandPromptVisible: false,
        candidateFinderResultsVisible: false,
        transientContentVisible: false).rawValue,
      OverlayPanel.persistentStatusWindowLevel.rawValue)
  }

  func testTransientSurfacesUseElevatedOverlayWindowLevel() {
    XCTAssertEqual(
      OverlayPanel.windowLevelForOverlayContent(
        inputMode: .commandLine,
        commandPromptVisible: true,
        candidateFinderResultsVisible: false,
        transientContentVisible: false).rawValue,
      OverlayPanel.transientOverlayWindowLevel.rawValue)
    XCTAssertEqual(
      OverlayPanel.windowLevelForOverlayContent(
        inputMode: .modal,
        commandPromptVisible: false,
        candidateFinderResultsVisible: false,
        transientContentVisible: true).rawValue,
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
    let config = ConfigLoader.parse(
      """
      [statusbar]
      left = "#{mode}"
      right = "#{script:~/bin/agent-status.sh}#[fg=colour245] · #{script:~/bin/battery-status.sh}#[fg=colour245] · #{date}"
      """)

    let text = FlashStatusBarTemplateEngine.render(
      template: config.statusBar.template,
      context: FlashStatusBarContext(now: now, calendar: calendar),
      dynamicValues: statusBarCommandValues(
        template: config.statusBar.template,
        agent: "#[fg=colour178]Cdx#[fg=colour245] 90%↻3h",
        battery: "#[range=user|bat-prefs fg=colour178]82%#[norange]")).rightText

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
