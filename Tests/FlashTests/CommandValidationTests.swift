import AppKit
import XCTest

@testable import flash

final class CommandValidationTests: XCTestCase {
  func testInvalidBuiltinArgumentsCannotBecomePluginCalls() {
    XCTAssertNil(URLEventHandler.parseOrPluginVerb(verb: "terminal_show", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parseOrPluginVerb(verb: "leave_mode", args: ["unexpected": "1"]))
    XCTAssertEqual(
      URLEventHandler.parseOrPluginVerb(verb: "app_save", args: [:]),
      .pluginVerb(name: "app_save", args: [:]))
  }

  func testStraySubcommandsAndMalformedFlagsAreRejectedInMappings() {
    for tail in [["typo"], ["--"], ["--=value"], ["name=value"]] {
      XCTAssertNil(parseMappingCommand(argv: ["flash", "enter_normal_mode"] + tail))
    }
    XCTAssertNotNil(parseMappingCommand(argv: ["flash", "enter_normal_mode"]))
    XCTAssertNotNil(parseMappingCommand(argv: ["echo", "name=value"]))
  }

  func testConfigWarningNamesTheInvalidCommandAndMapping() {
    for action in [
      "[\"flash\", \"does_not_exist\"]", "{ action = [\"flash\", \"does_not_exist\"] }",
    ] {
      let config = ConfigLoader.parse("[mode.all.mappings]\n\"cmd+shift+[\" = \(action)")
      XCTAssertTrue(
        config.loadingDiagnostics.contains {
          $0.message.contains("cmd+shift+[") && $0.message.contains("does_not_exist")
        })
      XCTAssertTrue(config.loadingErrorAlertMessage?.contains("does_not_exist") == true)
    }
  }

  func testCLIRejectsInvalidArgumentsWithoutSendingAnEvent() {
    XCTAssertEqual(FlashCLI.run(args: ["leave_mode", "typo"]), 2)
    XCTAssertEqual(FlashCLI.run(args: ["terminal_show", "--name="]), 2)
  }

  func testResidentRejectsMalformedBuiltinAndReturnsAnErrorReply() {
    var dispatched = false
    var rejected: [String] = []
    let handler = URLEventHandler(
      handler: { _ in
        dispatched = true
        return true
      },
      rejected: { rejected.append($0) })
    let reply = event("reply")
    handler.handleFlashEvent(
      event("leave_mode", arguments: "{\"unexpected\":\"1\"}"),
      withReplyEvent: reply)
    XCTAssertFalse(dispatched)
    XCTAssertEqual(rejected.count, 1)
    XCTAssertTrue(rejected.first?.contains("leave_mode") == true)
    XCTAssertNotEqual(reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, 0)
  }

  func testUnclaimedPluginCommandReturnsAnErrorReply() {
    let handler = URLEventHandler(handler: { _ in false }, rejected: { _ in })
    let reply = event("reply")
    handler.handleFlashEvent(event("missing_plugin_verb"), withReplyEvent: reply)
    XCTAssertTrue(
      reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue?
        .contains("missing_plugin_verb") == true)
  }

  private func event(_ verb: String, arguments: String = "{}") -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor.appleEvent(
      withEventClass: FlashCLI.appleEventClass, eventID: FlashCLI.appleEventID,
      targetDescriptor: nil, returnID: 0, transactionID: 0)
    event.setParam(NSAppleEventDescriptor(string: verb), forKeyword: FlashCLI.verbKey)
    event.setParam(NSAppleEventDescriptor(string: arguments), forKeyword: FlashCLI.argsKey)
    return event
  }
}
