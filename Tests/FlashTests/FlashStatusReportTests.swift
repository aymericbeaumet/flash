import AppKit
import XCTest

@testable import flash

final class FlashStatusReportTests: XCTestCase {
  private func report() -> FlashStatusReport {
    FlashStatusReport(
      version: "1.2.3", build: "45", mode: "normal", hintSession: "idle",
      focusedApp: "com.apple.Safari", accessibility: true, capture: .tap, secureInput: false,
      inputSource: "com.apple.keylayout.Russian", keyboardLayout: "auto",
      referenceLayout: "com.apple.keylayout.ABC", configPath: "/tmp/flash.toml",
      configDiagnostics: 2, plugins: .init(loaded: 3, ready: 2, error: 1), statusBar: true,
      autostart: false)
  }

  /// Scripts parse this object; a key added, renamed or dropped is a schema
  /// change and must bump `schema`.
  func testSchemaV1KeysArePinned() throws {
    XCTAssertEqual(FlashStatusReport.schema, 1)
    XCTAssertEqual(
      FlashStatusReport.keys,
      [
        "schema", "version", "build", "mode", "hint_session", "focused_app", "accessibility",
        "capture", "secure_input", "input_source", "keyboard_layout", "reference_layout",
        "config_path", "config_diagnostics", "plugins", "statusbar", "autostart",
      ])
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: report().data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(FlashStatusReport.keys))
    XCTAssertEqual(
      Set((object["plugins"] as? [String: Any] ?? [:]).keys), ["loaded", "ready", "error"])
    XCTAssertEqual(object["schema"] as? Int, 1)
    XCTAssertEqual(object["capture"] as? String, "tap")
    XCTAssertEqual(object["reference_layout"] as? String, "com.apple.keylayout.ABC")
  }

  func testTheResidentsReportHasExactlyThePinnedKeys() throws {
    let delegate = AppDelegate()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: delegate.statusReport().data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(FlashStatusReport.keys))
    XCTAssertNil(object["clipboard"], "status never carries clipboard values")
    XCTAssertEqual(object["hint_session"] as? String, "idle")
  }

  func testHintSessionPhaseNamesWhoOwnsTheKeys() {
    typealias R = FlashStatusReport
    XCTAssertEqual(R.hintSessionPhase(route: .labels, active: false, discovering: false), "idle")
    XCTAssertEqual(
      R.hintSessionPhase(route: .labels, active: false, discovering: true), "discovering")
    XCTAssertEqual(R.hintSessionPhase(route: .labels, active: true, discovering: false), "labels")
    XCTAssertEqual(
      R.hintSessionPhase(
        route: .grid(.bisect, cursorFollows: false), active: true, discovering: false),
      "grid")
    XCTAssertEqual(R.hintSessionPhase(route: .search, active: true, discovering: false), "search")
    XCTAssertEqual(
      R.hintSessionPhase(route: .adjustment, active: true, discovering: false), "adjusting")
    XCTAssertEqual(R.hintSessionPhase(route: .pointer, active: true, discovering: false), "pointer")
  }

  func testCaptureIsTheSessionsOrWhatASessionStartingNowGets() {
    typealias R = FlashStatusReport
    XCTAssertEqual(R.capture(tapInstalled: true, secureInputEnabled: false, session: nil), .tap)
    XCTAssertEqual(
      R.capture(tapInstalled: true, secureInputEnabled: true, session: nil), .keyWindow)
    XCTAssertEqual(
      R.capture(tapInstalled: false, secureInputEnabled: false, session: nil), .keyWindow)
    XCTAssertEqual(
      R.capture(tapInstalled: true, secureInputEnabled: false, session: .keyWindow), .keyWindow)
  }

  func testModeNames() {
    XCTAssertEqual(FlashStatusReport.modeName(.disabled), "disabled")
    XCTAssertEqual(FlashStatusReport.modeName(.normal), "normal")
    XCTAssertEqual(FlashStatusReport.modeName(.insert), "insert")
  }

  func testTextRenderingListsEveryFact() throws {
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: report().data) as? [String: Any])
    let text = FlashStatusReport.render(object)
    XCTAssertTrue(text.hasPrefix("Flash 1.2.3 (45)"), text)
    for fragment in [
      "normal", "idle", "com.apple.Safari", "granted", "tap", "off",
      "com.apple.keylayout.Russian", "keys read on com.apple.keylayout.ABC",
      "/tmp/flash.toml (2 diagnostics)", "3 loaded, 2 ready, 1 with errors",
    ] {
      XCTAssertTrue(text.contains(fragment), "missing \(fragment) in\n\(text)")
    }
  }
}
