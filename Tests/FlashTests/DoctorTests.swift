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
    XCTAssertNil(check(report, "hint_activations"), "reported only once hints were asked for")
  }

  /// A bar segment whose plugin is gone, disabled or never published that
  /// name shows nothing and fails no check: the doctor names each one and
  /// the value it most likely meant (a merged plugin's `<old>_<name>`, or the
  /// same name under another plugin).
  func testStatusValuesNoPluginPublishesAreNamedWithTheirReplacement() throws {
    var inputs = healthy()
    inputs.statusSegmentsRead = [
      "cpu": ["label"], "tmux": ["session"], "feed": ["label"], "sysinfo": ["cpu_temp"],
      "spotify": ["track"], "aiproviders": ["claude"],
    ]
    inputs.statusSegmentsDeclared = [
      "sysinfo": ["cpu_label", "cpu_percent"], "terminals": ["session", "window"],
      "feed": ["label", "summary"], "aiproviders": ["claude"],
    ]
    inputs.disabledPlugins = ["feed"]
    let found = try XCTUnwrap(check(Doctor.run(inputs), "status_values"))
    XCTAssertEqual(found.status, .warn)
    XCTAssertEqual(
      found.details,
      [
        "flash.plugin.cpu.label: no cpu plugin is loaded; did you mean flash.plugin.sysinfo.cpu_label?",
        "flash.plugin.feed.label: the feed plugin is disabled ([plugins] disabled)",
        "flash.plugin.spotify.track: no spotify plugin is loaded",
        "flash.plugin.sysinfo.cpu_temp: the sysinfo plugin publishes no cpu_temp "
          + "(it has cpu_label, cpu_percent)",
        "flash.plugin.tmux.session: no tmux plugin is loaded; did you mean flash.plugin.terminals.session?",
      ])

    inputs.statusSegmentsRead = ["sysinfo": ["cpu_label"]]
    XCTAssertEqual(check(Doctor.run(inputs), "status_values")?.status, .ok)
    inputs.statusSegmentsRead = [:]
    XCTAssertNil(check(Doctor.run(inputs), "status_values"), "nothing reads a plugin value")
  }

  func testPopupCommandsMissingFromTheLoginPathWarnWithTheirPopup() {
    var inputs = healthy()
    inputs.popupCommands = ["btop": "btop", "shell": "/bin/sh", "feed": "sh"]
    inputs.popupPath = "/usr/bin:/bin"
    let report = Doctor.run(inputs)
    let popups = check(report, "popup_commands")
    XCTAssertEqual(popups?.status, .warn)
    XCTAssertEqual(popups?.details.first, "popup.btop: btop")
    XCTAssertEqual(report.issues, 0, "a missing popup tool is a warning, not an issue")
    inputs.popupCommands = ["shell": "/bin/sh"]
    XCTAssertEqual(check(Doctor.run(inputs), "popup_commands")?.status, .ok)
    inputs.popupCommands = [:]
    XCTAssertNil(check(Doctor.run(inputs), "popup_commands"), "only with terminal popups")
  }

  /// A status link whose scheme is neither web, mail nor allowlisted does
  /// nothing; the doctor names each refused scheme once, with the setting
  /// that would allow it. Nothing refused, nothing said.
  func testRefusedStatusLinkSchemesAreNotedOnceWithTheSettingThatAllowsThem() throws {
    var inputs = healthy()
    XCTAssertNil(check(Doctor.run(inputs), "status_links"))
    inputs.refusedLinkSchemes = ["file", "slack"]
    let found = try XCTUnwrap(check(Doctor.run(inputs), "status_links"))
    XCTAssertEqual(found.status, .warn)
    XCTAssertEqual(found.summary, "2 status link schemes were refused since launch: file, slack")
    XCTAssertEqual(
      found.details,
      [
        "A #[link] opens only http, https and mailto URLs; a refused link does nothing.",
        "Allow a scheme with [statusbar] link_schemes = [\"file\", \"slack\"] "
          + "when you trust what writes those links.",
      ])
    XCTAssertEqual(Doctor.run(inputs).issues, 0, "a refused link is a warning, not an issue")
  }

  func testAMissingLinkSchemeIsNotSuggestedAsAnAllowlistEntry() throws {
    let check = try XCTUnwrap(Doctor.statusLinksCheck(["(none)", "slack"]))
    XCTAssertFalse(check.details.joined().contains("\"(none)\""))
    XCTAssertTrue(check.details.joined().contains("link_schemes = [\"slack\"]"))
    XCTAssertTrue(check.details.joined().contains("absolute URL"))
    let relativeOnly = try XCTUnwrap(Doctor.statusLinksCheck(["(none)"]))
    XCTAssertFalse(relativeOnly.details.joined().contains("link_schemes ="))
  }

  /// The OTLP receiver listens on loopback, which every account and program
  /// on the Mac shares. Without a token that is fine until a monitor runs a
  /// command from a received metric: then anyone local can fire it.
  func testAnOpenReceiverWarnsOnlyWhenAMonitorRunsCommandsFromReceivedMetrics() throws {
    var inputs = healthy()
    XCTAssertNil(check(Doctor.run(inputs), "telemetry_receiver"), "nothing to say when off")
    inputs.telemetryReceiver = .init(
      enabled: false, port: 4318, hasToken: false, monitorsRunOnReceivedMetrics: ["deploy"])
    XCTAssertNil(check(Doctor.run(inputs), "telemetry_receiver"), "off: no listener to guard")

    inputs.telemetryReceiver = .init(
      enabled: true, port: 4318, hasToken: false, monitorsRunOnReceivedMetrics: [])
    XCTAssertEqual(check(Doctor.run(inputs), "telemetry_receiver")?.status, .ok)
    inputs.telemetryReceiver = .init(
      enabled: true, port: 4318, hasToken: true, monitorsRunOnReceivedMetrics: ["deploy"])
    XCTAssertEqual(check(Doctor.run(inputs), "telemetry_receiver")?.status, .ok)

    inputs.telemetryReceiver = .init(
      enabled: true, port: 4319, hasToken: false,
      monitorsRunOnReceivedMetrics: ["build_long", "deploy"])
    let found = try XCTUnwrap(check(Doctor.run(inputs), "telemetry_receiver"))
    XCTAssertEqual(found.status, .warn)
    XCTAssertEqual(
      found.summary,
      "the OTLP receiver on 127.0.0.1:4319 has no token, and 2 monitors run commands "
        + "from received metrics: build_long, deploy")
    XCTAssertEqual(
      found.details,
      [
        "Any program on this Mac, under any account, can post a metric there and fire them.",
        "Set [telemetry.receiver] token and send it as Authorization: Bearer <token> "
          + "(OTEL_EXPORTER_OTLP_HEADERS), or drop run from those monitors.",
      ])
    XCTAssertEqual(Doctor.run(inputs).issues, 0, "a warning: the receiver is opt-in by design")
  }

  func testRecentHintActivationsAreReportedOnceThereAreAny() {
    typealias Summary = HintActivationStats.Summary
    var inputs = healthy()
    inputs.hintActivations = [
      Summary(bundleIdentifier: "com.apple.Notes", count: 8, empty: 1, p50Ms: 12, p95Ms: 40),
      // Too few activations to judge.
      Summary(bundleIdentifier: "com.example.rare", count: 4, empty: 4, p50Ms: nil, p95Ms: nil),
    ]
    let fine = check(Doctor.run(inputs), "hint_activations")
    XCTAssertEqual(fine?.status, .ok)
    XCTAssertEqual(fine?.summary, "hints appeared in 7 of 12 recent activations across 2 apps")
    XCTAssertEqual(Doctor.run(inputs).warnings, 0)

    inputs.hintActivations = [
      // 13 of 50 empty: over a fifth.
      Summary(
        bundleIdentifier: "org.mozilla.firefox", count: 50, empty: 13, p50Ms: 160, p95Ms: 420),
      // Slow at the tail.
      Summary(
        bundleIdentifier: "com.tinyspeck.slackmacgap", count: 20, empty: 0, p50Ms: 90, p95Ms: 684),
      Summary(bundleIdentifier: "com.apple.Notes", count: 8, empty: 1, p50Ms: 12, p95Ms: 40),
    ]
    let report = Doctor.run(inputs)
    let flagged = check(report, "hint_activations")
    XCTAssertEqual(flagged?.status, .warn, "a warning never fails `flash resident doctor`")
    XCTAssertEqual(report.issues, 0)
    XCTAssertEqual(
      flagged?.summary,
      "hints were often empty or slow in 2 apps: org.mozilla.firefox, com.tinyspeck.slackmacgap")
    XCTAssertEqual(
      flagged?.details.prefix(2),
      [
        "org.mozilla.firefox: 13 of 50 recent activations showed no hints; p95 420 ms",
        "com.tinyspeck.slackmacgap: 0 of 20 recent activations showed no hints; p95 684 ms",
      ])
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
    XCTAssertTrue(
      check(report, "secure_input")?.details.contains {
        $0.contains("asks the holding app to release")
      } == true)
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
