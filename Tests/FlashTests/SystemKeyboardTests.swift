import AppKit
import XCTest

@testable import flash

/// The function-row keys Flash posts: playback is the keyboard's own media
/// keys, never a player's scripting. No test here posts a HID event.
final class SystemKeyboardTests: XCTestCase {
  /// Play/pause is the keyboard's own NX_KEYTYPE_PLAY, posted as a key down
  /// and a key up.
  func testMediaKeysPostADownUpPairThroughTheSeam() throws {
    let original = SystemKeyboard.eventPoster
    defer { SystemKeyboard.eventPoster = original }
    var posted: [CGEvent] = []
    SystemKeyboard.eventPoster = { posted.append($0) }
    SystemKeyboard.perform(.mediaPlay)
    XCTAssertEqual(posted.count, 2, "one NX_KEYDOWN + one NX_KEYUP")
    let data = try posted.map { try XCTUnwrap(NSEvent(cgEvent: $0)).data1 }
    XCTAssertEqual(data.map { $0 >> 16 }, [16, 16])
    XCTAssertEqual(data.map { ($0 >> 8) & 0xFF }, [0x0A, 0x0B])
  }

  func testPlaybackKeysAreCoreCommandsWithARequiredKey() throws {
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "key", "system", "--key=media_play"]),
      .flashCommand(.systemKey(.mediaPlay)))
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCoreCommand(":key system --key=media_next"),
      .systemKey(.mediaNext))
    XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(":key system"))
    let key = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":key sy", pluginCommands: [], pluginSubcommands: [:]))
    XCTAssertTrue(
      key.items.contains(.init(label: "system", insertion: "system ", kind: .acceptsArgs)),
      "a required --key keeps the line open")
  }
}
