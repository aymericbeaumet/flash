import XCTest

@testable import flash

final class StatusModeLabelTests: XCTestCase {
  func testOnlyModeInterpolationIsLiveAlongsideIdenticalLiteralAndAppText() {
    let model = FlashStatusBarTemplateEngine.render(
      template: .init(
        template:
          "#[pill]NORMAL #{flash.mode} NORMAL#[nopill] | #{flash.mode} | #{flash.active_app_name}"),
      context: .init(activeAppName: "NORMAL", modeLabel: "NORMAL"))

    let live = model.document.runs.filter(\.isModeLabel)
    XCTAssertEqual(live.map(\.text), ["NORMAL", "NORMAL"])
    XCTAssertEqual(live.map(\.pill), [true, false])
    XCTAssertEqual(
      model.document.runs.filter { !$0.isModeLabel }.map(\.text).joined(),
      "NORMAL  NORMAL |  | NORMAL")
  }

  func testModeInterpolationSurvivesOptionAndConditionalExpansion() {
    let model = FlashStatusBarTemplateEngine.render(
      template: .init(
        template: "#{E:@left}",
        options: ["@left": "#[pill]#{?flash.active_app_name,#{flash.mode},NONE}#[nopill]"]),
      context: .init(activeAppName: "App", modeLabel: "NØRMÅL"))

    let live = model.document.runs.filter(\.isModeLabel)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.first?.text, "NØRMÅL")
    XCTAssertEqual(live.first?.pill, true)
  }

  func testTransformedModeValuesKeepTheirEvaluatedText() {
    let model = FlashStatusBarTemplateEngine.render(
      template: .init(template: "#{=/1:flash.mode} #{n:flash.mode} #{s/N/X/:flash.mode}"),
      context: .init(modeLabel: "NORMAL"))

    XCTAssertFalse(model.document.runs.contains(where: \.isModeLabel))
    XCTAssertEqual(model.document.runs.map(\.text).joined(), "N 6 XORMAL")
  }

  func testEmptyModeInterpolationKeepsItsPositionAndPillStyle() {
    let model = FlashStatusBarTemplateEngine.render(
      template: .init(template: "before#[pill]#{flash.mode}#[nopill]after"),
      context: .init(modeLabel: " "))

    let live = model.document.runs.filter(\.isModeLabel)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.first?.text, "")
    XCTAssertEqual(live.first?.pill, true)
    XCTAssertEqual(live.first?.isStyleBoundary, false)
    XCTAssertEqual(model.modeDocument.filter(\.isModeLabel).count, 1)
    let resolved = model.document.runs.map { $0.isModeLabel ? "INSERT" : $0.text }.joined()
    XCTAssertEqual(resolved, "beforeINSERTafter")
  }

  func testAdjacentModeInterpolationsRemainSeparateIncludingEmptyValues() {
    for label in ["NORMAL", ""] {
      let model = FlashStatusBarTemplateEngine.render(
        template: .init(template: "#{flash.mode}#{flash.mode}"),
        context: .init(modeLabel: label))

      XCTAssertEqual(model.document.runs.filter(\.isModeLabel).count, 2)
      XCTAssertEqual(
        model.document.runs.map { $0.isModeLabel ? "INSERT" : $0.text }.joined(),
        "INSERTINSERT")
    }
  }
}
