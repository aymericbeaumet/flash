import Foundation
import XCTest

@testable import flash

/// What Flash keeps about you on disk is readable by your account alone, even
/// when the file existed before with a wider mode.
final class PrivateFileTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-private-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? Int)
  }

  private func widened(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    return url
  }

  func testAPrivateWriteLandsOwnerOnlyOverAWiderFile() throws {
    let url = try widened("file.json")
    try PrivateFile.write(Data("new".utf8), to: url)
    XCTAssertEqual(try mode(url), 0o600)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
  }

  /// The file is owner-only from its first byte: the temporary file it is
  /// written to is created 0600, and none is left behind.
  func testANewPrivateFileIsOwnerOnlyAndLeavesNoTemporaryFile() throws {
    let url = directory.appendingPathComponent("fresh.json")
    try PrivateFile.write(Data("one".utf8), to: url)
    try PrivateFile.write(Data("two".utf8), to: url)
    XCTAssertEqual(try mode(url), 0o600)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fresh.json"])
  }

  /// A write that cannot land keeps the previous file and cleans up.
  func testAFailedWriteKeepsThePreviousFile() throws {
    let url = try widened("kept.json")
    let target = directory.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: target.appendingPathComponent("busy"), withIntermediateDirectories: true)
    // Renaming a file over a non-empty directory fails.
    XCTAssertThrowsError(try PrivateFile.write(Data("x".utf8), to: target))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      ["folder", "kept.json"])
  }

  func testTheCommandHistoryIsOwnerOnly() throws {
    let url = try widened("command-history.json")
    let store = try XCTUnwrap(CommandHistoryStore(fileURL: url))
    store.save(["mouse target"])
    store.drain()
    XCTAssertEqual(try mode(url), 0o600)
  }

  func testTheRankingDataIsOwnerOnly() throws {
    let url = try widened("frecency.json")
    let store = try XCTUnwrap(FrecencyStore(fileURL: url))
    store.recordOpen(itemKey: "app:com.apple.Safari")
    store.drain()
    XCTAssertEqual(try mode(url), 0o600)
  }

  func testTheMarksAreOwnerOnly() throws {
    let url = try widened("marks.json")
    let store = MarkStore(file: url, legacyFile: nil)
    let saved = expectation(description: "saved")
    store.set(
      MarkSlot(parsing: "a")!, to: MarkEntry(pid: 1, bundleID: "com.apple.Safari")
    ) { _ in saved.fulfill() }
    wait(for: [saved], timeout: 5)
    XCTAssertEqual(try mode(url), 0o600)
  }
}
