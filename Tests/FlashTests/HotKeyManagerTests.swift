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
