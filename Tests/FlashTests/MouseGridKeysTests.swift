import Foundation
import XCTest

@testable import flash

final class MouseGridKeysTests: XCTestCase {
  func testEmptyMatrixDerivesFromTheHintLayout() {
    XCTAssertNil(MouseGridKeys.problem(in: []))
    XCTAssertEqual(
      MouseGridKeys.resolve([], layoutName: "colemak"),
      Alphabet.gridKeys(layoutName: "colemak"))
    XCTAssertEqual(
      MouseGridKeys.resolve([], layoutName: nil), Alphabet.gridKeys(layoutName: "qwerty"))
  }

  func testExplicitMatrixIsLowercasedAndOverridesTheLayout() {
    XCTAssertNil(MouseGridKeys.problem(in: ["QWE", "asd"]))
    XCTAssertEqual(
      MouseGridKeys.resolve(["QWE", "asd"], layoutName: "dvorak"),
      [["q", "w", "e"], ["a", "s", "d"]])
  }

  func testEveryMalformedMatrixIsNamed() {
    let cases: [([String], MouseGridKeys.Problem)] = [
      (["qwert"], .tooFewRows),
      (["q", "a"], .tooFewColumns),
      (["qwert", "asdf"], .unevenRows),
      (["qw e", "asdf"], .whitespace),
      (["qw\te", "asdf"], .whitespace),
      (["qw`e", "asdf"], .reserved("`")),
      (["qwer", "asdQ"], .duplicate("q")),
      (["qqer", "asdf"], .duplicate("q")),
    ]
    for (rows, problem) in cases {
      XCTAssertEqual(MouseGridKeys.problem(in: rows), problem, "\(rows)")
    }
  }

  /// A rejected matrix is diagnosed and leaves the value an earlier layer set.
  func testEveryInvalidMatrixKeepsThePreviousValue() {
    let base = ConfigLoader.Layer(text: "[hints]\nmouse_grid_keys = [\"123\", \"qwe\"]")
    for invalid in [
      "[\"qwert\"]", "[\"q\", \"a\"]", "[\"qwert\", \"asdf\"]", "[\"q e\", \"asd\"]",
      "[\"q`e\", \"asd\"]", "[\"qwe\", \"asQ\"]", "\"qwert\"", "[1, 2]",
    ] {
      let config = ConfigLoader.parseLayers([
        base, ConfigLoader.Layer(text: "[hints]\nmouse_grid_keys = \(invalid)"),
      ])
      XCTAssertEqual(config.hints.mouseGridKeys, ["123", "qwe"], invalid)
      XCTAssertEqual(
        config.resolvedMouseGridKeys, [["1", "2", "3"], ["q", "w", "e"]], invalid)
      XCTAssertTrue(
        config.loadingDiagnostics.contains { $0.message.contains("hints.mouse_grid_keys") },
        "\(invalid): \(config.loadingDiagnostics.map(\.message))")
    }
  }

  /// `config.default.toml` is the base layer, so its empty default must defer
  /// to the user's layout instead of pinning QWERTY over it.
  func testUserLayoutOverTheDefaultLayerYieldsItsGrid() throws {
    let config = ConfigLoader.parseLayers([
      try defaultLayer(),
      ConfigLoader.Layer(text: "[hints]\nkeys = \"<colemak_homerow>\""),
    ])
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      config.resolvedMouseGridKeys.map { String($0) }, ["12345", "qwfpg", "arstd", "zxcvb"])
  }

  func testDefaultConfigUsesTheQwertyBlockAndNoCursorFollow() throws {
    let config = ConfigLoader.parseLayers([try defaultLayer()])
    XCTAssertEqual(config.hints.mouseGridKeys, [])
    XCTAssertFalse(config.hints.mouseGridCursorFollow)
    XCTAssertEqual(
      config.resolvedMouseGridKeys.map { String($0) }, ["12345", "qwert", "asdfg", "zxcvb"])
  }

  func testCursorFollowMustBeABoolean() {
    let config = ConfigLoader.parse("[hints]\nmouse_grid_cursor_follow = \"yes\"")
    XCTAssertFalse(config.hints.mouseGridCursorFollow)
    XCTAssertTrue(
      config.loadingDiagnostics.contains {
        $0.message.contains("hints.mouse_grid_cursor_follow")
      })
    XCTAssertTrue(
      ConfigLoader.parse("[hints]\nmouse_grid_cursor_follow = true")
        .hints.mouseGridCursorFollow)
  }

  private func defaultLayer() throws -> ConfigLoader.Layer {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // FlashTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("config.default.toml")
    return ConfigLoader.Layer(
      text: try String(contentsOf: url, encoding: .utf8), sourceURL: url,
      diagnosticLabel: "config.default.toml")
  }
}
