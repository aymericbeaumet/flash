import AppKit
import XCTest

@testable import flash

final class FlashCLITests: XCTestCase {
  func testAutomationDenialPreservesItsErrorCodeInsteadOfClaimingInvalidArguments() {
    for status in [OSStatus(noErr), OSStatus(errAEEventNotPermitted)] {
      let result = FlashCLI.response(
        verb: "enter_normal_mode", status: status,
        reply: reply(error: Int32(errAEEventNotPermitted)))
      XCTAssertEqual(result.exitCode, 1)
      XCTAssertTrue(result.message?.contains("OSStatus=-1743") == true)
      XCTAssertFalse(result.message?.contains("Unsupported command") == true)
    }
  }

  func testTransportErrorTakesPrecedenceOverAnErrorReply() {
    let result = FlashCLI.response(
      verb: "enter_normal_mode", status: OSStatus(errAETimeout),
      reply: reply(error: Int32(errAEEventNotHandled), message: "unrelated reply"))
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.message?.contains("OSStatus=-1712") == true)
    XCTAssertFalse(result.message?.contains("unrelated reply") == true)
  }

  func testUnhandledNativeEventWithoutAResidentMessageIsATransportFailure() {
    let result = FlashCLI.response(
      verb: "enter_normal_mode", status: noErr,
      reply: reply(error: Int32(errAEEventNotHandled)))
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.message?.contains("OSStatus=-1708") == true)
  }

  func testExplicitResidentRejectionPreservesItsDiagnostic() {
    let message = URLEventHandler.rejectionMessage("flash missing_plugin_verb")
    let result = FlashCLI.response(
      verb: "missing_plugin_verb", status: noErr,
      reply: reply(error: Int32(errAEEventNotHandled), message: message))
    XCTAssertEqual(result.exitCode, 2)
    XCTAssertEqual(result.message, message)
  }

  func testSuccessfulResponseHasNoDiagnostic() {
    let result = FlashCLI.response(verb: "enter_normal_mode", status: noErr, reply: reply())
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertNil(result.message)
  }

  func testANotRunningResidentSaysSo() {
    let result = FlashCLI.response(
      verb: "status", status: OSStatus(procNotFound), reply: reply())
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.message, "Flash is not running")
  }

  // MARK: Queries

  private func queryReply(_ object: [String: Any]) throws -> NSAppleEventDescriptor {
    let reply = reply()
    URLEventHandler.setDirectObject(
      try JSONSerialization.data(withJSONObject: object), on: reply)
    return reply
  }

  func testStatusRendersTheDirectObjectAsTextOrJSON() throws {
    let object: [String: Any] = [
      "schema": 1, "version": "1.2.3", "build": "4", "mode": "normal",
      "plugins": ["loaded": 1, "ready": 1, "error": 0],
    ]
    let text = FlashCLI.queryOutcome(
      .status, json: false, status: noErr, reply: try queryReply(object))
    XCTAssertEqual(text.exitCode, 0)
    XCTAssertNil(text.message)
    XCTAssertTrue(text.output?.hasPrefix("Flash 1.2.3 (4)") == true, text.output ?? "")

    let json = FlashCLI.queryOutcome(
      .status, json: true, status: noErr, reply: try queryReply(object))
    XCTAssertEqual(json.exitCode, 0)
    let decoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data((json.output ?? "").utf8)) as? [String: Any])
    XCTAssertEqual(decoded["mode"] as? String, "normal")
    XCTAssertEqual(decoded["schema"] as? Int, 1)
  }

  func testDoctorExitsOneOnlyWhenItFoundAnIssue() throws {
    let failing = try queryReply([
      "schema": 1, "issues": 1, "warnings": 0,
      "checks": [["id": "keyboard_tap", "status": "error", "summary": "no tap", "details": []]],
    ])
    let failed = FlashCLI.queryOutcome(.doctor, json: false, status: noErr, reply: failing)
    XCTAssertEqual(failed.exitCode, 1)
    XCTAssertTrue(failed.output?.contains("FAIL  no tap") == true, failed.output ?? "")
    XCTAssertEqual(
      FlashCLI.queryOutcome(.doctor, json: true, status: noErr, reply: failing).exitCode, 1)

    let warning = try queryReply([
      "schema": 1, "issues": 0, "warnings": 1,
      "checks": [["id": "signature", "status": "warn", "summary": "ad-hoc", "details": []]],
    ])
    XCTAssertEqual(
      FlashCLI.queryOutcome(.doctor, json: false, status: noErr, reply: warning).exitCode, 0)
  }

  func testAQueryReplyWithoutJSONOrWithATransportErrorFails() {
    let empty = FlashCLI.queryOutcome(.status, json: false, status: noErr, reply: reply())
    XCTAssertEqual(empty.exitCode, 1)
    XCTAssertNil(empty.output)
    XCTAssertTrue(empty.message?.contains("carried no JSON") == true)

    let transport = FlashCLI.queryOutcome(
      .doctor, json: false, status: OSStatus(errAETimeout), reply: reply())
    XCTAssertEqual(transport.exitCode, 1)
    XCTAssertTrue(transport.message?.contains("OSStatus=-1712") == true)
  }

  func testConfigCheckRunsWithoutTheResidentAndQueriesRejectForeignArguments() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-check-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("[mode.normal.mappings]\n\"t\" = false\n".utf8).write(to: url)
    XCTAssertEqual(FlashCLI.run(args: ["config_check", "--file=\(url.path)"]), 0)
    try Data("[hints]\nmin_length = 0\n".utf8).write(to: url)
    XCTAssertEqual(FlashCLI.run(args: ["config_check", "--file=\(url.path)"]), 1)
    XCTAssertEqual(FlashCLI.run(args: ["config_check", "--file=\(url.path).missing"]), 2)
    // Rejected before any event is sent.
    XCTAssertEqual(FlashCLI.run(args: ["status", "--file=x"]), 2)
    XCTAssertEqual(FlashCLI.run(args: ["doctor", "positional"]), 2)
  }

  func testQueryOptions() {
    XCTAssertEqual(FlashCLI.queryOptions(.status, args: [:])?.json, false)
    XCTAssertEqual(FlashCLI.queryOptions(.doctor, args: ["json": "1"])?.json, true)
    XCTAssertNil(FlashCLI.queryOptions(.status, args: ["json": "false"]))
    XCTAssertNil(FlashCLI.queryOptions(.status, args: ["file": "x"]))
    XCTAssertEqual(
      FlashCLI.queryOptions(.configCheck, args: ["file": "~/f.toml"])?.file, "~/f.toml")
    XCTAssertNil(FlashCLI.queryOptions(.configCheck, args: ["file": ""]))
    XCTAssertNil(FlashCLI.queryOptions(.configCheck, args: ["json": "1"]))
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

  private func reply(error: Int32? = nil, message: String? = nil) -> NSAppleEventDescriptor {
    let reply = NSAppleEventDescriptor.appleEvent(
      withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
      targetDescriptor: nil, returnID: 0, transactionID: 0)
    if let error {
      reply.setParam(NSAppleEventDescriptor(int32: error), forKeyword: AEKeyword(keyErrorNumber))
    }
    if let message {
      reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: AEKeyword(keyErrorString))
    }
    return reply
  }
}
