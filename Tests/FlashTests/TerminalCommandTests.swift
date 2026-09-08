import XCTest

@testable import flash

final class TerminalCommandTests: XCTestCase {
  func testShowAndDismissAreRecognizedWithStrictArguments() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_show", args: [:]), .terminalShow(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_show", args: ["name": "shell"]),
      .terminalShow(name: "shell"))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_show", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_show", args: ["unknown": "x"]))
    XCTAssertEqual(URLEventHandler.parse(verb: "terminal_dismiss", args: [:]), .terminalDismiss)
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_dismiss", args: ["name": "shell"]))
  }

  func testTerminalCommandsParseFromCommandLineAndMappingActions() {
    let commands: [(String, URLCommand)] = [
      ("terminal_show", .terminalShow(name: nil)),
      ("terminal_show --name=shell", .terminalShow(name: "shell")),
      ("terminal_dismiss", .terminalDismiss),
      ("terminal_restart --name=shell", .terminalRestart(name: "shell")),
    ]
    for (text, command) in commands {
      XCTAssertEqual(NormalModeDispatcher.commandLineTerminalCommand(":" + text), command)
      let action = MappingCommand.flashCommand(command)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + text.split(separator: " ").map(String.init)), action)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
    }
    for invalid in [
      ":terminal_show shell", ":terminal_show --name=", ":terminal_show --name=a --name=b",
      ":terminal_dismiss --name=shell",
    ] {
      XCTAssertNil(NormalModeDispatcher.commandLineTerminalCommand(invalid), invalid)
    }
  }

  func testTerminalCommandsAppearInCompletionCatalogAndHelp() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":terminal_", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(
      Set(context.items.map(\.label)), ["terminal_show", "terminal_dismiss", "terminal_restart"])
    XCTAssertEqual(context.items.first { $0.label == "terminal_dismiss" }?.kind, .terminal)
    XCTAssertEqual(context.items.first { $0.label == "terminal_show" }?.kind, .acceptsArgs)
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    for name in ["terminal_show", "terminal_dismiss", "terminal_restart"] {
      XCTAssertTrue(catalog.contains { $0["name"] as? String == ":" + name })
      XCTAssertTrue(
        NormalModeDispatcher.helpText(config: Config(), showModes: true).contains(":" + name))
      XCTAssertTrue(URLEventHandler.usageText.contains("flash " + name))
    }
  }

  func testRestartTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_restart", args: [:]),
      .terminalRestart(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_restart", args: ["name": "system"]),
      .terminalRestart(name: "system"))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_restart", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_restart", args: ["unknown": "x"]))
  }
}
