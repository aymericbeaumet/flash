import AppKit
import XCTest

@testable import flash

final class CommandValidationTests: XCTestCase {
  func testInvalidBuiltinArgumentsCannotBecomePluginCalls() {
    XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "terminal", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(topic: "mode", action: "leave", args: ["unexpected": "1"]))
    XCTAssertEqual(URLEventHandler.parse(topic: "app", action: "save", args: [:]), .save)
  }

  func testStraySubcommandsAndMalformedFlagsAreRejectedInMappings() {
    for tail in [["typo"], ["--"], ["--=value"], ["name=value"]] {
      XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "normal"] + tail))
    }
    XCTAssertNotNil(parseMappingCommand(argv: ["flash", "mode", "normal"]))
    XCTAssertNotNil(parseMappingCommand(argv: ["echo", "name=value"]))
  }

  func testConfigAcceptsPluginCommandsAndWarnsOnAOneWordPluginName() {
    let accepted = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<leader>c" = ["flash", "screenshot", "window"]
      """)
    XCTAssertTrue(accepted.loadingDiagnostics.isEmpty, "\(accepted.loadingDiagnostics)")
    XCTAssertTrue(
      accepted.mode.normal.contains {
        $0.action.command
          == .pluginCommand(command: "screenshot", subcommand: "window", args: [])
      })

    let oneWord = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+shift+[" = ["flash", "screenshot_window"]
      """)
    XCTAssertTrue(
      oneWord.loadingDiagnostics.contains {
        $0.message.contains("cmd+shift+[") && $0.message.contains("screenshot_window")
      })

    for action in [
      "[\"flash\", \"Not-A-Verb\"]", "{ command = [\"flash\", \"Not-A-Verb\"] }",
    ] {
      let config = ConfigLoader.parse("[mode.all.mappings]\n\"cmd+shift+[\" = \(action)")
      XCTAssertTrue(
        config.loadingDiagnostics.contains {
          $0.message.contains("cmd+shift+[") && $0.message.contains("Not-A-Verb")
        })
      XCTAssertTrue(config.loadingErrorAlertMessage?.contains("Not-A-Verb") == true)
    }
  }

  /// Without a resident, the CLI resolves the words itself to say why they
  /// name no command; with one, the resident resolves them (`CommandInvocationTests`).
  func testCLIRejectsInvalidArguments() {
    let notRunning = CommandInvocationTests.StubTransport().transport
    for args in [
      ["mode", "leave", "typo"], ["mode", "terminal", "--name="], ["screenshot"],
      ["screenshot", "not-a-subcommand"], ["screenshot_window"],
      // Every command is two words: the one-word forms are gone.
      ["mode_leave"], ["mode"], ["media", "volumedown"], ["caffeinate", "on", "--minutes=0"],
      ["audio", "output", "--device="],
      // A mark's letter is a `--letter=` argument of one ASCII letter or digit.
      ["mark", "set", "a"], ["mark", "set"], ["mark", "set", "--letter=ab"],
      ["mark", "jump", "--letter=é"],
    ] {
      XCTAssertEqual(FlashCLI.run(args: args, transport: notRunning), 2, "\(args)")
    }
  }
}
