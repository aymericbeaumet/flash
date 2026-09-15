import XCTest

@testable import flash

final class PassthroughConfigTests: XCTestCase {
  func testPassthroughHasNoDefaultDisplayLabel() {
    XCTAssertEqual(Config.default.mode.labels.passthrough, "")
    XCTAssertEqual(ConfigLoader.parse("").mode.labels.passthrough, "")
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

  func testNormalModeHasNoBarePassthroughExits() {
    for config in [Config.default, ConfigLoader.parse("")] {
      for rawKey in ["i", "<escape>"] {
        let key = NormalModeInterpreter.canonicalizeMappingKey(rawKey)
        XCTAssertNil(config.mode.normal.first { $0.key == key })
      }
      XCTAssertTrue(config.mode.passthrough.isEmpty)
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
      XCTAssertEqual(mappings.mapping(for: normalKey)?.action.command, .normalMode)
      XCTAssertEqual(mappings.mapping(for: passthroughKey)?.action.command, .passthroughMode)
    }
    XCTAssertEqual(ModeReducer.reduce(.normal, .enterNormal(targetPID: nil)).0, .normal)
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
