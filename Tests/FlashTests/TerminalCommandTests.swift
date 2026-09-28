import XCTest

@testable import flash

final class TerminalCommandTests: XCTestCase {
  func testShowAndDismissAreRecognizedWithStrictArguments() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_show", args: [:]), .popupShow(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_show", args: ["name": "shell"]),
      .popupShow(name: "shell"))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_show", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_show", args: ["unknown": "x"]))
    XCTAssertEqual(URLEventHandler.parse(verb: "popup_dismiss", args: [:]), .popupDismiss)
    XCTAssertNil(URLEventHandler.parse(verb: "popup_dismiss", args: ["name": "shell"]))
  }

  func testPopupCommandsParseFromCommandLineAndMappingActions() {
    let commands: [(String, URLCommand)] = [
      ("popup_show", .popupShow(name: nil)),
      ("popup_show --name=shell", .popupShow(name: "shell")),
      ("popup_dismiss", .popupDismiss),
      ("popup_restart --name=shell", .popupRestart(name: "shell")),
      ("popup_quit", .popupQuit(name: nil)),
      ("popup_quit --name=shell", .popupQuit(name: "shell")),
    ]
    for (text, command) in commands {
      XCTAssertEqual(NormalModeDispatcher.commandLinePopupCommand(":" + text), command)
      let action = MappingCommand.flashCommand(command)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + text.split(separator: " ").map(String.init)), action)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
    }
    for invalid in [
      ":popup_show shell", ":popup_show --name=", ":popup_show --name=a --name=b",
      ":popup_dismiss --name=shell",
      ":popup_quit shell", ":popup_quit --name=", ":popup_quit --name=a --name=b",
      ":popup_quit --unknown=x",
    ] {
      XCTAssertNil(NormalModeDispatcher.commandLinePopupCommand(invalid), invalid)
    }
  }

  func testPopupCommandsAppearInCompletionCatalogAndHelp() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":popup_", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(
      Set(context.items.map(\.label)),
      ["popup_show", "popup_dismiss", "popup_restart", "popup_quit"])
    XCTAssertEqual(context.items.first { $0.label == "popup_dismiss" }?.kind, .terminal)
    XCTAssertEqual(context.items.first { $0.label == "popup_show" }?.kind, .acceptsArgs)
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      ":" = ["flash", "enter_command_mode"]
      """)
    XCTAssertEqual(context.items.first { $0.label == "popup_quit" }?.kind, .acceptsArgs)
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    for name in ["popup_show", "popup_dismiss", "popup_restart", "popup_quit"] {
      XCTAssertTrue(catalog.contains { $0["name"] as? String == ":" + name })
      XCTAssertTrue(
        NormalModeDispatcher.helpText(config: config, showModes: true).contains(":" + name))
      XCTAssertTrue(URLEventHandler.usageText.contains("flash " + name))
    }
  }

  func testRestartTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_restart", args: [:]),
      .popupRestart(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_restart", args: ["name": "system"]),
      .popupRestart(name: "system"))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_restart", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_restart", args: ["unknown": "x"]))
  }

  func testQuitTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_quit", args: [:]),
      .popupQuit(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "popup_quit", args: ["name": "system"]),
      .popupQuit(name: "system"))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_quit", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "popup_quit", args: ["unknown": "x"]))
  }
}
