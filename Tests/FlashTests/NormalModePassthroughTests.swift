import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class NormalModePassthroughTests: XCTestCase {
  func testDefaultPassthroughCapturesAllUnmappedKeysAndModifiers() {
    let mode = Config.default.mode
    XCTAssertTrue(mode.normalPassthroughKeys.isEmpty)
    XCTAssertTrue(mode.normalPassthroughModifiers.isEmpty)
    for flags: CGEventFlags in [[], .maskShift, .maskCommand, .maskControl, .maskAlternate] {
      XCTAssertTrue(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal,
          inputMode: .normal,
          modifierFlags: flags,
          passthroughModifierFlags: KeyModifier.cgEventFlags(mode.normalPassthroughModifiers)))
    }
  }

  func testSlashIsConsumedWhenUnmappedAndDispatchesFindWhenMapped() {
    XCTAssertEqual(interpret("/", mappings: []), .consume)
    XCTAssertEqual(interpret("/", mappings: Config.default.mode.normal).command, .find)
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(flashMode: .normal, inputMode: .normal))
  }

  func testUnmappedSequenceSuffixIsConsumedWithNoPassthrough() {
    XCTAssertEqual(interpret("/", pending: "g", mappings: []), .consume)
    XCTAssertEqual(
      interpret("/", pending: "g", mappings: Config.default.mode.normal).command, .find)
  }

  func testConfiguredPassthroughYieldsOnlyUnmappedInput() {
    for mapped in [false, true] {
      XCTAssertEqual(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal, inputMode: .normal,
          hasMapping: mapped, isPassthroughKey: true), mapped)
      XCTAssertEqual(
        KeyboardCaptureTap.shouldSwallow(
          flashMode: .normal, inputMode: .normal,
          modifierFlags: .maskCommand, hasMapping: mapped,
          passthroughModifierFlags: .maskCommand), mapped)
    }
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal, inputMode: .normal,
        modifierFlags: .maskShift, passthroughModifierFlags: .maskCommand))
  }

  func testSlashMappingOverridesConfiguredPassthroughAfterInvalidSequence() {
    let recognized = NormalModeInterpreter.recognizesPhysicalKey(
      pending: "g", repeatAnchor: nil,
      virtualKey: UInt32(kVK_ANSI_Slash), modifierFlags: [],
      mappings: CompiledMappings(Config.default.mode.normal))
    XCTAssertTrue(recognized)
    XCTAssertTrue(
      KeyboardCaptureTap.shouldSwallow(
        flashMode: .normal, inputMode: .normal,
        hasMapping: recognized, isPassthroughKey: true))
  }

  private func interpret(
    _ characters: String, pending: String = "", mappings: [ModeMapping]
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: UInt16(kVK_ANSI_Slash), modifierFlags: [],
      characters: characters, charactersIgnoringModifiers: characters,
      mappings: CompiledMappings(mappings))
  }

  func testPassthroughFollowsOnlyEditableFocus() {
    for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
      XCTAssertTrue(NormalModeDispatcher.passthroughFocusIsEditable(role: role, subrole: nil), role)
    }
    XCTAssertTrue(
      NormalModeDispatcher.passthroughFocusIsEditable(role: "AXGroup", subrole: "AXContentEditable"))
    for role in ["AXWindow", "AXWebArea", "AXButton", "AXList", "AXGroup"] {
      XCTAssertFalse(NormalModeDispatcher.passthroughFocusIsEditable(role: role, subrole: nil), role)
    }
    XCTAssertFalse(NormalModeDispatcher.passthroughFocusIsEditable(role: nil, subrole: nil))
  }
}
