import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class MappingsCoordinatorTests: XCTestCase {
  /// Chords the tap or the key window hand over are the user's physical
  /// presses: a held `ctrl+e` repeating every few milliseconds scrolls on
  /// every repeat, and a chord Flash just posted into another app cannot be
  /// echoed back through them, so neither Carbon heuristic applies.
  func testPhysicalChordsAreNeitherDebouncedNorTakenForEchoes() throws {
    let coordinator = MappingsCoordinator()
    var fired: [MappingCommand] = []
    coordinator.start { fired.append($0) }
    var mode = Config.Mode()
    mode.all = [ModeMapping(key: "ctrl+e", action: .flashCommand(.normalMode))]
    mode.recompileMappings()
    coordinator.apply(mode: mode)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
        windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
        isARepeat: false, keyCode: UInt16(kVK_ANSI_E)))
    XCTAssertTrue(coordinator.handle(event: event))
    XCTAssertTrue(coordinator.handle(event: event))
    XCTAssertEqual(fired.count, 2, "fast repeats of a physical chord both fire")
    coordinator.noteSyntheticKey(virtualKey: UInt32(kVK_ANSI_E), flags: .maskControl)
    XCTAssertTrue(coordinator.handle(event: event))
    XCTAssertEqual(fired.count, 3, "a physical press is never an echo")
  }
}
