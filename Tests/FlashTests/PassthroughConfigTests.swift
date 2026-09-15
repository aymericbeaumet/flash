import XCTest

@testable import flash

final class PassthroughConfigTests: XCTestCase {
  func testPassthroughDisplaysInsertByDefault() {
    XCTAssertEqual(Config.default.mode.labels.passthrough, "INSERT")
    XCTAssertEqual(ConfigLoader.parse("").mode.labels.passthrough, "INSERT")
  }

  func testEmptyPassthroughLabelIsValid() {
    let config = ConfigLoader.parse(
      """
      [mode]
      labels = { normal = "NORMAL", passthrough = "", command = "COMMAND", terminal = "TERMINAL" }
      """)
    XCTAssertTrue(config.loadingDiagnostics.isEmpty)
    XCTAssertEqual(config.mode.labels.passthrough, "")
  }

  func testDefaultModeExitsAreScopedToNormalAndTerminal() throws {
    let escapeKey = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("<escape>"))
    for config in [Config.default, ConfigLoader.parse("")] {
      XCTAssertEqual(config.mode.normal.first { $0.key == "i" }?.action.command, .passthroughMode)
      XCTAssertNil(config.mode.normal.first { $0.key == escapeKey })
      XCTAssertEqual(
        config.mode.terminal.first { $0.key == escapeKey }?.action.command, .terminalDismiss)
      XCTAssertTrue(config.mode.passthrough.isEmpty)
      XCTAssertTrue(config.mode.all.isEmpty)
    }
  }

  func testDefaultModeExitMappingsCanBeOverridden() throws {
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "i" = ["flash", "scroll_top"]
      [mode.terminal.mappings]
      "<escape>" = ["flash", "terminal_restart"]
      """)
    XCTAssertTrue(config.loadingDiagnostics.isEmpty)
    let escapeKey = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("<escape>"))
    XCTAssertEqual(config.mode.normal.filter { $0.key == "i" }.count, 1)
    XCTAssertEqual(config.mode.compiledNormal.mapping(for: "i")?.action.command, .scroll(.top))
    XCTAssertEqual(config.mode.terminal.filter { $0.key == escapeKey }.count, 1)
    XCTAssertEqual(
      config.mode.compiledTerminal.mapping(for: escapeKey)?.action.command,
      .terminalRestart(name: nil))
  }

  func testNormalEntryVariantsEnableAdvancedModeAndReachTerminal() throws {
    let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("cmd+ctrl+["))
    for suffix in ["", ", \"--persistent\"", ", \"--persistent=false\""] {
      let config = ConfigLoader.parse(
        """
        [mode.all.mappings]
        "cmd+ctrl+[" = ["flash", "enter_normal_mode"\(suffix)]
        """)
      XCTAssertTrue(config.loadingDiagnostics.isEmpty, suffix)
      let action = try XCTUnwrap(config.mode.all.first?.action, suffix)
      XCTAssertTrue(config.mode.containsAdvancedModeMapping, suffix)
      XCTAssertTrue(config.mode.containsNormalModeMapping, suffix)
      XCTAssertEqual(config.mode.compiledTerminal.mapping(for: key)?.action, action, suffix)
    }
  }

  func testExplicitModeShortcutsSelectTheirModesInEveryInputScope() throws {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+[" = ["flash", "enter_normal_mode"]
      "cmd+ctrl+i" = ["flash", "enter_passthrough_mode"]
      """)
    XCTAssertTrue(config.loadingDiagnostics.isEmpty)
    let normalKey = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("cmd+ctrl+["))
    let passthroughKey = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey("cmd+ctrl+i"))
    for mappings in [
      config.mode.compiledNormal, config.mode.compiledPassthrough, config.mode.compiledTerminal,
    ] {
      XCTAssertEqual(
        mappings.mapping(for: normalKey)?.action.command, .normalMode(persistent: false))
      XCTAssertEqual(mappings.mapping(for: passthroughKey)?.action.command, .passthroughMode)
    }
    XCTAssertEqual(
      ModeReducer.reduce(
        .normal(persistent: false), .enterNormal(persistent: false, targetPID: nil)
      ).0,
      .normal(persistent: false))
    XCTAssertEqual(
      ModeReducer.reduce(.passthrough, .enterPassthrough(targetPID: nil)).0, .passthrough)
  }

  func testLegacyModeConfigurationAndRestoreFlagAreRejected() {
    let config = ConfigLoader.parse(
      """
      [mode.insert.mappings]
      "ctrl+n" = ["flash", "enter_normal_mode"]
      """)
    XCTAssertFalse(config.loadingDiagnostics.isEmpty)
    XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_insert_mode"]))
    for argument in ["--restore-mode", "--restore_mode=1"] {
      XCTAssertNil(
        parseMappingCommand(
          argv: ["flash", "enter_command_mode", "--input=flashlight ", argument]))
    }
  }
}
