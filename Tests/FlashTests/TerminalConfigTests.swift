import XCTest

@testable import flash

final class TerminalConfigTests: XCTestCase {
  func testTerminalDefaultsRestartQuitAndDismissTheFocusedProcess() throws {
    let referenceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("config.default.toml")
    let reference = ConfigLoader.parse(try String(contentsOf: referenceURL, encoding: .utf8))
    let expected: [(String, URLCommand)] = [
      ("cmd+r", .terminalRestart(name: nil)),
      ("cmd+q", .terminalQuit(name: nil)),
      ("cmd+w", .terminalDismiss),
    ]
    for config in [Config.default, ConfigLoader.parse(""), reference] {
      for (chord, command) in expected {
        let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey(chord))
        XCTAssertEqual(
          config.mode.compiledTerminal.mapping(for: key)?.action.command, command, chord)
      }
    }
  }

  func testTerminalsHaveExplicitPersistenceAndIndependentDefaults() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      enabled = false
      [terminal.shell]
      command = ["/bin/zsh", "-l"]
      [terminal.monitor]
      command = ["btm"]
      persistent = true
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.terminals["shell"]?.command, ["/bin/zsh", "-l"])
    XCTAssertEqual(config.terminals["shell"]?.columns, 100)
    XCTAssertEqual(config.terminals["shell"]?.rows, 28)
    XCTAssertEqual(config.terminals["shell"]?.persistent, false)
    XCTAssertEqual(config.terminals["monitor"]?.persistent, true)
  }

  func testInvalidReplacementIsMarkedWithoutDiscardingPreviousLayer() {
    for body in [
      "command = []", "command = [\"btm\"]\nrows = 0",
      "command = [\"btm\"]\npersistent = \"true\"",
      "command = [\"btm\"]\nenv = { PATH = 1 }",
      "command = [\"btm\"]\nunknown = true",
    ] {
      let config = ConfigLoader.parseLayers([
        .init(text: "[terminal.monitor]\ncommand = [\"btm\"]\npersistent = true"),
        .init(text: "[terminal.monitor]\n" + body),
      ])
      XCTAssertFalse(config.diagnostics.isEmpty, body)
      XCTAssertTrue(config.invalidTerminalNames.contains("monitor"), body)
      XCTAssertEqual(config.terminals["monitor"]?.command, ["btm"], body)
      XCTAssertEqual(config.terminals["monitor"]?.persistent, true, body)
    }
  }
  func testTerminalPathsAndEnvironmentFollowDefiningLayer() {
    let config = ConfigLoader.parseLayers([
      .init(
        text: """
          [terminal.editor]
          command = ["./editor", "--empty"]
          working_directory = "./work"
          env = { LANG = "en_US.UTF-8" }
          columns = 120
          rows = 32
          """, sourceURL: URL(fileURLWithPath: "/tmp/base/flash.toml")),
      .init(
        text: "[statusbar]\nenabled = true", sourceURL: URL(fileURLWithPath: "/tmp/user/flash.toml")
      ),
    ])
    let terminal = config.terminals["editor"]
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(terminal?.command, ["/tmp/base/editor", "--empty"])
    XCTAssertEqual(terminal?.workingDirectory, "/tmp/base/work")
    XCTAssertEqual(terminal?.environment, ["LANG": "en_US.UTF-8"])
    XCTAssertEqual(terminal?.columns, 120)
    XCTAssertEqual(terminal?.rows, 32)
  }

  func testWorkingDirectoryExpandsHomeAndPreservesRelativePaths() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for (directory, expected) in [
      ("~", home),
      ("~/projects", home + "/projects"),
      ("work", "/tmp/config/work"),
      ("./work", "/tmp/config/work"),
    ] {
      let config = ConfigLoader.parse(
        """
        [terminal.shell]
        command = ["/bin/zsh"]
        working_directory = "\(directory)"
        """, sourceURL: URL(fileURLWithPath: "/tmp/config/flash.toml"))
      XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
      let terminal = try XCTUnwrap(config.terminals["shell"])
      let launch = StatusTerminalRegistry.configuration(for: terminal, environment: [:])
      XCTAssertEqual(launch.workingDirectory, expected, directory)
    }
  }

  func testValidReplacementClearsInvalidMarkerAndUpdatesPersistence() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[terminal.shell]\ncommand = []"),
      .init(text: "[terminal.shell]\ncommand = [\"/bin/zsh\"]\npersistent = true"),
    ])
    XCTAssertTrue(config.invalidTerminalNames.isEmpty)
    XCTAssertEqual(config.terminals["shell"]?.persistent, true)
  }

  func testMalformedTablesAreDiagnosedAndPersistentRequiresBoolean() {
    for text in [
      "terminal = 42", "[terminal]\nshell = true", "[terminal.\"\"]\ncommand = [\"/bin/zsh\"]",
    ] {
      let config = ConfigLoader.parse(text)
      XCTAssertFalse(config.diagnostics.isEmpty, text)
      XCTAssertTrue(config.terminals.isEmpty, text)
    }
    let config = ConfigLoader.parse("[terminal.shell]\ncommand = [\"/bin/zsh\"]\npersistent = 1")
    XCTAssertTrue(
      config.diagnostics.contains {
        $0.message.contains("terminal.shell.persistent must be a boolean")
      })
    XCTAssertTrue(config.invalidTerminalNames.contains("shell"))
  }

  func testResolvedDiagnosticsDoNotExposeTerminalCommandsOrEnvironment() {
    let config = ConfigLoader.parse(
      """
      [terminal.shell]
      command = ["/bin/zsh", "private-argument"]
      env = { TOKEN = "private-secret" }
      persistent = true
      """)
    XCTAssertFalse(config.resolvedConfigJSON.contains("private-argument"))
    XCTAssertFalse(config.resolvedConfigJSON.contains("private-secret"))
    XCTAssertTrue(config.resolvedConfigJSON.contains("persistent"))
  }

}
