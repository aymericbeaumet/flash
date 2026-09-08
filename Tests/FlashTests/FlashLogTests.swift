import Foundation
import XCTest

@testable import flash

final class FlashLogTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-log-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func record(_ id: Int) -> Data { Data("{\"id\":\(id)}\n".utf8) }

  private func identifiers(in files: [URL]) throws -> [Int] {
    try files.flatMap { file in
      try Data(contentsOf: file).split(separator: 10).map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Int]
        return try XCTUnwrap(object?["id"])
      }
    }
  }

  func testXCTestDisablesDefaultFileOutputAndKeepsInMemorySinks() {
    XCTAssertNil(FlashLog.defaultLogFileURL)
    let emitted = expectation(description: "isolated in-memory log")
    let sink = FlashLog.addSink { record in
      guard record.source == "core:FlashLogTests" else { return }
      XCTAssertEqual(record.message, "isolated log test")
      emitted.fulfill()
    }
    defer { FlashLog.removeSink(sink) }
    FlashLog.info("isolated log test", source: "core:FlashLogTests")
    wait(for: [emitted], timeout: 1)
  }

  func testQueuedRecordsSurviveRepeatedRotation() throws {
    let directory = try temporaryDirectory()
    let writer = FlashLogFileWriter(
      url: directory.appendingPathComponent("flash.log"),
      rotationByteLimit: 80, rotationKeep: 100)
    for id in 0..<200 { writer.append(record(id)) }
    writer.flush()
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    XCTAssertGreaterThan(files.count, 2)
    XCTAssertEqual(try identifiers(in: files).sorted(), Array(0..<200))
  }

  func testIndependentConcurrentWritersAppendWithoutOverwriting() throws {
    let directory = try temporaryDirectory()
    let url = directory.appendingPathComponent("flash.log")
    try record(-1).write(to: url)
    let writers = (0..<4).map { _ in FlashLogFileWriter(url: url) }
    DispatchQueue.concurrentPerform(iterations: 400) { id in
      writers[id % writers.count].append(record(id))
    }
    for writer in writers { writer.flush() }
    XCTAssertEqual(try identifiers(in: [url]).sorted(), Array(-1..<400))
  }
}
