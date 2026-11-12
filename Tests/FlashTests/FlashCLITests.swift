import AppKit
import XCTest

@testable import flash

final class FlashCLITests: XCTestCase {
  // Transport and replies are `CommandInvocationTests`.

  // MARK: Queries

  func testStatusRendersAsTextOrJSON() throws {
    let object: [String: Any] = [
      "schema": 3, "version": "1.2.3", "build": "4", "mode": "normal",
      "plugins": ["loaded": 1, "ready": 1, "error": 0],
      "hints": ["com.apple.Notes": ["count": 3, "empty": 0, "p50_ms": 1.5, "p95_ms": 2.5]],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let text = try XCTUnwrap(FlashQuery.render(.status, json: data, asJSON: false))
    XCTAssertTrue(text.hasPrefix("Flash 1.2.3 (4)"), text)
    XCTAssertTrue(text.contains("com.apple.Notes: 3 activations"), text)

    let json = try XCTUnwrap(FlashQuery.render(.status, json: data, asJSON: true))
    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(decoded["mode"] as? String, "normal")
    XCTAssertEqual(decoded["schema"] as? Int, 3)
    XCTAssertEqual(
      (decoded["hints"] as? [String: [String: Any]])?["com.apple.Notes"]?["count"] as? Int, 3)
    XCTAssertNil(FlashQuery.render(.status, json: Data(), asJSON: false))
  }

  func testDoctorRendersItsChecks() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "schema": 1, "issues": 1, "warnings": 0,
      "checks": [["id": "keyboard_tap", "status": "error", "summary": "no tap", "details": []]],
    ])
    let text = try XCTUnwrap(FlashQuery.render(.doctor, json: data, asJSON: false))
    XCTAssertTrue(text.contains("FAIL  no tap"), text)
  }

  func testQueryArguments() {
    XCTAssertTrue(FlashQuery.status.accepts([:]))
    XCTAssertTrue(FlashQuery.doctor.accepts(["json": "1"]))
    XCTAssertFalse(FlashQuery.status.accepts(["json": "false"]))
    XCTAssertFalse(FlashQuery.status.accepts(["file": "x"]))
    XCTAssertTrue(FlashQuery.configCheck.accepts(["file": "~/f.toml"]))
    XCTAssertFalse(FlashQuery.configCheck.accepts(["file": ""]))
    XCTAssertFalse(FlashQuery.configCheck.accepts(["json": "1"]))
  }

  func testConfigCheckPrintsLocatedDiagnosticsAndFails() {
    let url = URL(fileURLWithPath: "/tmp/flash-check.toml")
    let bad = ConfigCheck.run(
      fileURL: url,
      text: """
        [mode.normal.mappings]
        "t" = true

        [hints]
        min_length = 0
        """,
      defaultLayer: nil)
    XCTAssertEqual(bad.exitCode, 1)
    XCTAssertEqual(bad.lines.count, 2, bad.lines.joined(separator: "\n"))
    // In line order, whichever section the loader validated first.
    XCTAssertTrue(bad.lines[0].hasPrefix("/tmp/flash-check.toml:2:7: mapping \"t\""), bad.lines[0])
    XCTAssertTrue(
      bad.lines[1].hasPrefix("/tmp/flash-check.toml:5:14: hints.min_length"), bad.lines[1])

    let good = ConfigCheck.run(
      fileURL: url, text: "[mode.normal.mappings]\n\"t\" = false\n", defaultLayer: nil)
    XCTAssertEqual(good, ConfigCheck.Result(exitCode: 0, lines: []))

    let unreadable = ConfigCheck.run(fileURL: url, text: nil, defaultLayer: nil)
    XCTAssertEqual(unreadable.exitCode, 2)
    XCTAssertEqual(unreadable.lines, ["/tmp/flash-check.toml: cannot read the file"])
  }

  /// Through `~/.local/bin/flash`, `Bundle.main` is the symlink's
  /// directory; the bundled defaults come from the executable's own bundle.
  func testTheAppBundleIsFoundFromTheResolvedExecutable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Flash.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.flash.test</string></dict></plist>
      """.utf8
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try XCTUnwrap(
      FlashCLI.appBundle(containing: macOS.appendingPathComponent("flash")))
    XCTAssertEqual(bundle.bundleURL.lastPathComponent, "Flash.app")
    XCTAssertNil(FlashCLI.appBundle(containing: root.appendingPathComponent("bin/flash")))
  }

  func testConfigCheckNamesTheBundledDefaultsForTheirOwnDiagnostics() {
    let defaults = ConfigLoader.Layer(
      text: "[hints]\nmin_length = 0\n",
      sourceURL: URL(fileURLWithPath: "/Applications/Flash.app/config.default.toml"),
      diagnosticLabel: "config.default.toml")
    let result = ConfigCheck.run(
      fileURL: URL(fileURLWithPath: "/tmp/user.toml"), text: "", defaultLayer: defaults)
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(
      result.lines[0].hasPrefix(
        "/Applications/Flash.app/config.default.toml:2:14: config.default.toml: hints.min_length"),
      result.lines[0])
  }

}
