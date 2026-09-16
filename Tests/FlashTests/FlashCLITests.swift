import AppKit
import XCTest

@testable import flash

final class FlashCLITests: XCTestCase {
  func testAutomationDenialPreservesItsErrorCodeInsteadOfClaimingInvalidArguments() {
    for status in [OSStatus(noErr), OSStatus(errAEEventNotPermitted)] {
      let result = FlashCLI.response(
        verb: "enter_normal_mode", status: status,
        reply: reply(error: Int32(errAEEventNotPermitted)))
      XCTAssertEqual(result.exitCode, 1)
      XCTAssertTrue(result.message?.contains("OSStatus=-1743") == true)
      XCTAssertFalse(result.message?.contains("Unsupported command") == true)
    }
  }

  func testTransportErrorTakesPrecedenceOverAnErrorReply() {
    let result = FlashCLI.response(
      verb: "enter_normal_mode", status: OSStatus(errAETimeout),
      reply: reply(error: Int32(errAEEventNotHandled), message: "unrelated reply"))
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.message?.contains("OSStatus=-1712") == true)
    XCTAssertFalse(result.message?.contains("unrelated reply") == true)
  }

  func testUnhandledNativeEventWithoutAResidentMessageIsATransportFailure() {
    let result = FlashCLI.response(
      verb: "enter_normal_mode", status: noErr,
      reply: reply(error: Int32(errAEEventNotHandled)))
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.message?.contains("OSStatus=-1708") == true)
  }

  func testExplicitResidentRejectionPreservesItsDiagnostic() {
    let message = URLEventHandler.rejectionMessage("flash missing_plugin_verb")
    let result = FlashCLI.response(
      verb: "missing_plugin_verb", status: noErr,
      reply: reply(error: Int32(errAEEventNotHandled), message: message))
    XCTAssertEqual(result.exitCode, 2)
    XCTAssertEqual(result.message, message)
  }

  func testSuccessfulResponseHasNoDiagnostic() {
    let result = FlashCLI.response(verb: "enter_normal_mode", status: noErr, reply: reply())
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertNil(result.message)
  }

  private func reply(error: Int32? = nil, message: String? = nil) -> NSAppleEventDescriptor {
    let reply = NSAppleEventDescriptor.appleEvent(
      withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
      targetDescriptor: nil, returnID: 0, transactionID: 0)
    if let error {
      reply.setParam(NSAppleEventDescriptor(int32: error), forKeyword: AEKeyword(keyErrorNumber))
    }
    if let message {
      reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: AEKeyword(keyErrorString))
    }
    return reply
  }
}
