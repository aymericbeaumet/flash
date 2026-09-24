import AppKit
import XCTest

@testable import flash

final class StatusPopupSnapshotTests: XCTestCase {
  func testFreezeFinishesActiveWriteAndCancelsQueuedHoverPublication() throws {
    let fileQueue = DispatchQueue(label: "test.popup-snapshot")
    let snapshot = StatusPopupSnapshot(data: Data("original".utf8), fileQueue: fileQueue)
    defer { snapshot.close() }
    let initial = expectation(description: "initial file")
    snapshot.write { result in
      XCTAssertEqual(try? result.get(), true)
      initial.fulfill()
    }
    wait(for: [initial], timeout: 2)

    fileQueue.suspend()
    snapshot.data = Data("active".utf8)
    var publications: [String] = []
    snapshot.publish { _ in publications.append("active") }
    snapshot.data = Data("queued".utf8)
    snapshot.publish { _ in publications.append("queued") }
    var didFreeze = false
    let frozen = expectation(description: "freeze barrier")
    snapshot.freeze { changed in
      didFreeze = true
      XCTAssertTrue(changed)
      XCTAssertEqual(try? String(contentsOf: snapshot.fileURL), "active")
      XCTAssertEqual(publications, ["active"])
      frozen.fulfill()
    }
    XCTAssertFalse(didFreeze, "Focus must wait for the active file write")
    fileQueue.resume()
    wait(for: [frozen], timeout: 2)

    snapshot.data = Data("late hover".utf8)
    snapshot.publish { _ in XCTFail("A focused pager cannot publish hover data") }
    let idle = expectation(description: "late hover was ignored")
    fileQueue.async { DispatchQueue.main.async { idle.fulfill() } }
    wait(for: [idle], timeout: 2)
    XCTAssertEqual(try String(contentsOf: snapshot.fileURL), "active")

    snapshot.data = Data("explicit refresh".utf8)
    let refreshed = expectation(description: "explicit refresh while frozen")
    snapshot.write { result in
      XCTAssertEqual(try? result.get(), true)
      refreshed.fulfill()
    }
    wait(for: [refreshed], timeout: 2)
    XCTAssertEqual(try String(contentsOf: snapshot.fileURL), "explicit refresh")
  }

  func testFreezePreservesInitialPublicationBeforeFocus() {
    let fileQueue = DispatchQueue(label: "test.popup-startup")
    fileQueue.suspend()
    let snapshot = StatusPopupSnapshot(data: Data("initial".utf8), fileQueue: fileQueue)
    defer { snapshot.close() }
    var events: [String] = []
    snapshot.publish { _ in events.append("published") }
    let frozen = expectation(description: "initial publication then focus")
    snapshot.freeze { _ in
      XCTAssertEqual(events, ["published"])
      XCTAssertEqual(try? String(contentsOf: snapshot.fileURL), "initial")
      frozen.fulfill()
    }
    fileQueue.resume()
    wait(for: [frozen], timeout: 2)
  }

  func testDismissedPopupCannotAcquireFocusAfterItsFileWriteFinishes() {
    _ = NSApplication.shared
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var focusCalls = 0
    controller.willFocus = { focusCalls += 1 }
    controller.preview(
      StatusBarPopupRegion(rect: .zero, name: "details", content: "initial"),
      pointer: CGPoint(x: 100, y: 100),
      visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    controller.focus()
    XCTAssertTrue(controller.presentation.isFocused)
    XCTAssertEqual(focusCalls, 0)
    controller.dismiss()
    let settled = expectation(description: "cancelled focus settles")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { settled.fulfill() }
    wait(for: [settled], timeout: 2)
    XCTAssertEqual(focusCalls, 0)
  }
}
