import Foundation
import XCTest

@testable import flash

/// The 36 app marks: one ASCII letter or digit each, saved as a process ID
/// and bundle identifier, persisted beside the other core stores.
final class MarkStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func file(_ name: String = "marks.json") -> URL {
    root.appendingPathComponent(name)
  }

  private func legacyFile() -> URL {
    root.appendingPathComponent("Plugins/marks/share/marks.json")
  }

  private func entry(_ store: MarkStore, _ slot: MarkSlot) -> MarkEntry? {
    let read = expectation(description: "mark read")
    var result: MarkEntry?
    store.entry(for: slot) { value in
      result = value
      read.fulfill()
    }
    wait(for: [read], timeout: 3)
    return result
  }

  @discardableResult
  private func set(_ store: MarkStore, _ slot: MarkSlot, _ entry: MarkEntry) -> Bool {
    let saved = expectation(description: "mark set")
    var result = false
    store.set(slot, to: entry) { ok in
      result = ok
      saved.fulfill()
    }
    wait(for: [saved], timeout: 3)
    return result
  }

  // MARK: - Slots

  func testSlotsAreOneASCIILetterOrDigitLowercased() {
    XCTAssertEqual(MarkSlot(parsing: "a")?.description, "a")
    XCTAssertEqual(MarkSlot(parsing: "Z")?.description, "z")
    XCTAssertEqual(MarkSlot(parsing: "5")?.description, "5")
    for rejected in ["é", "٢", "ab", "", " a", "a ", "-", "_"] {
      XCTAssertNil(MarkSlot(parsing: rejected), rejected)
    }
    XCTAssertEqual(MarkSlot(parsing: "A"), MarkSlot(parsing: "a"))
  }

  // MARK: - Target resolution

  func testTargetPrefersTheSavedProcessThenAnotherInstanceOfTheBundle() {
    let mark = MarkEntry(pid: 17, bundleID: "com.example.editor")
    XCTAssertEqual(
      MarkStore.target(
        for: mark,
        running: [
          (pid: 29, bundleID: "com.example.editor"), (pid: 17, bundleID: "com.example.editor"),
        ]),
      17)
    // The saved pid now belongs to another app: another instance of the
    // bundle wins over it.
    XCTAssertEqual(
      MarkStore.target(
        for: mark,
        running: [
          (pid: 17, bundleID: "com.example.other"), (pid: 29, bundleID: "com.example.editor"),
        ]),
      29)
    XCTAssertNil(
      MarkStore.target(for: mark, running: [(pid: 17, bundleID: "com.example.other")]))
    XCTAssertNil(MarkStore.target(for: mark, running: []))
    // An app without a bundle identifier only comes back as its own process.
    let unbundled = MarkEntry(pid: 17, bundleID: "")
    XCTAssertEqual(MarkStore.target(for: unbundled, running: [(pid: 17, bundleID: "")]), 17)
    XCTAssertNil(MarkStore.target(for: unbundled, running: [(pid: 29, bundleID: "")]))
  }

  // MARK: - Persistence

  func testMarksRoundTripThroughTheFile() throws {
    let slot = try XCTUnwrap(MarkSlot(parsing: "a"))
    let digit = try XCTUnwrap(MarkSlot(parsing: "7"))
    let first = MarkStore(file: file(), legacyFile: nil)
    XCTAssertNil(entry(first, slot))
    XCTAssertTrue(set(first, slot, MarkEntry(pid: 17, bundleID: "com.example.editor")))
    XCTAssertTrue(set(first, digit, MarkEntry(pid: 41, bundleID: "com.example.terminal")))
    XCTAssertEqual(entry(first, slot), MarkEntry(pid: 17, bundleID: "com.example.editor"))

    let data = try Data(contentsOf: file())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try XCTUnwrap(object["entries"] as? [String: [String: Any]])
    XCTAssertEqual(entries["a"]?["pid"] as? Int, 17)
    XCTAssertEqual(entries["a"]?["bundle_id"] as? String, "com.example.editor")
    XCTAssertEqual(entries["7"]?["bundle_id"] as? String, "com.example.terminal")

    let second = MarkStore(file: file(), legacyFile: nil)
    XCTAssertEqual(entry(second, slot), MarkEntry(pid: 17, bundleID: "com.example.editor"))
    XCTAssertEqual(entry(second, digit), MarkEntry(pid: 41, bundleID: "com.example.terminal"))
  }

  func testRewritePIDKeepsTheMarkOnTheRunningInstance() throws {
    let slot = try XCTUnwrap(MarkSlot(parsing: "b"))
    let store = MarkStore(file: file(), legacyFile: nil)
    let saved = MarkEntry(pid: 17, bundleID: "com.example.editor")
    XCTAssertTrue(set(store, slot, saved))
    store.rewritePID(29, for: slot, expecting: saved)
    XCTAssertEqual(entry(store, slot), MarkEntry(pid: 29, bundleID: "com.example.editor"))
    // A mark that changed meanwhile is left alone.
    store.rewritePID(99, for: slot, expecting: saved)
    XCTAssertEqual(entry(store, slot), MarkEntry(pid: 29, bundleID: "com.example.editor"))
    let reloaded = MarkStore(file: file(), legacyFile: nil)
    XCTAssertEqual(entry(reloaded, slot), MarkEntry(pid: 29, bundleID: "com.example.editor"))
  }

  func testAFailedSaveKeepsNoMark() throws {
    // The file's parent is a regular file, so the directory cannot be made.
    let blocker = root.appendingPathComponent("blocker")
    try Data("x".utf8).write(to: blocker)
    let slot = try XCTUnwrap(MarkSlot(parsing: "a"))
    let store = MarkStore(file: blocker.appendingPathComponent("marks.json"), legacyFile: nil)
    XCTAssertFalse(set(store, slot, MarkEntry(pid: 17, bundleID: "com.example.editor")))
    XCTAssertNil(entry(store, slot))
  }

  func testLegacyPluginMarksMoveToTheCoreFileOnce() throws {
    let legacy = legacyFile()
    try FileManager.default.createDirectory(
      at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json = #"{"entries":{"a":{"pid":17,"bundle_id":"com.example.editor"}}}"#
    try Data(json.utf8).write(to: legacy)
    let slot = try XCTUnwrap(MarkSlot(parsing: "a"))

    let store = MarkStore(file: file(), legacyFile: legacy)
    XCTAssertEqual(entry(store, slot), MarkEntry(pid: 17, bundleID: "com.example.editor"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file().path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Plugins/marks").path),
      "the emptied plugin directory is removed")
  }

  func testAnExistingCoreFileIsNeverOverwrittenByTheLegacyOne() throws {
    let legacy = legacyFile()
    try FileManager.default.createDirectory(
      at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"entries":{"a":{"pid":17,"bundle_id":"com.example.old"}}}"#.utf8).write(to: legacy)
    try Data(#"{"entries":{"a":{"pid":29,"bundle_id":"com.example.new"}}}"#.utf8).write(to: file())
    let slot = try XCTUnwrap(MarkSlot(parsing: "a"))

    let store = MarkStore(file: file(), legacyFile: legacy)
    XCTAssertEqual(entry(store, slot), MarkEntry(pid: 29, bundleID: "com.example.new"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "no migration")
  }

  func testAnUnreadableFileLoadsNoMarks() throws {
    try Data("not json".utf8).write(to: file())
    let store = MarkStore(file: file(), legacyFile: nil)
    XCTAssertNil(entry(store, try XCTUnwrap(MarkSlot(parsing: "a"))))
    let invalidSlots =
      #"{"entries":{"ab":{"pid":1,"bundle_id":"x"},"é":{"pid":2,"bundle_id":"y"}}}"#
    try Data(invalidSlots.utf8).write(to: file("other.json"))
    let other = MarkStore(file: file("other.json"), legacyFile: nil)
    XCTAssertNil(entry(other, try XCTUnwrap(MarkSlot(parsing: "a"))))
  }

  // MARK: - Commands

  func testCommandsParseAndRoundTrip() throws {
    let slot = try XCTUnwrap(MarkSlot(parsing: "a"))
    let cases: [(String, MarkCommand)] = [
      ("mark set --letter=a", .set(slot)), ("mark jump --letter=a", .jump(slot)),
    ]
    for (text, command) in cases {
      let words = text.split(separator: " ").map(String.init)
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash"] + words), .flashCommand(.marks(command)), text)
      XCTAssertEqual(URLCommand.marks(command).diagnosticDescription, "flash " + text)
      XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(":" + text), .marks(command))
      XCTAssertFalse(URLCommand.marks(command).explanation.isEmpty)
    }
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "mark", "set", "--letter=Z"]),
      .flashCommand(.marks(.set(try XCTUnwrap(MarkSlot(parsing: "z"))))))
    XCTAssertEqual(
      URLCommand.marks(.set(slot)).explanation, "Saves the focused app as mark a.")
    XCTAssertEqual(
      URLCommand.marks(.jump(slot)).explanation, "Brings back the app saved as mark a.")
    XCTAssertTrue(URLEventHandler.isTopic("mark"))
    for argv in [
      ["flash", "mark", "set", "a"], ["flash", "mark", "set"],
      ["flash", "mark", "set", "--letter=ab"], ["flash", "mark", "set", "--letter="],
      ["flash", "mark", "jump", "--letter=é"], ["flash", "mark", "jump", "--letter=a", "--now"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: argv), argv.joined(separator: " "))
    }
  }
}
