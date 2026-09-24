import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class KeyboardLayoutTests: XCTestCase {
  /// What a Russian (ЙЦУКЕН) source types on a few physical keys: the
  /// characters a key event carries while that source is selected.
  private let russian = KeyboardLayout(
    sourceID: "com.apple.keylayout.Russian",
    plain: [
      UInt16(kVK_ANSI_F): "а", UInt16(kVK_ANSI_G): "п", UInt16(kVK_ANSI_Q): "й",
      UInt16(kVK_ANSI_1): "1",
    ],
    shifted: [UInt16(kVK_ANSI_F): "А", UInt16(kVK_ANSI_G): "П", UInt16(kVK_ANSI_1): "!"])

  private func read(
    _ layout: KeyboardLayout?, keyCode: Int, flags: NSEvent.ModifierFlags = [],
    typed: String, unshifted: String? = nil
  ) -> KeyCharacters {
    KeyCharacters.read(
      layout: layout, keyCode: UInt16(keyCode), modifierFlags: flags, characters: typed,
      ignoringModifiers: typed, unshifted: { unshifted })
  }

  func testUSANSITableCoversTheRelocatedLetterAndDigitMap() {
    XCTAssertEqual(KeyboardLayout.usANSI.character(keyCode: UInt16(kVK_ANSI_F), shift: false), "f")
    XCTAssertEqual(KeyboardLayout.usANSI.character(keyCode: UInt16(kVK_ANSI_F), shift: true), "F")
    XCTAssertEqual(KeyboardLayout.usANSI.character(keyCode: UInt16(kVK_ANSI_1), shift: true), "!")
    XCTAssertEqual(
      KeyboardLayout.usANSI.character(keyCode: UInt16(kVK_ANSI_Semicolon), shift: false), ";")
    XCTAssertNil(KeyboardLayout.usANSI.character(keyCode: UInt16(kVK_Return), shift: false))
    XCTAssertNil(KeyboardLayout.usANSI.character(keyCode: 200, shift: false))
    XCTAssertEqual(KeyboardLayout.usANSILetterOrDigit(UInt16(kVK_ANSI_I)), "i")
    XCTAssertEqual(KeyboardLayout.usANSILetterOrDigit(UInt16(kVK_ANSI_0)), "0")
    XCTAssertNil(KeyboardLayout.usANSILetterOrDigit(UInt16(kVK_ANSI_Semicolon)))
    XCTAssertNil(KeyboardLayout.usANSILetterOrDigit(UInt16(kVK_Tab)))
  }

  func testATableReplacesTheTypedCharactersOfAPrintableKey() {
    // A Russian source types "а" on the F key; against US-ANSI it reads `f`.
    let keys = read(.usANSI, keyCode: kVK_ANSI_F, typed: "а")
    XCTAssertEqual(keys, KeyCharacters(characters: "f", ignoringModifiers: "f", unshifted: "f"))
    let shifted = read(.usANSI, keyCode: kVK_ANSI_F, flags: [.shift], typed: "А")
    XCTAssertEqual(shifted.characters, "F")
    XCTAssertEqual(shifted.ignoringModifiers, "F")
    XCTAssertEqual(shifted.unshifted, "f")
  }

  func testKeysATableDoesNotTypeKeepTheEventsOwnCharacters() {
    XCTAssertEqual(read(.usANSI, keyCode: kVK_Return, typed: "\r").characters, "\r")
    XCTAssertEqual(read(.usANSI, keyCode: kVK_Escape, typed: "\u{1b}").ignoringModifiers, "\u{1b}")
  }

  func testNoTableKeepsTheTypedCharactersAndReadsUnshiftedOnlyUnderShift() {
    var unshiftedReads = 0
    let plain = KeyCharacters.read(
      layout: nil, keyCode: UInt16(kVK_ANSI_F), modifierFlags: [], characters: "f",
      ignoringModifiers: "f",
      unshifted: {
        unshiftedReads += 1
        return "f"
      })
    XCTAssertEqual(plain, KeyCharacters(characters: "f", ignoringModifiers: "f", unshifted: nil))
    XCTAssertEqual(unshiftedReads, 0)
    let shifted = KeyCharacters.read(
      layout: nil, keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.shift], characters: "!",
      ignoringModifiers: "!",
      unshifted: {
        unshiftedReads += 1
        return "1"
      })
    XCTAssertEqual(shifted.unshifted, "1")
    XCTAssertEqual(unshiftedReads, 1)
  }

  func testAutoTranslatesOnlyWhenTheCurrentSourceIsNotASCIICapable() {
    var asciiReads = 0
    let latin = KeyboardLayout.reference(
      setting: .auto, currentIsASCIICapable: true,
      asciiCapableLayout: {
        asciiReads += 1
        return .usANSI
      }, namedLayout: { _ in nil })
    XCTAssertNil(latin.table)
    XCTAssertEqual(asciiReads, 0, "an ASCII-capable source types what the labels show")

    let colemak = KeyboardLayout(
      sourceID: "com.apple.keylayout.Colemak", plain: [UInt16(kVK_ANSI_E): "f"], shifted: [:])
    let cyrillic = KeyboardLayout.reference(
      setting: .auto, currentIsASCIICapable: false,
      asciiCapableLayout: { colemak }, namedLayout: { _ in nil })
    XCTAssertEqual(cyrillic.table, colemak)
    XCTAssertNil(cyrillic.missingSourceID)

    let fallback = KeyboardLayout.reference(
      setting: .auto, currentIsASCIICapable: false,
      asciiCapableLayout: { nil }, namedLayout: { _ in nil })
    XCTAssertEqual(fallback.table, .usANSI)
  }

  func testAnExplicitSourceAlwaysTranslatesAndFallsBackToUSANSI() {
    let reference = KeyboardLayout.reference(
      setting: .inputSource("com.apple.keylayout.Russian"), currentIsASCIICapable: true,
      asciiCapableLayout: { nil },
      namedLayout: { $0 == "com.apple.keylayout.Russian" ? self.russian : nil })
    XCTAssertEqual(reference.table, russian)

    let missing = KeyboardLayout.reference(
      setting: .inputSource("com.example.keylayout.Gone"), currentIsASCIICapable: true,
      asciiCapableLayout: { nil }, namedLayout: { _ in nil })
    XCTAssertEqual(missing.table, .usANSI)
    XCTAssertEqual(missing.missingSourceID, "com.example.keylayout.Gone")
  }

  func testSettingParsesAutoOrAnInputSourceID() {
    XCTAssertEqual(KeyboardLayout.Setting("auto"), .auto)
    XCTAssertEqual(
      KeyboardLayout.Setting("com.apple.keylayout.US"), .inputSource("com.apple.keylayout.US"))
    for invalid in ["", "US", " com.apple.keylayout.US", "com.apple.keylayout.US\n", "Auto"] {
      XCTAssertNil(KeyboardLayout.Setting(invalid), invalid)
    }
  }

  func testTypableCharactersAreEveryPlainAndShiftedCharacter() {
    XCTAssertEqual(russian.typableCharacters, ["а", "п", "й", "1", "А", "П", "!"])
    XCTAssertEqual(russian.unshiftedCharacters, ["а", "п", "й", "1"])
    XCTAssertTrue(KeyboardLayout.usANSI.typableCharacters.isSuperset(of: Set("asdfghjkl;12345")))
  }

  func testTranslatingTheInstalledUSLayoutMatchesTheBuiltInTable() throws {
    guard let us = InputSources.layout(id: "com.apple.keylayout.US") else {
      throw XCTSkip("com.apple.keylayout.US is not installed")
    }
    for code in [kVK_ANSI_A, kVK_ANSI_F, kVK_ANSI_Q, kVK_ANSI_1, kVK_ANSI_Slash] {
      for shift in [false, true] {
        XCTAssertEqual(
          us.character(keyCode: UInt16(code), shift: shift),
          KeyboardLayout.usANSI.character(keyCode: UInt16(code), shift: shift),
          "key code \(code) shift=\(shift)")
      }
    }
    XCTAssertNil(us.character(keyCode: UInt16(kVK_Return), shift: false))
  }
}
