import Carbon.HIToolbox
import Security
import XCTest

@testable import flash

final class DoctorTests: XCTestCase {
  private func healthy() -> Doctor.Inputs {
    Doctor.Inputs(
      accessibilityTrusted: true, tapInstalled: true, secureInputEnabled: false,
      signature: .certificate("Flash Dev"), configPath: "/tmp/flash.toml",
      plugins: PluginDoctor.Report(lines: ["protocol v1; 0 plugin(s)"], issues: 0),
      hintKeys: Array("asdfghjkl"), gridKeys: Array("12345qwertasdfgzxcvb"),
      readLayout: .usANSI)
  }

  private func check(_ report: Doctor.Report, _ id: String) -> Doctor.Check? {
    report.checks.first { $0.id == id }
  }

  func testAHealthySetupHasNoIssues() {
    var inputs = healthy()
    inputs.plugins = PluginDoctor.Report(
      lines: ["protocol v1; 2 plugin(s)", "ok media: state=running", "ok tmux: state=running"],
      issues: 0)
    let report = Doctor.run(inputs)
    XCTAssertEqual(report.checks.first { $0.id == "plugins" }?.summary, "2 plugins healthy")
    XCTAssertEqual(report.issues, 0, report.lines.joined(separator: "\n"))
    XCTAssertEqual(report.warnings, 0)
    XCTAssertEqual(
      report.checks.map(\.id),
      [
        "accessibility", "keyboard_tap", "secure_input", "signature", "residents", "config",
        "hotkeys", "plugins", "keyboard_layout",
      ])
    XCTAssertNil(check(report, "screen_recording"), "checked only with the screenshot plugin")
  }

  func testEveryFailureIsAnIssue() {
    var inputs = healthy()
    inputs.accessibilityTrusted = false
    inputs.tapInstalled = false
    inputs.otherResidents = [Doctor.Process(pid: 42, name: "/Applications/Flash.app")]
    inputs.configDiagnostics = ["/tmp/flash.toml:3:5: bad"]
    inputs.refusedHotkeys = ["cmd+shift+space"]
    inputs.plugins = PluginDoctor.Report(lines: ["!! media: exec missing"], issues: 1)
    let report = Doctor.run(inputs)
    XCTAssertEqual(report.issues, 6, report.lines.joined(separator: "\n"))
    for id in ["accessibility", "keyboard_tap", "residents", "config", "hotkeys", "plugins"] {
      XCTAssertEqual(check(report, id)?.status, .error, id)
    }
    XCTAssertEqual(check(report, "config")?.details, ["/tmp/flash.toml:3:5: bad"])
    XCTAssertEqual(check(report, "plugins")?.details, ["media: exec missing"])
    XCTAssertEqual(check(report, "hotkeys")?.details, ["cmd+shift+space"])
    XCTAssertTrue(check(report, "residents")?.summary.contains("2 Flash residents") == true)
  }

  func testSecureInputAndAdHocSigningWarnWithoutFailing() {
    var inputs = healthy()
    inputs.secureInputEnabled = true
    inputs.secureInputHolders = [Doctor.Process(pid: 7, name: "1Password")]
    inputs.signature = .adHoc
    inputs.screenRecordingGranted = false
    let report = Doctor.run(inputs)
    XCTAssertEqual(report.issues, 0)
    XCTAssertEqual(report.warnings, 3)
    XCTAssertTrue(
      check(report, "secure_input")?.summary.contains("1Password (pid 7)") == true,
      check(report, "secure_input")?.summary ?? "")
    XCTAssertTrue(check(report, "signature")?.summary.contains("ad-hoc") == true)
    XCTAssertEqual(check(report, "screen_recording")?.status, .warn)
  }

  func testKeysTheReadLayoutCannotTypeAreAnIssue() {
    var inputs = healthy()
    inputs.readLayout = KeyboardLayout(
      sourceID: "com.apple.keylayout.Russian",
      plain: [UInt16(kVK_ANSI_A): "ф", UInt16(kVK_ANSI_1): "1"], shifted: [:])
    inputs.hintKeys = Array("a1")
    inputs.gridKeys = Array("1q")
    let layout = check(Doctor.run(inputs), "keyboard_layout")
    XCTAssertEqual(layout?.status, .error)
    XCTAssertEqual(layout?.details, ["hints.keys: a", "mouse grid keys: q"])
    XCTAssertTrue(layout?.summary.contains("com.apple.keylayout.Russian") == true)

    // AZERTY types digits only with Shift, which the grid reads as a click
    // modifier: those cells cannot be selected.
    var azerty = healthy()
    azerty.readLayout = KeyboardLayout(
      sourceID: "com.apple.keylayout.French",
      plain: [UInt16(kVK_ANSI_Q): "a", UInt16(kVK_ANSI_1): "&"],
      shifted: [UInt16(kVK_ANSI_1): "1"])
    azerty.hintKeys = Array("a1")
    azerty.gridKeys = Array("1a")
    XCTAssertEqual(
      check(Doctor.run(azerty), "keyboard_layout")?.details, ["mouse grid keys: 1"])

    var missing = healthy()
    missing.missingKeyboardLayout = "com.example.Gone"
    XCTAssertEqual(check(Doctor.run(missing), "keyboard_layout")?.status, .error)
    XCTAssertTrue(
      check(Doctor.run(missing), "keyboard_layout")?.details.first?.contains("com.example.Gone")
        == true)
  }

  func testSecureInputHoldersComeFromConsoleUsers() {
    XCTAssertEqual(
      Doctor.secureInputPIDs(consoleUsers: [
        ["kCGSSessionSecureInputPID": NSNumber(value: 812), "kCGSSessionUserNameKey": "ab"],
        ["kCGSSessionUserNameKey": "guest"],
        ["kCGSSessionSecureInputPID": NSNumber(value: 0)],
      ]), [812])
  }

  func testSignatureKinds() {
    XCTAssertEqual(
      Doctor.signature(
        flags: SecCodeSignatureFlags.adhoc.rawValue, leafCertificate: nil, identifier: "x"),
      .adHoc)
    XCTAssertEqual(
      Doctor.signature(flags: 0, leafCertificate: "Developer ID Application", identifier: "x"),
      .certificate("Developer ID Application"))
    XCTAssertEqual(Doctor.signature(flags: 0, leafCertificate: nil, identifier: nil), .unsigned)
  }

  func testJSONAndTextRendering() throws {
    var inputs = healthy()
    inputs.tapInstalled = false
    inputs.signature = .adHoc
    let report = Doctor.run(inputs)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: report.data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["schema", "issues", "warnings", "checks"])
    XCTAssertEqual(object["issues"] as? Int, 1)
    let checks = try XCTUnwrap(object["checks"] as? [[String: Any]])
    XCTAssertEqual(Set(checks[0].keys), ["id", "status", "summary", "details"])
    let text = Doctor.render(object)
    XCTAssertTrue(text.contains("FAIL  the keyboard tap is not installed"), text)
    XCTAssertTrue(text.contains("warn  ad-hoc signed"), text)
    XCTAssertTrue(text.hasSuffix("1 issue found."), text)
  }
}
