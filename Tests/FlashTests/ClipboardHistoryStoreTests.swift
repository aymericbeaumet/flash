import AppKit
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

  // MARK: - Pins, sizes and restores

  private func text(_ value: String) -> ClipboardCapture.Item {
    ClipboardCapture.Item(
      kind: .text, text: value, html: nil, image: nil, mime: nil, files: [], sha256: nil)
  }

  private func png(width: Int, height: Int) throws -> Data {
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }

  /// Waits for every operation queued so far, and returns the first page.
  private func firstPage(_ store: ClipboardHistoryStore) -> ClipboardHistoryPage? {
    let loaded = expectation(description: "page")
    var result: ClipboardHistoryPage?
    store.page(offset: 0) { page in
      result = page
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 3)
    return result
  }

  private func pin(_ store: ClipboardHistoryStore, _ id: String, _ pinned: Bool = true)
    -> ClipboardHistoryStore.PinResult?
  {
    let done = expectation(description: "pin")
    var result: ClipboardHistoryStore.PinResult?
    store.setPinned(id: id, pinned) { outcome in
      result = outcome
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
    return result
  }

  func testPinnedEntriesListFirstSurviveTrimmingAndPersist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardHistoryStore(directory: root, legacyDirectory: nil, capacity: 3)
    store.record(text("oldest"))
    store.record(text("middle"))
    store.record(text("newest"))
    let oldest = try XCTUnwrap(firstPage(store)?.entries.last)
    XCTAssertEqual(oldest.value, "oldest")
    XCTAssertEqual(pin(store, oldest.id), .changed)
    store.record(text("fourth"))
    store.record(text("fifth"))
    let page = try XCTUnwrap(firstPage(store))
    XCTAssertEqual(page.entries.map(\.value), ["oldest", "fifth", "fourth"])
    XCTAssertEqual(page.entries.map(\.pinned), [true, false, false])
    XCTAssertEqual(page.total, 3)

    let reloaded = ClipboardHistoryStore(directory: root, legacyDirectory: nil, capacity: 3)
    XCTAssertEqual(firstPage(reloaded)?.entries.map(\.value), ["oldest", "fifth", "fourth"])
    XCTAssertEqual(firstPage(reloaded)?.entries.first?.pinned, true)

    // A lower capacity trims unpinned entries only, and always keeps the newest.
    reloaded.setCapacity(1)
    XCTAssertEqual(firstPage(reloaded)?.entries.map(\.value), ["oldest", "fifth"])
  }

  func testPinsLeaveRoomForANewCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardHistoryStore(directory: root, legacyDirectory: nil, capacity: 2)
    store.record(text("one"))
    store.record(text("two"))
    let ids = try XCTUnwrap(firstPage(store)?.entries.map(\.id))
    XCTAssertEqual(pin(store, ids[0]), .changed)
    XCTAssertEqual(pin(store, ids[1]), .full(capacity: 2))
    XCTAssertEqual(pin(store, ids[0]), .unchanged)
    XCTAssertEqual(pin(store, String(repeating: "f", count: 32)), .missing)
    XCTAssertEqual(pin(store, ids[0], false), .changed)
    XCTAssertEqual(firstPage(store)?.entries.map(\.pinned), [false, false])
  }

  func testListingFollowsDisplayOrderAndCarriesImageSizes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = NSLock()
    var listings: [[ClipboardListing]] = []
    let store = ClipboardHistoryStore(
      directory: root, legacyDirectory: nil,
      didList: { listing in
        lock.lock()
        listings.append(listing)
        lock.unlock()
      })
    let image = try png(width: 3, height: 2)
    store.record(text("words"))
    store.record(
      ClipboardCapture.Item(
        kind: .image, text: "", html: nil, image: image, mime: "image/png", files: [],
        sha256: ClipboardCapture.sha256Hex(image)))
    let ids = try XCTUnwrap(firstPage(store)?.entries.map(\.id))
    XCTAssertEqual(pin(store, ids[1]), .changed)
    _ = firstPage(store)
    lock.lock()
    let last = listings.last ?? []
    lock.unlock()
    XCTAssertEqual(last.map(\.text), ["words", ""])
    XCTAssertEqual(last.map(\.pinned), [true, false])
    XCTAssertEqual(last[1].kind, "image")
    XCTAssertEqual(last[1].width, 3)
    XCTAssertEqual(last[1].height, 2)
  }

  func testImagesRecordedWithoutASizeLearnItOnLoad() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
    let id = String(repeating: "b", count: 32)
    let image = try png(width: 5, height: 4)
    try image.write(to: root.appendingPathComponent("images/\(id).png"))
    let json = """
      [{"id":"\(id)","kind":"image","text":"","mime":"image/png","files":[],\
      "sha256":"\(ClipboardCapture.sha256Hex(image))"}]
      """
    try Data(json.utf8).write(to: root.appendingPathComponent("history.json"))

    let lock = NSLock()
    var listed: [ClipboardListing] = []
    let store = ClipboardHistoryStore(
      directory: root, legacyDirectory: nil,
      didList: { listing in
        lock.lock()
        listed = listing
        lock.unlock()
      })
    XCTAssertEqual(firstPage(store)?.entries.map(\.id), [id])
    lock.lock()
    XCTAssertEqual(listed.first?.width, 5)
    XCTAssertEqual(listed.first?.height, 4)
    lock.unlock()
    let stored = try String(
      contentsOf: root.appendingPathComponent("history.json"), encoding: .utf8)
    XCTAssertTrue(stored.contains("\"width\":5"), stored)
    XCTAssertFalse(stored.contains("pinned"), "unpinned entries write no pin")
  }

  func testTouchMovesARestoredEntryFirstAndPayloadReadsItsImage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardHistoryStore(directory: root, legacyDirectory: nil)
    let image = try png(width: 2, height: 2)
    store.record(
      ClipboardCapture.Item(
        kind: .image, text: "", html: nil, image: image, mime: "image/png", files: [],
        sha256: ClipboardCapture.sha256Hex(image)))
    store.record(text("later"))
    let ids = try XCTUnwrap(firstPage(store)?.entries.map(\.id))
    store.touch(id: ids[1])
    XCTAssertEqual(firstPage(store)?.entries.map(\.id), [ids[1], ids[0]])

    let read = expectation(description: "payload")
    store.payload(id: ids[1]) { payload in
      XCTAssertEqual(payload?.kind, "image")
      XCTAssertEqual(payload?.mime, "image/png")
      XCTAssertEqual(payload?.image, image)
      read.fulfill()
    }
    wait(for: [read], timeout: 3)
    let missing = expectation(description: "missing payload")
    store.payload(id: String(repeating: "c", count: 32)) { payload in
      XCTAssertNil(payload)
      missing.fulfill()
    }
    wait(for: [missing], timeout: 3)
  }
}
