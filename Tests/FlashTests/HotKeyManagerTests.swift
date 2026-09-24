import Carbon.HIToolbox
import XCTest

@testable import flash

final class HotKeyManagerTests: XCTestCase {
  func testForeignHandlerDeclinesEventBeforeOwnerDispatchesIt() throws {
    let all = HotKeyEventRouter()
    let scoped = HotKeyEventRouter()
    var allFires = 0
    var scopedFires = 0
    let allID = all.register { allFires += 1 }
    let scopedID = scoped.register { scopedFires += 1 }
    XCTAssertNotEqual(allID.id, scopedID.id)

    let allEvent = try event(id: allID)
    defer { ReleaseEvent(allEvent) }
    XCTAssertEqual(scoped.handle(event: allEvent), OSStatus(eventNotHandledErr))
    XCTAssertEqual(all.handle(event: allEvent), noErr)
    XCTAssertEqual(allFires, 1)
    XCTAssertEqual(scopedFires, 0)

    let scopedEvent = try event(id: scopedID)
    defer { ReleaseEvent(scopedEvent) }
    XCTAssertEqual(all.handle(event: scopedEvent), OSStatus(eventNotHandledErr))
    XCTAssertEqual(scoped.handle(event: scopedEvent), noErr)
    XCTAssertEqual(scopedFires, 1)
  }

  func testForeignSignatureAndUnknownIDAreNotHandled() throws {
    let router = HotKeyEventRouter()
    var fires = 0
    let id = router.register { fires += 1 }
    let foreign = try event(id: EventHotKeyID(signature: id.signature ^ 1, id: id.id))
    let unknown = try event(id: EventHotKeyID(signature: id.signature, id: 0))
    defer {
      ReleaseEvent(foreign)
      ReleaseEvent(unknown)
    }
    XCTAssertEqual(router.handle(event: foreign), OSStatus(eventNotHandledErr))
    XCTAssertEqual(router.handle(event: unknown), OSStatus(eventNotHandledErr))
    XCTAssertEqual(fires, 0)
  }

  func testRemovedRegistrationCannotDispatchAfterReload() throws {
    let router = HotKeyEventRouter()
    var fires = 0
    let oldID = router.register { fires += 1 }
    let oldEvent = try event(id: oldID)
    defer { ReleaseEvent(oldEvent) }
    router.removeAll()
    let newID = router.register { fires += 1 }
    XCTAssertNotEqual(oldID.id, newID.id)
    XCTAssertEqual(router.handle(event: oldEvent), OSStatus(eventNotHandledErr))

    router.remove(id: newID.id)
    let removedEvent = try event(id: newID)
    defer { ReleaseEvent(removedEvent) }
    XCTAssertEqual(router.handle(event: removedEvent), OSStatus(eventNotHandledErr))
    XCTAssertEqual(fires, 0)
  }

  func testMissingEventOrHotkeyParameterIsNotHandled() throws {
    let router = HotKeyEventRouter()
    let missingParameter = try event(id: nil)
    defer { ReleaseEvent(missingParameter) }
    XCTAssertEqual(router.handle(event: nil), OSStatus(eventNotHandledErr))
    XCTAssertEqual(router.handle(event: missingParameter), OSStatus(eventNotHandledErr))
  }

  func testReconcileTouchesOnlyChordsThatDiffer() {
    let manager = HotKeyManager()
    defer { manager.unregisterAll() }
    let a = ParsedHotkey(modifiers: UInt32(cmdKey | optionKey | controlKey), virtualKey: 0x7A)
    let b = ParsedHotkey(modifiers: UInt32(cmdKey | optionKey | controlKey), virtualKey: 0x78)
    let c = ParsedHotkey(modifiers: UInt32(cmdKey | optionKey | controlKey), virtualKey: 0x63)
    var fired: [ParsedHotkey] = []

    let first = manager.reconcile(desired: [a, b]) { fired.append($0) }
    XCTAssertEqual(first.added, 2)
    XCTAssertEqual(first.removed, 0)
    XCTAssertEqual(manager.registeredChords, [a, b])

    let second = manager.reconcile(desired: [b, c]) { fired.append($0) }
    XCTAssertEqual(second.added, 1)
    XCTAssertEqual(second.removed, 1)
    XCTAssertEqual(manager.registeredChords, [b, c])

    let unchanged = manager.reconcile(desired: [b, c]) { fired.append($0) }
    XCTAssertEqual(unchanged.added, 0)
    XCTAssertEqual(unchanged.removed, 0)
    XCTAssertTrue(fired.isEmpty)
  }

  func testModeMappingParsesNativeHotkeyOnce() {
    let mapping = ModeMapping(key: "ctrl-d", action: .shellCommand(["true"]))
    XCTAssertEqual(mapping.nativeHotkey, ModeMapping.parseNativeHotkey("ctrl+d"))
    XCTAssertNil(ModeMapping(key: "gi", action: .shellCommand(["true"])).nativeHotkey)
  }

  private func event(id: EventHotKeyID?) throws -> EventRef {
    var event: EventRef?
    XCTAssertEqual(
      CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event),
      noErr)
    let result = try XCTUnwrap(event)
    if var id {
      XCTAssertEqual(
        SetEventParameter(
          result, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
          MemoryLayout<EventHotKeyID>.size, &id), noErr)
    }
    return result
  }
}
