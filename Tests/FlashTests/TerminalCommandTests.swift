import XCTest

@testable import flash

final class TerminalCommandTests: XCTestCase {
  func testEnterTerminalModeIsRecognizedWithStrictArguments() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "enter_terminal_mode", args: [:]), .terminalMode(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "enter_terminal_mode", args: ["name": "terminal"]),
      .terminalMode(name: "terminal"))
    XCTAssertNil(URLEventHandler.parse(verb: "enter_terminal_mode", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "enter_terminal_mode", args: ["name": " "]))
    XCTAssertNil(URLEventHandler.parse(verb: "enter_terminal_mode", args: ["unknown": "x"]))
  }

  /// `enter_terminal_mode` replaced `popup_show`, and `leave_mode` replaced
  /// `popup_dismiss`: the old names are unknown everywhere, with no alias.
  func testRetiredPopupShowAndDismissVerbsAreRejected() {
    for verb in ["popup_show", "popup_dismiss"] {
      XCTAssertNil(URLEventHandler.parse(verb: verb, args: [:]), verb)
      XCTAssertNil(URLEventHandler.parse(verb: verb, args: ["name": "terminal"]), verb)
      XCTAssertNil(parseMappingCommand(argv: ["flash", verb]), verb)
      XCTAssertNil(NormalModeDispatcher.commandLinePopupCommand(":" + verb), verb)
      XCTAssertNil(NormalModeDispatcher.popupCommandSyntax[verb], verb)
      XCTAssertFalse(URLEventHandler.usageText.contains("flash " + verb + "\n"), verb)
      XCTAssertFalse(URLEventHandler.usageText.contains("flash " + verb + " "), verb)
      let config = ConfigLoader.parse(
        """
        [mode.all.mappings]
        "alt+space" = ["flash", "\(verb)"]
        """)
      XCTAssertTrue(
        config.loadingDiagnostics.contains { $0.message.contains(verb) },
        "\(config.loadingDiagnostics.map(\.message))")
      XCTAssertFalse(config.mode.all.contains { $0.key == "alt+space" }, verb)
      XCTAssertEqual(config.prewarmedPopupNames, [], verb)
    }
  }

  func testPopupCommandsParseFromCommandLineAndMappingActions() {
    let commands: [(String, URLCommand)] = [
      ("enter_terminal_mode", .terminalMode(name: nil)),
      ("enter_terminal_mode --name=terminal", .terminalMode(name: "terminal")),
      ("popup_restart --name=terminal", .popupRestart(name: "terminal")),
      ("popup_quit", .popupQuit(name: nil)),
      ("popup_quit --name=terminal", .popupQuit(name: "terminal")),
    ]
    for (text, command) in commands {
      XCTAssertEqual(NormalModeDispatcher.commandLinePopupCommand(":" + text), command)
      let action = MappingCommand.flashCommand(command)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + text.split(separator: " ").map(String.init)), action)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
    }
    for invalid in [
      ":enter_terminal_mode terminal", ":enter_terminal_mode --name=",
      ":enter_terminal_mode --name=a --name=b", ":enter_terminal_mode --unknown=x",
      ":popup_quit shell", ":popup_quit --name=", ":popup_quit --name=a --name=b",
      ":popup_quit --unknown=x",
    ] {
      XCTAssertNil(NormalModeDispatcher.commandLinePopupCommand(invalid), invalid)
    }
  }

  func testPopupCommandsAppearInCompletionCatalogAndHelp() throws {
    let popup = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":popup_", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(Set(popup.items.map(\.label)), ["popup_restart", "popup_quit"])
    let terminal = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":enter_t", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(terminal.items.map(\.label), ["enter_terminal_mode"])
    for item in popup.items + terminal.items {
      XCTAssertEqual(item.kind, .acceptsArgs, item.label)
      XCTAssertEqual(item.insertion, item.label + " ")
    }
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      ":" = ["flash", "enter_command_mode"]
      """)
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    for name in ["enter_terminal_mode", "popup_restart", "popup_quit"] {
      XCTAssertTrue(catalog.contains { $0["name"] as? String == ":" + name })
      XCTAssertTrue(
        NormalModeDispatcher.helpText(config: config, showModes: true).contains(":" + name))
      XCTAssertTrue(URLEventHandler.usageText.contains("flash " + name))
    }
    XCTAssertTrue(URLEventHandler.usageText.contains("flash enter_terminal_mode [--name=<popup>]"))
    XCTAssertTrue(FlashCLI.usage.contains("flash enter_terminal_mode --name="))
    XCTAssertTrue(URLEventHandler.helpTopic.body.contains("enter_terminal_mode"))
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
