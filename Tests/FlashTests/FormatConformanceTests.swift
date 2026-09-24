import Foundation
import XCTest

@testable import flash

final class FormatConformanceTests: XCTestCase {
  private struct Case: Decodable {
    var format: String
    var options: [String: String]?
    var expected: String
  }

  func testPinnedTmuxFormatCorpus() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("StatusFormatFixtures/tmux-3.7b.json")
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
    for item in cases {
      var context = StatusFormatContext()
      context.options = item.options ?? [:]
      context.timeZone = TimeZone(secondsFromGMT: 0)!
      let actual = StatusFormatProgram.compile(source: item.format).evaluate(
        context, expandTime: true
      ).text
      XCTAssertEqual(actual, item.expected, item.format)
    }
  }

  func testOnlyEvaluatedBranchesRequestJobs() {
    let program = StatusFormatProgram.compile(
      source: "#{?@visible,#(echo yes),#(echo no)} #{||:1,#(never)}")
    var context = StatusFormatContext()
    context.options = ["@visible": "1"]
    context.jobs = ["echo yes": "ready"]
    let result = program.evaluate(context)
    XCTAssertEqual(result.text, "ready 1")
    XCTAssertEqual(Set(result.jobs.map(\.command)), ["echo yes"])
    XCTAssertTrue(program.dependencies.containsJobs)
  }

  func testNamedFragmentRetainsItsDefinitionOrigin() {
    var context = StatusFormatContext()
    context.options = ["@fragment": "#[popup=inline:details]label#[nopopup]"]
    let result = StatusFormatProgram.compile(source: "#{E:@fragment}").evaluate(context)
    XCTAssertEqual(result.fragments.first?.span.origin.name, "option.@fragment")
  }

  func testLoopContextAndNeighbors() {
    var context = StatusFormatContext()
    context.scopes["W"] = [
      .init(values: ["window_name": "a"], options: ["@color": "red"], index: 1, name: "a"),
      .init(values: ["window_name": "b"], active: true, index: 2, name: "b"),
    ]
    let result = StatusFormatProgram.compile(
      source: "#{W:#{window_name},[#{window_name}:#{prev_@color}:#{loop_last}]}"
    ).evaluate(context)
    XCTAssertEqual(result.text, "a[b:red:1]")
  }

  func testCompilerReportsDecodedByteSpans() {
    let program = StatusFormatProgram.compile(
      source: "界 #{unclosed", origin: .init("popup.details"))
    XCTAssertEqual(program.diagnostics.first?.span.bytes, 4..<14)
    XCTAssertEqual(program.diagnostics.first?.span.origin.name, "popup.details")
  }

  func testEveryAliasResolvesThroughTheProvidedContext() {
    var context = StatusFormatContext()
    for (alias, key) in StatusFormatSyntax.aliases {
      context.values[key] = String(UnicodeScalar(alias))
    }
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#D#F#H#I#P#S#T#W#h").evaluate(context).text, "DFHIPSTWh")
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{window_name}:#{pane_title}:#{C:needle}:#{W:#W}")
        .evaluate().text, "::0:")
  }

  func testIterationFamiliesAndNativeSortFlagPrecedence() {
    var context = StatusFormatContext()
    let rows: [StatusFormatScope] = [
      .init(values: ["label": "b"], index: 0, name: "b", activity: 10),
      .init(values: ["label": "a"], active: true, index: 1, name: "a", activity: 20),
    ]
    for family in ["S", "W", "P", "L"] { context.scopes[family] = rows }
    XCTAssertEqual(
      StatusFormatProgram.compile(
        source:
          "#{S/n:#{label}}|#{L/tr:#{label}}|#{P/r:#{label},[#{label}]}|#{W/in:#{label},[#{label}]}"
      ).evaluate(context).text, "ab|ba|[a]b|b[a]")
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{S:#{label},#{loop_last};}").evaluate(context).text,
      "b,0;a,1;")
  }

  func testNameQueryFlagsAndPaneSearchUseExplicitContext() {
    var context = StatusFormatContext()
    context.scopes["S"] = [.init(values: [:], name: "alpha")]
    context.scopes["W"] = [.init(values: [:], name: "beta")]
    context.options["@x"] = "plain"
    context.paneLines = ["first   ", "an ERROR occurred  ", "last"]
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{N/ws:alpha}|#{N/s:alpha}|#{N/z:@x}").evaluate(context)
        .text, "0|1|plain")
    XCTAssertEqual(
      StatusFormatProgram.compile(
        source: "#{C:ERROR}|#{C/ri:^AN ERROR}|#{C:*cur*}|#{C:last }|#{C:absent}"
      ).evaluate(context).text, "2|2|2|0|0")
  }

  func testTimeModifiersUseTheTimestampAndPreservePrettyFlagAcrossChains() {
    var context = StatusFormatContext()
    context.now = Date(timeIntervalSince1970: 1_700_000_001)
    context.timeZone = TimeZone(secondsFromGMT: 0)!
    context.options["@time"] = "1700000000"
    context.environment["ENV_TIME"] = "1700000000"
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{t/f/%Y-%m-%d:@time}|#{t/p;t/f/%Y:@time}|#{t:ENV_TIME}")
        .evaluate(context).text, "2023-11-14|22:13|")
  }

  func testInlineIdentitySurvivesDataChangesAndDistinguishesFragmentInvocations() {
    let program = StatusFormatProgram.compile(source: "#{@before}#{E:@popup}#{E:@popup}")
    var context = StatusFormatContext()
    context.options = ["@before": "short", "@popup": "#[popup=inline:first]label#[nopopup]"]
    func names(_ context: StatusFormatContext) -> [String] {
      StatusFormatDocument.parse(program.evaluate(context)).runs.filter { !$0.text.isEmpty }
        .compactMap(\.popup)
    }
    let before = names(context)
    XCTAssertEqual(Set(before).count, 2)
    context.options["@before"] = String(repeating: "long ", count: 20)
    context.options["@popup"] = "#[popup=inline:second]label#[nopopup]"
    XCTAssertEqual(names(context), before)
  }

  func testOrdinaryValuesAreDataAndCachedJobOutputIsExpandedWithoutNestedJobs() {
    var context = StatusFormatContext()
    context.values["flash.plugin.demo.status"] = "#[fg=red]#{@value}#(nested)"
    context.options = ["@value": "expanded", "@command": "printf first"]
    context.jobs["#{@command}"] = "#{@value}#(nested)"
    let data = StatusFormatProgram.compile(source: "#{flash.plugin.demo.status}").evaluate(context)
    XCTAssertTrue(data.jobs.isEmpty)
    XCTAssertEqual(StatusFormatDocument.parse(data).runs.last?.text, "#{@value}#(nested)")
    let job = StatusFormatProgram.compile(source: "#(#{@command})").evaluate(context)
    XCTAssertEqual(job.text, "expanded")
    XCTAssertEqual(job.jobs.map(\.rawCommand), ["#{@command}"])
    XCTAssertEqual(job.jobs.map(\.command), ["printf first"])
    context.options["@command"] = "printf second"
    let changed = StatusFormatProgram.compile(source: "#(#{@command})").evaluate(context)
    XCTAssertEqual(changed.text, "expanded")
    XCTAssertEqual(changed.jobs.first?.command, "printf second")
  }

  func testExtremeNumericValuesAndRecursiveOptionsStayBounded() {
    var context = StatusFormatContext()
    context.options = ["@value": "abcdef", "@time": String(Int64.max), "@loop": "#{E:@loop}"]
    XCTAssertEqual(
      StatusFormatProgram.compile(
        source:
          "#{=-9223372036854775808:@value}|#{p-9223372036854775808:@value}|#{R:x,9223372036854775807}|#{t:@time}|#{E:@loop}"
      ).evaluate(context).text, "abcdef|abcdef|||")
    XCTAssertEqual(StatusFormatProgram.compile(source: "#{e/+/f:1.5,2.5}").evaluate().text, "4.00")
  }
}
