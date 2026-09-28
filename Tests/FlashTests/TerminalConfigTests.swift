import XCTest

@testable import flash

/// `[popup.<name>]` with `command`: terminal popups.
final class TerminalConfigTests: XCTestCase {
  func testPopupDefaultsRestartQuitAndDismissTheFocusedPopup() throws {
    let referenceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("config.default.toml")
    let reference = ConfigLoader.parse(try String(contentsOf: referenceURL, encoding: .utf8))
    let expected: [(String, URLCommand)] = [
      ("cmd+r", .popupRestart(name: nil)),
      ("cmd+q", .popupQuit(name: nil)),
      ("cmd+w", .popupDismiss),
    ]
    for config in [Config.default, ConfigLoader.parse(""), reference] {
      for (chord, command) in expected {
        let key = try XCTUnwrap(NormalModeInterpreter.canonicalizeMappingKey(chord))
        XCTAssertEqual(
          config.mode.compiledTerminal.mapping(for: key)?.action.command, command, chord)
      }
    }
  }

  func testTerminalPopupsHaveExplicitPersistenceSizeAndDefaults() {
    let config = ConfigLoader.parse(
      """
      [popup.editor]
      command = ["/bin/zsh", "-l"]
      [popup.btop]
      command = ["btop"]
      size = "90%x85%"
      persistent = true
      [popup.bonsai]
      command = ["bonsai", "hq"]
      size = "120x36"
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    let terminals = config.terminalPopups
    XCTAssertEqual(terminals["editor"]?.command, ["/bin/zsh", "-l"])
    XCTAssertEqual(terminals["editor"]?.size, .default)
    XCTAssertEqual(terminals["editor"]?.lifecycle, .fresh)
    XCTAssertEqual(
      terminals["btop"]?.size, Config.PopupSize(columns: .percent(90), rows: .percent(85)))
    XCTAssertEqual(terminals["btop"]?.lifecycle, .persistent)
    XCTAssertEqual(
      terminals["bonsai"]?.size, Config.PopupSize(columns: .cells(120), rows: .cells(36)))
    XCTAssertEqual(
      terminals["shell"],
      Config.defaultPopups["shell"].flatMap {
        if case .terminal(let shell) = $0 { return shell }
        return nil
      })
  }

  func testPopupSizeParsesCellsAndPercentagesPerSide() {
    XCTAssertEqual(Config.PopupSize.default.description, "100x28")
    for raw in ["100x28", "90%x85%", "120x50%", "1x1", "1000x1000", "100%x1%"] {
      XCTAssertEqual(Config.PopupSize(raw)?.description, raw, raw)
    }
    for raw in [
      "", "100", "100X28", "0x28", "1001x28", "0%x10%", "101%x10%", "100 x 28", "-1x28",
      "10.5x28", "x28", "100x", "100x28x3", "%x28",
    ] {
      XCTAssertNil(Config.PopupSize(raw), raw)
    }
  }

  func testPopupSizeGridsFitTheScreen() {
    let cell = CGSize(width: 8, height: 16)
    let screen = CGSize(width: 1000, height: 820)
    // Cells are exact until the screen is too small.
    let cells = Config.PopupSize(columns: .cells(100), rows: .cells(28))
    XCTAssertTrue(cells.grid(visible: screen, cell: cell, inset: 10) == (100, 28))
    XCTAssertTrue(
      cells.grid(visible: CGSize(width: 420, height: 200), cell: cell, inset: 10) == (50, 11))
    // A percentage sizes the popup's outer frame, inset included.
    let percent = Config.PopupSize(columns: .percent(50), rows: .percent(100))
    XCTAssertTrue(percent.grid(visible: screen, cell: cell, inset: 10) == (60, 50))
    XCTAssertTrue(
      percent.grid(visible: screen, cell: cell, inset: 10, reservedHeight: 16) == (60, 49))
    XCTAssertTrue(
      Config.PopupSize(columns: .percent(1), rows: .percent(1)).grid(
        visible: screen, cell: cell, inset: 10) == (1, 1))
    XCTAssertTrue(percent.followsScreen)
    XCTAssertFalse(cells.followsScreen)
    XCTAssertTrue(percent.unplacedGrid == (100, 28))
    XCTAssertTrue(
      Config.PopupSize(columns: .cells(120), rows: .percent(80)).unplacedGrid == (120, 28))
  }

  func testInvalidReplacementIsMarkedWithoutDiscardingPreviousLayer() {
    for body in [
      "command = []", "command = [\"btm\"]\nsize = \"0x28\"",
      "command = [\"btm\"]\npersistent = \"true\"",
      "command = [\"btm\"]\nenv = { PATH = 1 }",
      "command = [\"btm\"]\nunknown = true",
      "command = [\"btm\"]\ntext = \"both\"",
      "cwd = \"~\"",
    ] {
      let config = ConfigLoader.parseLayers([
        .init(text: "[popup.monitor]\ncommand = [\"btm\"]\npersistent = true"),
        .init(text: "[popup.monitor]\n" + body),
      ])
      XCTAssertFalse(config.diagnostics.isEmpty, body)
      XCTAssertTrue(config.invalidPopupNames.contains("monitor"), body)
      XCTAssertEqual(config.terminalPopups["monitor"]?.command, ["btm"], body)
      XCTAssertEqual(config.terminalPopups["monitor"]?.lifecycle, .persistent, body)
      XCTAssertTrue(config.terminalPopupNames.contains("monitor"), body)
    }
  }

  func testTerminalPathsAndEnvironmentFollowDefiningLayer() {
    let config = ConfigLoader.parseLayers([
      .init(
        text: """
          [popup.editor]
          command = ["./editor", "--empty"]
          cwd = "./work"
          env = { LANG = "en_US.UTF-8" }
          size = "120x32"
          """, sourceURL: URL(fileURLWithPath: "/tmp/base/flash.toml")),
      .init(
        text: "[statusbar]\nenabled = true", sourceURL: URL(fileURLWithPath: "/tmp/user/flash.toml")
      ),
    ])
    let terminal = config.terminalPopups["editor"]
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(terminal?.command, ["/tmp/base/editor", "--empty"])
    XCTAssertEqual(terminal?.workingDirectory, "/tmp/base/work")
    XCTAssertEqual(terminal?.environment, ["LANG": "en_US.UTF-8"])
    XCTAssertEqual(terminal?.size.description, "120x32")
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
        [popup.editor]
        command = ["/bin/zsh"]
        cwd = "\(directory)"
        """, sourceURL: URL(fileURLWithPath: "/tmp/config/flash.toml"))
      XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
      let terminal = try XCTUnwrap(config.terminalPopups["editor"])
      let launch = StatusTerminalRegistry.configuration(for: terminal, environment: [:])
      XCTAssertEqual(launch.workingDirectory, expected, directory)
    }
  }

  func testValidReplacementClearsInvalidMarkerAndUpdatesPersistence() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[popup.editor]\ncommand = []"),
      .init(text: "[popup.editor]\ncommand = [\"/bin/zsh\"]\npersistent = true"),
    ])
    XCTAssertTrue(config.invalidPopupNames.isEmpty)
    XCTAssertEqual(config.terminalPopups["editor"]?.lifecycle, .persistent)
  }

  func testMalformedTablesAndNamesAreDiagnosed() {
    for text in [
      "popup = 42", "[popup]\nshell = true", "[popup.\"a b\"]\ncommand = [\"/bin/zsh\"]",
      "[popup.\"\"]\ncommand = [\"/bin/zsh\"]", "[[popup.list]]\ncommand = [\"/bin/zsh\"]",
    ] {
      let config = ConfigLoader.parse(text)
      XCTAssertFalse(config.diagnostics.isEmpty, text)
      XCTAssertEqual(Set(config.popups.keys), ["shell"], text)
    }
    let config = ConfigLoader.parse("[popup.editor]\ncommand = [\"/bin/zsh\"]\npersistent = 1")
    XCTAssertTrue(
      config.diagnostics.contains {
        $0.message.contains("popup.editor.persistent must be true or false")
      })
    XCTAssertTrue(config.invalidPopupNames.contains("editor"))
  }

  func testRetiredTerminalKeysPointAtTheirReplacements() {
    let config = ConfigLoader.parse(
      """
      [popup.feed]
      command = ["newsboat"]
      working_directory = "."
      """)
    XCTAssertTrue(
      config.diagnostics.contains {
        $0.message == "popup.feed: unknown key 'working_directory' — did you mean 'cwd'?"
      }, "\(config.diagnostics)")
    for key in ["columns", "rows"] {
      let sized = ConfigLoader.parse("[popup.feed]\ncommand = [\"newsboat\"]\n\(key) = 30")
      XCTAssertTrue(
        sized.diagnostics.contains {
          $0.message == "popup.feed: unknown key '\(key)' — did you mean 'size'?"
        }, "\(sized.diagnostics)")
    }
  }

  func testResolvedDiagnosticsDoNotExposeTerminalCommandsOrEnvironment() {
    let config = ConfigLoader.parse(
      """
      [popup.editor]
      command = ["/bin/zsh", "private-argument"]
      env = { TOKEN = "private-secret" }
      persistent = true
      """)
    XCTAssertFalse(config.resolvedConfigJSON.contains("private-argument"))
    XCTAssertFalse(config.resolvedConfigJSON.contains("private-secret"))
    XCTAssertTrue(config.resolvedConfigJSON.contains("persistent"))
  }
}
