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

  /// A full-screen app that hides the menu bar owns every chord: suspension
  /// unregisters the whole Carbon set, a table applied meanwhile registers
  /// nothing, and resuming registers the current table again.
  func testSuspensionReleasesEveryChordUntilItResumes() {
    _ = NSApplication.shared
    let coordinator = MappingsCoordinator()
    coordinator.start { _ in }
    defer { coordinator.setSuspended(true) }
    let chord = "ctrl+alt+shift+cmd+f19"
    var mode = Config.Mode()
    mode.all = [ModeMapping(key: chord, action: .flashCommand(.normalMode))]
    mode.recompileMappings()
    coordinator.apply(mode: mode)
    coordinator.apply(scope: .normal)
    drainMain()
    let registered = coordinator.registeredHotkeys
    XCTAssertTrue(registered.contains(chord))

    coordinator.setSuspended(true)
    XCTAssertEqual(coordinator.registeredHotkeys, [])
    coordinator.apply(mode: mode)
    coordinator.apply(scope: .insert)
    coordinator.apply(scope: .normal)
    drainMain()
    XCTAssertEqual(coordinator.registeredHotkeys, [], "nothing registers while suspended")

    coordinator.setSuspended(false)
    XCTAssertEqual(coordinator.registeredHotkeys, registered)
  }

  private func drainMain() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)
  }
}
