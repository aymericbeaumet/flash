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
      autostart: false,
      hints: [
        .init(
          bundleIdentifier: "org.mozilla.firefox", count: 12, empty: 2, p50Ms: 160.24,
          p95Ms: 684.06),
        .init(bundleIdentifier: "org.alacritty", count: 4, empty: 4, p50Ms: nil, p95Ms: nil),
      ])
  }

  /// Scripts parse this object; a key added, renamed or dropped is a schema
  /// change and must bump `schema`.
  func testSchemaV2KeysArePinned() throws {
    XCTAssertEqual(FlashStatusReport.schema, 2)
    XCTAssertEqual(
      FlashStatusReport.keys,
      [
        "schema", "version", "build", "mode", "hint_session", "focused_app", "accessibility",
        "capture", "secure_input", "input_source", "keyboard_layout", "reference_layout",
        "config_path", "config_diagnostics", "plugins", "statusbar", "autostart", "hints",
      ])
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: report().data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(FlashStatusReport.keys))
    XCTAssertEqual(
      Set((object["plugins"] as? [String: Any] ?? [:]).keys), ["loaded", "ready", "error"])
    XCTAssertEqual(object["schema"] as? Int, 2)
    XCTAssertEqual(object["capture"] as? String, "tap")
    XCTAssertEqual(object["reference_layout"] as? String, "com.apple.keylayout.ABC")

    let hints = try XCTUnwrap(object["hints"] as? [String: [String: Any]])
    XCTAssertEqual(Set(hints.keys), ["org.mozilla.firefox", "org.alacritty"])
    let firefox = try XCTUnwrap(hints["org.mozilla.firefox"])
    XCTAssertEqual(Set(firefox.keys), ["count", "p50_ms", "p95_ms", "empty"])
    XCTAssertEqual(firefox["count"] as? Int, 12)
    XCTAssertEqual(firefox["empty"] as? Int, 2)
    XCTAssertEqual(firefox["p50_ms"] as? Double, 160.2)
    XCTAssertEqual(firefox["p95_ms"] as? Double, 684.1)
    let alacritty = try XCTUnwrap(hints["org.alacritty"])
    XCTAssertTrue(alacritty["p50_ms"] is NSNull, "no activation of it showed hints")
    XCTAssertTrue(alacritty["p95_ms"] is NSNull)
  }

  func testTheResidentsReportHasExactlyThePinnedKeys() throws {
    let delegate = AppDelegate()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: delegate.statusReport().data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(FlashStatusReport.keys))
    XCTAssertNil(object["clipboard"], "status never carries clipboard values")
    XCTAssertEqual(object["hint_session"] as? String, "idle")
    XCTAssertEqual((object["hints"] as? [String: Any])?.isEmpty, true)

    delegate.hintActivationStats.record(bundleIdentifier: "com.apple.Notes", ms: 12, empty: false)
    let recorded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: delegate.statusReport().data) as? [String: Any])
    let notes = (recorded["hints"] as? [String: [String: Any]])?["com.apple.Notes"]
    XCTAssertEqual(notes?["count"] as? Int, 1)
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
      "org.mozilla.firefox: 12 activations, 2 empty, p50 160.2 ms, p95 684.1 ms",
      "org.alacritty: 4 activations, 4 empty",
    ] {
      XCTAssertTrue(text.contains(fragment), "missing \(fragment) in\n\(text)")
    }
  }

  func testTextRenderingShowsTheBusiestAppsOnly() throws {
    var object: [String: Any] = ["version": "1", "build": "2"]
    object["hints"] = Dictionary(
      uniqueKeysWithValues: (1...5).map { index in
        (
          "app.\(index)",
          ["count": index, "empty": 0, "p50_ms": 10.0, "p95_ms": 20.0] as [String: Any]
        )
      })
    let text = FlashStatusReport.render(object)
    let lines = text.split(separator: "\n").map(String.init)
    let hintLines = lines.filter { $0.contains("activations") }
    XCTAssertTrue(hintLines.first?.hasPrefix("hints ") == true, text)
    XCTAssertEqual(
      hintLines.map {
        $0.replacingOccurrences(of: "hints", with: "").trimmingCharacters(in: .whitespaces)
      },
      [
        "app.5: 5 activations, 0 empty, p50 10.0 ms, p95 20.0 ms",
        "app.4: 4 activations, 0 empty, p50 10.0 ms, p95 20.0 ms",
        "app.3: 3 activations, 0 empty, p50 10.0 ms, p95 20.0 ms",
      ], text)
    let none = FlashStatusReport.render(["hints": [String: Any]()])
    XCTAssertTrue(
      none.split(separator: "\n").contains {
        $0.hasPrefix("hints ") && $0.hasSuffix(" none yet")
      }, none)
  }
}
