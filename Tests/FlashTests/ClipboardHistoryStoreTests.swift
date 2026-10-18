import Foundation
import XCTest

@testable import flash

final class ClipboardHistoryStoreTests: XCTestCase {
  func testLegacyHistoryLoadsWhenCoreDirectoryAlreadyExists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let current = root.appendingPathComponent("clipboard")
    let legacy = root.appendingPathComponent("Plugins/clipboard/share")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: legacy.appendingPathComponent("images"), withIntermediateDirectories: true)
    let id = String(repeating: "a", count: 32)
    let json = "[{\"id\":\"\(id)\",\"kind\":\"text\",\"text\":\"old copy\"}]"
    try Data(json.utf8).write(to: legacy.appendingPathComponent("history.json"))
    try Data([1, 2, 3]).write(to: legacy.appendingPathComponent("images/\(id).png"))

    let store = ClipboardHistoryStore(directory: current, legacyDirectory: legacy)
    let loaded = expectation(description: "legacy history loaded")
    store.page(offset: 0) { page in
      XCTAssertEqual(page?.entries.map(\.value), ["old copy"])
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 3)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: current.appendingPathComponent("history.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: current.appendingPathComponent("images/\(id).png").path))
  }

  func testRecordDeduplicatesAndRespectsCapacity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardHistoryStore(directory: root, legacyDirectory: nil, capacity: 2)
    let first = ClipboardCapture.Item(
      kind: .text, text: "one", html: nil, image: nil, mime: nil, files: [], sha256: nil)
    let second = ClipboardCapture.Item(
      kind: .text, text: "two", html: nil, image: nil, mime: nil, files: [], sha256: nil)
    let third = ClipboardCapture.Item(
      kind: .text, text: "three", html: nil, image: nil, mime: nil, files: [], sha256: nil)
    store.record(first)
    store.record(second)
    store.record(first)
    store.record(third)
    let loaded = expectation(description: "latest page")
    store.page(offset: 0) { page in
      XCTAssertEqual(page?.entries.map(\.value), ["three", "one"])
      XCTAssertEqual(page?.total, 2)
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 3)
  }

  func testRecordedImageUsesCorePathAndIsRemovedOnDelete() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardHistoryStore(directory: root, legacyDirectory: nil)
    store.record(
      ClipboardCapture.Item(
        kind: .image, text: "", html: nil, image: Data([1, 2, 3]), mime: "image/png",
        files: [], sha256: nil))
    let loaded = expectation(description: "image recorded")
    var id: String?
    store.page(offset: 0) { page in
      id = page?.entries.first?.id
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 3)
    let entryID = try XCTUnwrap(id)
    let image = root.appendingPathComponent("images/\(entryID).png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("share/images").path))

    let deleted = expectation(description: "image deleted")
    store.delete(id: entryID) { ok in
      XCTAssertTrue(ok)
      deleted.fulfill()
    }
    wait(for: [deleted], timeout: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
  }
}
