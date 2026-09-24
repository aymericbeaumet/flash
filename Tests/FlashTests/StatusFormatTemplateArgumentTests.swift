import XCTest

@testable import flash

/// `#{E:@template,arg1,…}` / `#{T:@template,…}`: a Flash extension that binds
/// the arguments as `@1…@9` while the named option is expanded. Real tmux looks
/// up an option literally named `@template,arg1,…`; Flash keeps that meaning
/// whenever `@template` itself does not exist.
final class StatusFormatTemplateArgumentTests: XCTestCase {
  private func evaluate(
    _ source: String, options: [String: String], values: [String: String] = [:]
  ) -> StatusFormatEvaluation {
    var context = StatusFormatContext()
    context.options = options
    context.values = values
    return StatusFormatProgram.compile(source: source).evaluate(context)
  }

  private func text(
    _ source: String, options: [String: String], values: [String: String] = [:]
  ) -> String {
    evaluate(source, options: options, values: values).text
  }

  func testArgumentsBindAsNumberedOptions() {
    let options = ["@pair": "#{@1}=#{@2}"]
    XCTAssertEqual(text("#{E:@pair,cpu,42}", options: options), "cpu=42")
    XCTAssertEqual(text("#{E:@pair,cpu}", options: options), "cpu=", "a missing argument is empty")
    XCTAssertEqual(text("#{E:@pair,,x}", options: options), "=x", "an empty argument binds")
    XCTAssertEqual(text("#{E:@pair}", options: options), "=", "no arguments is plain E:")
    XCTAssertEqual(
      text("#{E:@nine,1,2,3,4,5,6,7,8,9,10}", options: ["@nine": "#{@9}#{@1}"]), "91",
      "arguments past the ninth are ignored")
  }

  func testArgumentsExpandInTheCallersContext() {
    let options = ["@pair": "#{@1}=#{@2}", "@name": "load", "@on": "1"]
    XCTAssertEqual(
      text(
        "#{E:@pair,#{@name},#{?@on,#{flash.plugin.cpu.load},off}}", options: options,
        values: ["flash.plugin.cpu.load": "3.47"]),
      "load=3.47")
    XCTAssertEqual(
      text("#{E:@pair,a,b}", options: ["@pair": "#{@1}#{@2}#{@3}", "@3": "outer"]), "ab",
      "unbound numbered options are empty inside the call")
  }

  func testBoundValuesAreNotReexpanded() {
    XCTAssertEqual(
      text(
        "#{E:@show,#{@raw}}", options: ["@show": "[#{@1}]", "@raw": "#{@secret}", "@secret": "x"]),
      "[#{@secret}]")
  }

  func testTemplatesNestWithTheirOwnScope() {
    let options = [
      "@outer": "[#{E:@inner,#{@2}}#{@1}]", "@inner": "<#{@1}#{@2}>",
    ]
    XCTAssertEqual(text("#{E:@outer,a,b}", options: options), "[<b>a]")
    XCTAssertEqual(
      text(
        "#{E:@outer,#{@1}}#{@1}",
        options: ["@outer": "#{E:@inner,x}#{@1}", "@inner": "#{@1}", "@1": "top"]),
      "xtoptop", "a call restores the caller's bindings")
  }

  func testEscapedCommasAndNestedFormatsStayInOneArgument() {
    let options = ["@pair": "#{@1}|#{@2}", "@y": "1"]
    XCTAssertEqual(text("#{E:@pair,a#,b,c}", options: options), "a,b|c")
    XCTAssertEqual(text("#{E:@pair,#{?@y,p,q},c}", options: options), "p|c")
    XCTAssertEqual(text("#{E:@pair,#{E:@pair,1,2},3}", options: options), "1|2|3")
    XCTAssertEqual(text("#{E:@pair,#[fg=red bold]x,y}", options: options), "#[fg=red bold]x|y")
  }

  func testTimeExpansionFollowsT() {
    var context = StatusFormatContext()
    context.options = ["@stamp": "%Y #{@1}"]
    context.now = Date(timeIntervalSince1970: 1_790_000_000)
    context.timeZone = TimeZone(secondsFromGMT: 0)!
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{T:@stamp,now}").evaluate(context).text, "2026 now")
    XCTAssertEqual(
      StatusFormatProgram.compile(source: "#{E:@stamp,now}").evaluate(context).text, "%Y now")
  }

  func testAMissingTemplateKeepsTmuxsLiteralLookup() {
    XCTAssertEqual(text("#{E:@missing,a,b}", options: [:]), "")
    XCTAssertEqual(
      text("#{E:@missing,#{@v},b}", options: ["@v": "hello"]), "@missing,hello,b")
    XCTAssertEqual(text("#{E:@t,a}", options: ["@t,a": "literal"]), "literal")
    XCTAssertEqual(text("#{@pair,a}", options: ["@pair": "x"]), "", "only E: and T: call")
    XCTAssertEqual(
      text("#{E:@pair,a}", options: ["@pair": "#{@1}", "@pair,a": "literal"]), "a",
      "an existing template wins over the literal option")
  }

  func testTemplateDependenciesAreCapturedStaticallyAndAtEvaluation() {
    let source = "#{E:@gauge,#{flash.plugin.cpu.percent},#(echo hi)}"
    let program = StatusFormatProgram.compile(source: source)
    XCTAssertTrue(program.dependencies.options.contains("@gauge"))
    XCTAssertTrue(program.dependencies.values.contains("flash.plugin.cpu.percent"))
    XCTAssertTrue(program.dependencies.containsJobs)
    let result = evaluate(
      source, options: ["@gauge": "#{@1}:#{@2}:#{flash.plugin.memory.percent}"],
      values: ["flash.plugin.cpu.percent": "40", "flash.plugin.memory.percent": "70"])
    XCTAssertEqual(result.text, "40::70", "a job without output yet is empty")
    XCTAssertTrue(result.dependencies.options.contains("@gauge"))
    XCTAssertTrue(result.dependencies.values.contains("flash.plugin.cpu.percent"))
    XCTAssertTrue(result.dependencies.values.contains("flash.plugin.memory.percent"))
    XCTAssertEqual(result.jobs.map(\.command), ["echo hi"], "an argument's job runs once")
  }

  func testRecursiveTemplatesStopAtTheDepthLimit() {
    let start = Date()
    let result = text("#{E:@loop,x}", options: ["@loop": "#{@1}#{E:@loop,#{@1}}"])
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    XCTAssertFalse(result.isEmpty)
    XCTAssertTrue(result.allSatisfy { $0 == "x" })
    XCTAssertLessThanOrEqual(result.count, 100)
  }

  func testWidgetConfigurationUsesTemplatesWithoutDiagnostics() throws {
    let config = ConfigLoader.parse(
      """
      [widgets.panel]
      template = "#{E:@row,CPU,#{flash.plugin.cpu.percent}}"
      [widgets.panel.options]
      "@row" = "#{@1} #[meter=10]#{@2}#[nometer]"
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let tokens = try XCTUnwrap(config.widgets["panel"]).template.variables.map(\.token)
    XCTAssertTrue(tokens.contains("flash.plugin.cpu.percent"))
  }
}
