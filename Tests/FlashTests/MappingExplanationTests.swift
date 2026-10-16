import XCTest

@testable import flash

/// The mappings-page `?` names what that binding does, including its flags.
final class MappingExplanationTests: XCTestCase {
  func testArrowExplanationsNameTheDirectionAndShift() {
    XCTAssertEqual(
      URLCommand.arrow(direction: .left, shift: false).explanation,
      "Posts the Left arrow.")
    XCTAssertEqual(
      URLCommand.arrow(direction: .left, shift: true).explanation,
      "Posts Shift+Left.")
    XCTAssertEqual(
      URLCommand.arrow(direction: .down, shift: false).explanation,
      "Posts the Down arrow.")
    XCTAssertNotEqual(
      URLCommand.arrow(direction: .up, shift: false).explanation,
      URLCommand.arrow(direction: .up, shift: true).explanation)
  }

  func testSystemAndFunctionKeysNameThePrintedAction() {
    XCTAssertEqual(
      URLCommand.systemKey(.brightnessUp).explanation,
      "Raises the display brightness.")
    XCTAssertEqual(
      URLCommand.systemKey(.volumeDown).explanation,
      "Lowers the volume.")
    XCTAssertEqual(URLCommand.functionKey(12).explanation, "Sends F12 to the focused app.")
  }

  func testWindowMoveNamesTheSlotAndTheDisplay() {
    XCTAssertEqual(
      URLCommand.moveWindow(MoveWindowParams(layout: .position(.leftHalf), screen: 0)).explanation,
      "Moves the focused window to the left half of the screen.")
    XCTAssertEqual(
      URLCommand.moveWindow(MoveWindowParams(layout: .position(.leftHalf), screen: 1)).explanation,
      "Moves the focused window to the left half of the next display.")
  }

  func testMouseExplanationsNameTheGesture() {
    XCTAssertEqual(
      URLCommand.mouseTarget(.click(.leftClick, modifiers: [])).explanation,
      "Labels targets in the focused window and left-clicks the one you pick.")
    XCTAssertEqual(
      URLCommand.mouseTarget(.click(.rightClick, modifiers: [])).explanation,
      "Labels targets in the focused window and right-clicks the one you pick.")
    XCTAssertEqual(
      URLCommand.mouseBigram(.move).explanation,
      "Asks for a letter, then a two-character hint, and moves the pointer onto that glyph.")
    XCTAssertEqual(
      URLCommand.mouseGrid(.init(.click(.leftClick, modifiers: []), bisect: true)).explanation,
      "Opens the half-and-quadrant grid and left-clicks the cell you choose.")
  }

  func testShellMappingNamesTheProgram() {
    XCTAssertEqual(
      MappingCommand.shellCommand(["/bin/sh", "-c", "echo hi"]).explanation,
      "Runs /bin/sh -c echo hi.")
  }

  func testMappingsJSONCarriesTheExplanation() {
    var mode = Config().mode
    mode.hyper = [
      ModeMapping(key: "h", action: .flashCommand(.arrow(direction: .left, shift: false)))
    ]
    mode.recompileMappings()
    let row = NormalModeDispatcher.mappingsJSON(mode: mode).first {
      $0["scope"] == "hyper" && $0["key"] == "h"
    }
    XCTAssertEqual(row?["action"], "flash arrow --direction=left")
    XCTAssertEqual(row?["explanation"], "Posts the Left arrow.")
  }
}
