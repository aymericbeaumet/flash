import FlashCore
import XCTest

@testable import flash

final class LatencyProbeTests: XCTestCase {
  func testAProbeArmedInsideAnInteractionDatesFromItsInput() {
    Trace.begin(.hotkey, triggeredAt: 12.5) {
      let probe = LatencyProbe.arm(.flashlightOpen, at: 13)
      XCTAssertEqual(probe.origin, .hotkey)
      XCTAssertEqual(probe.trace, Trace.current)
      XCTAssertEqual(probe.startedAt, 12.5)
      XCTAssertEqual(probe.elapsedMs(at: 12.75), 250, accuracy: 0.001)
    }
  }

  func testAProbeArmedOutsideAnInteractionDatesFromItsArming() {
    let probe = LatencyProbe.arm(.configReload, at: 40)
    XCTAssertNil(probe.origin)
    XCTAssertNil(probe.trace)
    XCTAssertEqual(probe.startedAt, 40)
    XCTAssertEqual(probe.elapsedMs(at: 39), 0, "never negative")

    // A later turn of an interaction keeps its id for the log, not its input.
    var captured: Trace.ID?
    Trace.begin(.key, triggeredAt: 1) { captured = Trace.current }
    Trace.run(in: captured) {
      let later = LatencyProbe.arm(.popupShow, at: 50)
      XCTAssertEqual(later.trace, captured)
      XCTAssertNil(later.origin)
      XCTAssertEqual(later.startedAt, 50)
    }
  }

  /// `Scripts/log-summary.py` aggregates every `[latency] <flow>` line by its
  /// leading `ms=`; the stage fields follow in the order given.
  func testTheLogLineFormat() {
    var probe = LatencyProbe.arm(.configReload, at: 10)
    XCTAssertEqual(
      probe.line(
        endedAt: 10.0423, fields: [("reason", "watch"), ("parse_ms", "30.1"), ("apply_ms", "12.2")]),
      "[latency] config_reload ms=42.3 origin=- reason=watch parse_ms=30.1 apply_ms=12.2")
    Trace.begin(.cli, triggeredAt: 20) { probe = LatencyProbe.arm(.popupShow, at: 21) }
    XCTAssertEqual(
      probe.line(endedAt: 20.5, fields: [("state", "cold")]),
      "[latency] popup_show ms=500.0 origin=cli state=cold")
    XCTAssertEqual(
      LatencyProbe.arm(.launchReady, at: 1).line(endedAt: 1.25),
      "[latency] launch_ready ms=250.0 origin=-")
  }

  /// Every field stays one `name=value` token, whatever a caller passes.
  func testAFieldValueNeverBreaksTheLine() {
    let probe = LatencyProbe.arm(.flashlightOpen, at: 0)
    XCTAssertEqual(
      probe.line(endedAt: 0.001, fields: [("reason", "all sources\tsettled"), ("scope", "")]),
      "[latency] flashlight_open ms=1.0 origin=- reason=all_sources_settled scope=-")
  }

  func testOnlyThePerKeyFlowLogsAtTrace() {
    for flow in LatencyProbe.Flow.allCases {
      XCTAssertEqual(flow.level, flow == .flashlightKey ? .trace : .info, flow.rawValue)
    }
  }

  func testStagesAreMillisecondFieldsInTheOrderTheyRan() {
    var stages = LatencyStages()
    stages.add("config", since: 1, until: 1.0305)
    stages.add("plugins", since: 2, until: 2.001)
    XCTAssertEqual(stages.measure("apply") { 7 }, 7)
    XCTAssertEqual(stages.fields.map(\.0), ["config_ms", "plugins_ms", "apply_ms"])
    XCTAssertEqual(stages.fields[0].1, "30.5")
    XCTAssertEqual(stages.fields[1].1, "1.0")
    stages.add("early", since: 3, until: 2)
    XCTAssertEqual(stages.fields.last?.1, "0.0", "never negative")
  }

  /// The line reaches the log at the flow's level, inside its interaction.
  func testFinishLogsTheLineAtTheFlowsLevel() {
    var lines: [(FlashLog.Level, String)] = []
    let sink = FlashLog.addSink { record in
      guard record.message.hasPrefix("[latency] ") else { return }
      lines.append((record.level, record.message))
    }
    defer { FlashLog.removeSink(sink) }
    LatencyProbe.arm(.configReload, at: 5).finish(endedAt: 5.01, fields: [("reason", "command")])
    LatencyProbe.arm(.flashlightKey, at: 5).finish(endedAt: 5.002, fields: [("pool", "12")])
    XCTAssertEqual(
      lines.map(\.1),
      [
        "[latency] config_reload ms=10.0 origin=- reason=command",
        "[latency] flashlight_key ms=2.0 origin=- pool=12",
      ])
    XCTAssertEqual(lines.map(\.0), [.info, .trace])
  }

  /// Every evaluation of the flashlight list is one `flashlight_key` line
  /// naming the list it built, dated from the key when it ran in its turn.
  func testEachFlashlightEvaluationLogsOneKeyLine() {
    var lines: [String] = []
    let sink = FlashLog.addSink { record in
      guard record.message.hasPrefix("[latency] flashlight_key ") else { return }
      lines.append(record.message)
    }
    defer { FlashLog.removeSink(sink) }
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    defer { delegate.overlay.orderOut(nil) }
    // The catalogs already landed: typing evaluates at once.
    delegate.finder.publishInitialSnapshot()

    delegate.refreshCommandLine(text: "flashlight ")
    delegate.refreshCommandLine(text: "flashlight de")
    delegate.refreshCommandLine(text: "flashlight =1+1")
    Trace.begin(.key, triggeredAt: LatencyProbe.now) {
      delegate.refreshCommandLine(text: "flashlight !")
    }
    let paths = ["empty", "ranked", "evaluator", "bangs"]
    XCTAssertEqual(lines.count, paths.count, "\(lines)")
    for (line, path) in zip(lines, paths) {
      XCTAssertTrue(
        line.contains(" origin=\(path == "bangs" ? "key" : "-") path=\(path) pool="), line)
      XCTAssertTrue(line.contains(" eval_ms="), line)
    }
    XCTAssertTrue(lines.dropFirst().first?.contains(" filter_ms=") ?? false, "\(lines)")
    XCTAssertTrue(lines.dropFirst().first?.contains(" score_ms=") ?? false, "\(lines)")

    // A `menu choose` list is not the flashlight's.
    lines.removeAll()
    delegate.finder.menu = MenuSession(candidates: MenuChoice.candidates(["main", "dev"])) { _ in }
    delegate.refreshCommandLine(text: "flashlight de")
    XCTAssertEqual(lines, [])
  }

  func testTheProcessStartPrecedesNow() throws {
    let started = try XCTUnwrap(LatencyProbe.processStartUptime())
    XCTAssertLessThan(started, ProcessInfo.processInfo.systemUptime)
  }
}
