import FlashCore
import XCTest

@testable import flash

final class ConfigReloadTests: XCTestCase {
  private var directory: URL!
  private var file: URL { directory.appendingPathComponent("flash.toml") }
  private var environment: [String: String] { ["FLASH_CONFIG": file.path] }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-config-reload-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func write(minLength: Int) throws {
    try Data("[hints]\nmin_length = \(minLength)\n".utf8).write(to: file)
  }

  /// What `watchConfigFile` did about the file: a skip, or a reload's line.
  private func recordingConfigLoads(_ body: () throws -> Void) rethrows -> [String] {
    var lines: [String] = []
    let sink = FlashLog.addSink { record in
      guard
        record.message.hasPrefix("[config] reload_skipped")
          || record.message.hasPrefix("[latency] config_reload")
      else { return }
      lines.append(record.message)
    }
    defer { FlashLog.removeSink(sink) }
    try body()
    return lines
  }

  /// One read gives the path and the bytes; the parse is of those bytes, so
  /// the watcher compares exactly what was applied.
  func testTheConfigurationIsParsedFromTheBytesThatWereRead() throws {
    try write(minLength: 3)
    let read = ConfigLoader.userFile(environment: environment)
    XCTAssertEqual(read.url, file)
    XCTAssertEqual(read.contents, Data("[hints]\nmin_length = 3\n".utf8))
    try write(minLength: 5)
    XCTAssertEqual(ConfigLoader.load(read, environment: environment).hints.minLength, 3)
    XCTAssertNotEqual(ConfigLoader.userFile(environment: environment), read)
  }

  func testAMissingFileReadsAsNoContents() {
    let read = ConfigLoader.userFile(environment: environment)
    XCTAssertEqual(read.url, file)
    XCTAssertNil(read.contents)
    XCTAssertEqual(
      ConfigLoader.load(read, environment: environment).hints.minLength,
      Config.default.hints.minLength)
  }

  /// Launch parses the file once: watching the file it loaded reloads
  /// nothing.
  func testWatchingTheFileLaunchLoadedDoesNotLoadItAgain() throws {
    try write(minLength: 3)
    let delegate = AppDelegate()
    defer { delegate.stopWatchingConfigFile() }
    let lines = recordingConfigLoads {
      delegate.loadLaunchConfig(environment: environment)
      delegate.watchConfigFile(environment: environment)
    }
    XCTAssertEqual(delegate.config.hints.minLength, 3)
    XCTAssertEqual(lines, ["[config] reload_skipped reason=unchanged"])
  }

  /// No file at launch and none since is unchanged too, whatever happened
  /// in the watched directory.
  func testWatchingAMissingFileLaunchLoadedDoesNotLoadItAgain() {
    let delegate = AppDelegate()
    defer { delegate.stopWatchingConfigFile() }
    let lines = recordingConfigLoads {
      delegate.loadLaunchConfig(environment: environment)
      delegate.watchConfigFile(environment: environment)
      delegate.watchConfigFile(environment: environment)
    }
    XCTAssertEqual(lines, Array(repeating: "[config] reload_skipped reason=unchanged", count: 2))
  }

  /// The browser editor saves through a linked `flash.toml`: the link stays
  /// a link and the file it names carries the new text.
  func testSavingThroughASymbolicLinkWritesItsTarget() throws {
    let dotfiles = directory.appendingPathComponent("dotfiles")
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appendingPathComponent("flash.toml")
    try Data("[hints]\nmin_length = 2\n".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

    try AppDelegate.writeConfig("[hints]\nmin_length = 3\n", to: file)

    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[hints]\nmin_length = 3\n")
    let loaded = ConfigLoader.load(
      ConfigLoader.userFile(environment: environment), environment: environment)
    XCTAssertEqual(loaded.hints.minLength, 3)

    // A plain file, and one whose directory does not exist yet, still save.
    let fresh = directory.appendingPathComponent("new/flash.toml")
    try AppDelegate.writeConfig("[hints]\nmin_length = 4\n", to: fresh)
    XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "[hints]\nmin_length = 4\n")
  }
}
