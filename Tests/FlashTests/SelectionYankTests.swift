import AppKit
import XCTest

@testable import flash

final class SelectionYankTests: XCTestCase {
  private let input = SelectionYankInputSnapshot.capture { _ in 10 }
  func testEveryRegisterClearsOnlyAfterItsCopyHasCommitted() {
    for register: String? in [nil, "\"", "+", "*", "0", "a", "A", "5", "_"] {
      let pasteboard = NSPasteboard(name: .init("flash-yank-\(UUID().uuidString)"))
      defer { pasteboard.releaseGlobally() }
      let store = RegisterStore(pasteboard: pasteboard)
      store.write("before", register: "a")
      let beforeChange = pasteboard.changeCount
      let request = SelectionYankRequest(
        targetPID: 42, register: register, commandToken: 7, input: input)
      var cleared = false
      XCTAssertTrue(
        request.complete(text: "copied", write: store.write) {
          cleared = true
          // The clipboard is the unnamed register: a named yank leaves it.
          let clipboard = RegisterStore.isSystemClipboard(register)
          XCTAssertEqual(store.read(register: nil), clipboard ? "copied" : nil)
          if let register, !clipboard, register != "_" {
            let expected = register == "A" ? "beforecopied" : "copied"
            XCTAssertEqual(store.read(register: register), expected)
          }
        })
      XCTAssertTrue(cleared, "register \(register ?? "unnamed") must clear the copied selection")
      if register == "_" { XCTAssertEqual(pasteboard.changeCount, beforeChange) }
    }
  }

  func testFailedCopyDoesNotWriteOrClearTheSelection() {
    let request = SelectionYankRequest(targetPID: 42, register: "a", commandToken: 7, input: input)
    for text: String? in [nil, ""] {
      XCTAssertFalse(
        request.complete(text: text, write: { _, _ in XCTFail("no copy") }) {
          XCTFail("failed copy must leave the selection")
        })
    }
  }

  func testBlackHoleClearsWithoutTouchingTheClipboard() {
    let request = SelectionYankRequest(targetPID: 42, register: "_", commandToken: 7, input: input)
    var cleared = false
    XCTAssertTrue(
      request.complete(text: nil, write: { _, _ in XCTFail("black hole must not copy") }) {
        cleared = true
      })
    XCTAssertTrue(cleared)
  }

  func testDelayedYankDoesNotOwnAnotherAppOrANewerCommand() {
    let request = SelectionYankRequest(targetPID: 42, register: "a", commandToken: 7, input: input)
    XCTAssertTrue(request.owns(targetPID: 42, commandToken: 7, currentInput: input))
    XCTAssertFalse(request.owns(targetPID: 99, commandToken: 7, currentInput: input))
    XCTAssertFalse(request.owns(targetPID: 42, commandToken: 8, currentInput: input))
    XCTAssertFalse(request.owns(targetPID: nil, commandToken: 7, currentInput: input))
  }

  func testChangedTextOrSelectionRangeCancelsCapturedSelection() {
    let captured = TextSelectionIdentity(text: "same", range: NSRange(location: 4, length: 4))
    XCTAssertEqual(captured.state(comparedTo: captured), .unchanged)
    XCTAssertEqual(
      captured.state(comparedTo: .init(text: "other", range: captured.range)), .changed)
    XCTAssertEqual(
      captured.state(comparedTo: .init(text: "same", range: NSRange(location: 14, length: 4))),
      .changed)
    XCTAssertEqual(
      captured.state(comparedTo: .init(text: nil, range: NSRange(location: 8, length: 0))),
      .collapsed)
    XCTAssertEqual(
      captured.state(comparedTo: .init(text: nil, range: NSRange(location: 4, length: 0))),
      .changed)
  }

  func testClearingNeverSendsTerminalInputOrAnArrowForAnUnknownSelection() {
    let captured = TextSelectionIdentity(text: "copied", range: NSRange(location: 0, length: 6))
    XCTAssertFalse(SelectionYankRequest.permitsArrowFallback(isTerminal: true, selection: captured))
    XCTAssertTrue(SelectionYankRequest.permitsArrowFallback(isTerminal: false, selection: captured))
    XCTAssertFalse(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: false, selection: .init(text: nil, range: nil)))
  }

  func testFlashCapturePanelStillPermitsTheOriginalExternalTarget() {
    let request = SelectionYankRequest(targetPID: 42, register: nil, commandToken: 7, input: input)
    XCTAssertTrue(request.permitsFrontmost(42, flashPID: 1))
    XCTAssertTrue(request.permitsFrontmost(1, flashPID: 1))
    XCTAssertFalse(request.permitsFrontmost(99, flashPID: 1))
    XCTAssertFalse(request.permitsFrontmost(nil, flashPID: 1))
  }

  func testSuccessfulWebCopyCanClearWithoutAXSelectionAttributes() {
    XCTAssertTrue(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: false, selection: .init(text: nil, range: nil), copiedText: "web selection"))
    XCTAssertFalse(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: false, selection: .init(text: nil, range: nil), copiedText: ""))
    XCTAssertFalse(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: true, selection: .init(text: nil, range: nil), copiedText: "terminal selection")
    )
  }

  func testExplicitBlackHoleCanClearUnknownWebSelectionWithoutCopying() {
    XCTAssertTrue(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: false, selection: .init(text: nil, range: nil), discard: true))
    XCTAssertFalse(
      SelectionYankRequest.permitsArrowFallback(
        isTerminal: true, selection: .init(text: nil, range: nil), discard: true))
  }

  func testEverySelectionChangingHardwareEventRevokesTheYank() {
    let baseline = SelectionYankInputSnapshot.capture { _ in 10 }
    let request = SelectionYankRequest(
      targetPID: 42, register: nil, commandToken: 7, input: baseline)
    XCTAssertTrue(request.owns(targetPID: 42, commandToken: 7, currentInput: baseline))
    for event in SelectionYankInputSnapshot.eventTypes {
      let changed = SelectionYankInputSnapshot.capture { $0 == event ? 11 : 10 }
      XCTAssertFalse(
        request.owns(targetPID: 42, commandToken: 7, currentInput: changed),
        "event \(event.rawValue) must revoke selection ownership")
    }
  }

  func testReleasingTheYankKeyOrModifierDoesNotRevokeIt() {
    let baseline = SelectionYankInputSnapshot.capture { _ in 10 }
    let released = SelectionYankInputSnapshot.capture { event in
      event == .keyUp || event == .flagsChanged ? 11 : 10
    }
    XCTAssertEqual(baseline, released)
    XCTAssertFalse(SelectionYankInputSnapshot.eventTypes.contains(.keyUp))
    XCTAssertFalse(SelectionYankInputSnapshot.eventTypes.contains(.flagsChanged))
  }

}
