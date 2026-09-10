import XCTest

@testable import flash

final class StatusEvaluationInputsTests: XCTestCase {
  private func context(segments: [String: String]) -> FlashStatusBarContext {
    FlashStatusBarContext(
      activeAppName: "App", activeBundleIdentifier: "com.example.app", modeLabel: "NORMAL",
      now: Date(timeIntervalSince1970: 1_000_000), calendar: .current, locale: .current,
      pluginStatuses: [
        PluginStatusBarInfo(id: "cpu", state: "running", hasError: false, statusSegments: segments)
      ],
      hostName: "h", userName: "u", userID: 1, processID: 1)
  }

  func testOptionExpandedValuesAreEvaluationInputs() {
    let template = FlashStatusBarTemplate(template: "#[align=right]#{E:@right}")
    let options = ["@right": "#{flash.plugin.cpu.summary} #{?flash.plugin.cpu.summary,on,off} %H:%M"]
    let first = FlashStatusBarTemplateEngine.evaluate(
      template: template, context: context(segments: [:]), options: options)
    XCTAssertTrue(first.dependencies.values.contains("flash.plugin.cpu.summary"))
    XCTAssertTrue(first.dependencies.options.contains("@right"))
    XCTAssertTrue(first.dependencies.containsTime)

    var before = FlashStatusBarTemplateEngine.formatContext(context(segments: [:]))
    before.options = options
    var after = FlashStatusBarTemplateEngine.formatContext(context(segments: ["summary": "42%"]))
    after.options = options
    XCTAssertNotEqual(
      FlashStatusBarTemplateEngine.EvaluationInputs.capture(
        dependencies: first.dependencies, native: before),
      FlashStatusBarTemplateEngine.EvaluationInputs.capture(
        dependencies: first.dependencies, native: after))
    let second = FlashStatusBarTemplateEngine.evaluate(
      template: template, context: context(segments: ["summary": "42%"]), options: options)
    XCTAssertTrue(second.model.rightText.contains("42%"))
  }
}
