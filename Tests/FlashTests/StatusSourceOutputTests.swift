import XCTest

@testable import flash

/// Named sources that run scripts written for another bar: SwiftBar/xbar,
/// i3blocks and waybar print more than the bar's text, and only the text is
/// kept.
final class StatusSourceOutputTests: XCTestCase {
  func testXbarKeepsTheHeaderLinesWithoutTheirParameters() {
    let script = """
      CPU 12% | color=red font=Menlo
      MEM 40%|sfimage=memorychip
      ---
      Top processes | bash=/usr/bin/top terminal=true
      Refresh | refresh=true
      """
    XCTAssertEqual(FlashStatusBarSourceOutput.xbar.extract(script), "CPU 12%\nMEM 40%")
    XCTAssertEqual(FlashStatusBarSourceOutput.xbar.extract("Only a title"), "Only a title")
    XCTAssertEqual(
      FlashStatusBarSourceOutput.xbar.extract("| color=red\n---\nmenu"), "",
      "a header with no text keeps the last good value")
  }

  func testI3blocksKeepsTheFullText() {
    XCTAssertEqual(
      FlashStatusBarSourceOutput.i3blocks.extract("BAT 87%\n87%\n#00FF00\n"), "BAT 87%")
  }

  func testWaybarReadsTheLastJSONTextWithoutMarkup() {
    let output = """
      {"text": "old"}
      {"text": "<span color='red'>5 &amp; 6</span>", "class": "warning", "tooltip": "t"}
      """
    XCTAssertEqual(FlashStatusBarSourceOutput.waybar.extract(output), "5 & 6")
    XCTAssertEqual(FlashStatusBarSourceOutput.waybar.extract("not json"), "")
    XCTAssertEqual(
      FlashStatusBarSourceOutput.text.extract("a\nb"), "a\nb", "the default is unchanged")
  }

  func testTheOutputKeyNamesAFormatAndNeedsACommand() {
    let config = ConfigLoader.parse(
      """
      [statusbar.sources.cpu]
      command = ["./cpu.5s.sh"]
      output = "xbar"
      cycle_interval = 10

      [statusbar.sources.bad]
      command = ["./x.sh"]
      output = "polybar"

      [statusbar.sources.pushed]
      output = "xbar"
      """)
    XCTAssertEqual(config.statusBar.sources["cpu"]?.output, .xbar)
    XCTAssertNil(config.statusBar.sources["bad"])
    XCTAssertNil(config.statusBar.sources["pushed"])
    let messages = config.loadingDiagnostics.map(\.message)
    XCTAssertTrue(
      messages.contains {
        $0.contains("statusbar.sources.bad.output must be one of \"text\", \"xbar\"")
      }, "\(messages)")
    XCTAssertTrue(
      messages.contains { $0.contains("statusbar.sources.pushed.output needs a command") },
      "\(messages)")
  }

  // MARK: status refresh

  func testExpeditingMakesAnIdleJobDueAndARunningOneRunAgainAfterIt() {
    var schedule = StatusJobSchedule()
    XCTAssertTrue(schedule.begin(token: 1, now: 0, interval: 60))
    schedule.expedite(now: 5)
    XCTAssertTrue(schedule.complete(1))
    XCTAssertEqual(schedule.dueAt, 5, "the run in flight is followed at once by another")
    XCTAssertTrue(schedule.begin(token: 2, now: 5, interval: 60))
    XCTAssertTrue(schedule.complete(2))
    XCTAssertEqual(schedule.dueAt, 65)
    schedule.expedite(now: 10)
    XCTAssertEqual(schedule.dueAt, 10, "an idle job is due now")
  }

  func testARefreshNeedsADeclaredShownSourceWithACommand() {
    let command = FlashStatusBarSourceDefinition(command: ["/bin/x"])
    XCTAssertNil(StatusRefresh.refusal(source: "x", definition: command, shown: true))
    XCTAssertEqual(
      StatusRefresh.refusal(source: "x", definition: nil, shown: true),
      "no status source named x; declare [statusbar.sources.x]")
    XCTAssertEqual(
      StatusRefresh.refusal(
        source: "x", definition: FlashStatusBarSourceDefinition(command: []), shown: true),
      "x has no command; status set changes it")
    XCTAssertEqual(
      StatusRefresh.refusal(source: "x", definition: command, shown: false),
      "x is not shown: no bar or widget reads #{flash.source.x}")
  }
}
