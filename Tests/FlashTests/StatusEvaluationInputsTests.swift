import XCTest

@testable import flash

final class StatusEvaluationInputsTests: XCTestCase {
  private func context(segments: [String: String]) -> FlashStatusBarContext {
    FlashStatusBarContext(
      focusedAppName: "App", focusedAppBundleID: "com.example.app", modeLabel: "NORMAL",
      now: Date(timeIntervalSince1970: 1_000_000), calendar: .current, locale: .current,
      pluginStatuses: [
        PluginStatusBarInfo(
          id: "sysinfo", state: "running", hasError: false,
          statusSegments: segments.mapValues(PluginStatusSegment.text))
      ],
      hostName: "h", userName: "u", userID: 1, processID: 1)
  }

  func testConditionalAndTimeValuesAreEvaluationInputs() {
    let template = FlashStatusBarTemplate(
      template:
        "#[align=right]#{flash.plugin.sysinfo.cpu_summary} #{?flash.plugin.sysinfo.cpu_summary,on,off} %H:%M"
    )
    let first = FlashStatusBarTemplateEngine.evaluate(
      template: template, context: context(segments: [:]))
    XCTAssertTrue(first.dependencies.values.contains("flash.plugin.sysinfo.cpu_summary"))
    XCTAssertTrue(first.dependencies.options.isEmpty)
    XCTAssertTrue(first.dependencies.containsTime)

    let before = FlashStatusBarTemplateEngine.formatContext(context(segments: [:]))
    let after = FlashStatusBarTemplateEngine.formatContext(
      context(segments: ["cpu_summary": "42%"]))
    XCTAssertNotEqual(
      FlashStatusBarTemplateEngine.EvaluationInputs.capture(
        dependencies: first.dependencies, native: before),
      FlashStatusBarTemplateEngine.EvaluationInputs.capture(
        dependencies: first.dependencies, native: after))
    let second = FlashStatusBarTemplateEngine.evaluate(
      template: template, context: context(segments: ["cpu_summary": "42%"]))
    XCTAssertTrue(second.model.rightDocument.map(\.text).joined().hasPrefix("42% on "))
  }
}
