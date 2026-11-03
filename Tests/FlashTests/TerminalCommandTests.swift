import XCTest

@testable import flash

final class TerminalCommandTests: XCTestCase {
  func testEnterTerminalModeIsRecognizedWithStrictArguments() {
    XCTAssertEqual(
      URLEventHandler.parse(topic: "mode", action: "terminal", args: [:]), .terminalMode(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(topic: "mode", action: "terminal", args: ["name": "terminal"]),
      .terminalMode(name: "terminal"))
    XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "terminal", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "terminal", args: ["name": " "]))
    XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "terminal", args: ["unknown": "x"]))
  }

  /// `mode terminal` replaced `popup_show`, and `mode leave` replaced
  /// `popup_dismiss`: the old names are unknown everywhere, with no alias.
  func testRetiredPopupShowAndDismissCommandsAreRejected() {
    for action in ["show", "dismiss"] {
      let verb = "popup \(action)"
      XCTAssertNil(URLEventHandler.parse(topic: "popup", action: action, args: [:]), verb)
      XCTAssertNil(
        URLEventHandler.parse(topic: "popup", action: action, args: ["name": "terminal"]), verb)
      XCTAssertNil(parseMappingCommand(argv: ["flash", "popup", action]), verb)
      XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(":" + verb), verb)
      XCTAssertFalse(URLEventHandler.usageText.contains("flash " + verb + "\n"), verb)
      XCTAssertFalse(URLEventHandler.usageText.contains("flash " + verb + " "), verb)
      let config = ConfigLoader.parse(
        """
        [mode.all.mappings]
        "alt+space" = ["flash", "popup", "\(action)"]
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
      ("mode terminal", .terminalMode(name: nil)),
      ("mode terminal --name=terminal", .terminalMode(name: "terminal")),
      ("popup restart --name=terminal", .popupRestart(name: "terminal")),
      ("popup quit", .popupQuit(name: nil)),
      ("popup quit --name=terminal", .popupQuit(name: "terminal")),
    ]
    for (text, command) in commands {
      XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(":" + text), command)
      let action = MappingCommand.flashCommand(command)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + text.split(separator: " ").map(String.init)), action)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
    }
    for invalid in [
      ":mode terminal terminal", ":mode terminal --name=",
      ":mode terminal --name=a --name=b", ":mode terminal --unknown=x",
      ":popup quit shell", ":popup quit --name=", ":popup quit --name=a --name=b",
      ":popup quit --unknown=x",
    ] {
      XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(invalid), invalid)
    }
  }

  func testPopupCommandsAppearInCompletionCatalogAndHelp() throws {
    let topics = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":pop", pluginCommands: [], pluginSubcommands: [:]))
    let topic = try XCTUnwrap(topics.items.first { $0.label == "popup" })
    XCTAssertEqual(topic.kind, .acceptsArgs)
    XCTAssertEqual(topic.insertion, "popup ")
    let popup = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":popup ", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(popup.prefix, ":popup ")
    XCTAssertEqual(popup.items.map(\.label), ["quit", "restart"])
    let mode = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":mode t", pluginCommands: [], pluginSubcommands: [:]))
    let terminal = try XCTUnwrap(mode.items.first { $0.label == "terminal" })
    for item in popup.items + [terminal] {
      XCTAssertEqual(item.kind, .pluginSubcommand, "\(item.label) runs bare on <CR>")
      XCTAssertEqual(item.insertion, item.label)
    }
    let app = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":app op", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertEqual(app.prefix, ":app ")
    XCTAssertEqual(app.query, "op")
    XCTAssertEqual(
      app.items.first { $0.label == "open" },
      .init(label: "open", insertion: "open ", kind: .acceptsArgs),
      "a required --name keeps the line open")
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    for name in ["mode terminal", "popup restart", "popup quit"] {
      XCTAssertTrue(catalog.contains { $0["name"] as? String == ":" + name })
      XCTAssertTrue(URLEventHandler.usageText.contains("flash " + name))
    }
    XCTAssertTrue(URLEventHandler.usageText.contains("flash mode terminal [--name=<popup>]"))
    XCTAssertTrue(FlashCLI.usage.contains("flash mode terminal --name="))
    let manual = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/commands.md")
    XCTAssertTrue(try String(contentsOf: manual, encoding: .utf8).contains("mode terminal"))
  }

  func testRestartTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(topic: "popup", action: "restart", args: [:]),
      .popupRestart(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(topic: "popup", action: "restart", args: ["name": "system"]),
      .popupRestart(name: "system"))
    XCTAssertNil(URLEventHandler.parse(topic: "popup", action: "restart", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(topic: "popup", action: "restart", args: ["unknown": "x"]))
  }

  func testQuitTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(topic: "popup", action: "quit", args: [:]),
      .popupQuit(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(topic: "popup", action: "quit", args: ["name": "system"]),
      .popupQuit(name: "system"))
    XCTAssertNil(URLEventHandler.parse(topic: "popup", action: "quit", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(topic: "popup", action: "quit", args: ["unknown": "x"]))
  }
}
