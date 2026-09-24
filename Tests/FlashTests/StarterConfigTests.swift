import Foundation
import XCTest

@testable import flash

final class StarterConfigTests: XCTestCase {
  func testStarterParsesCleanlyAndBindsOnlyHints() throws {
    let config = try loadAsUserFile(StarterConfig.text)
    XCTAssertEqual(config.loadingDiagnostics.map(\.logMessage), [])
    XCTAssertEqual(config.mode.all.map(\.key), [key("cmd+shift+space")])
    let mapping = config.mode.all.first
    XCTAssertEqual(mapping?.action.command, .mouseTarget(.click(.leftClick, modifiers: [])))
    XCTAssertNotNil(mapping?.nativeHotkey)
    // Hints only: advanced mode stays off until the user opts in.
    XCTAssertFalse(config.mode.containsAdvancedModeMapping)
  }

  /// The commented suggestions are copied verbatim by users, so each must
  /// stay valid: uncommenting every one still loads without a diagnostic.
  func testEverySuggestionParsesWhenUncommented() throws {
    var uncommented = 0
    let text = StarterConfig.text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        guard line.hasPrefix("# \"") else { return String(line) }
        uncommented += 1
        return String(line.dropFirst(2))
      }
      .joined(separator: "\n")
    XCTAssertEqual(uncommented, 4)

    let config = try loadAsUserFile(text)
    XCTAssertEqual(config.loadingDiagnostics.map(\.logMessage), [])
    XCTAssertEqual(config.mode.all.count, 5)
    // Every mapping is a single modified chord Carbon can register.
    for mapping in config.mode.all {
      XCTAssertNotNil(mapping.nativeHotkey, mapping.key)
    }
    XCTAssertEqual(
      command(config, "cmd+shift+alt+space"), .mouseGrid(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(command(config, "cmd+ctrl+["), .normalMode)
    XCTAssertEqual(command(config, "cmd+ctrl+i"), .insertMode)
    guard
      case .enterCommand(input: let input, restoreMode: false)? = command(
        config, "cmd+ctrl+alt+space")
    else { return XCTFail("the search suggestion must be enter_command_mode") }
    // The trailing space opens flashlight search, not command completion.
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":" + input), "")
  }

  func testSeedsOnlyWithoutFlashConfigOrAnExistingFile() {
    XCTAssertTrue(StarterConfig.shouldSeed(environment: [:], configExists: false))
    XCTAssertTrue(
      StarterConfig.shouldSeed(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], configExists: false))
    XCTAssertFalse(StarterConfig.shouldSeed(environment: [:], configExists: true))
    XCTAssertFalse(
      StarterConfig.shouldSeed(
        environment: ["FLASH_CONFIG": "/tmp/flash.toml"], configExists: false))
    XCTAssertFalse(StarterConfig.shouldSeed(environment: ["FLASH_CONFIG": ""], configExists: false))
  }

  func testSeedCreatesDirectoriesAndNeverTouchesAnExistingFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-starter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let fresh = root.appendingPathComponent("flash/flash.toml")
    XCTAssertEqual(StarterConfig.seedIfNeeded(at: fresh, environment: [:]), fresh)
    XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), StarterConfig.text)

    let empty = root.appendingPathComponent("empty.toml")
    XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
    XCTAssertNil(StarterConfig.seedIfNeeded(at: empty, environment: [:]))
    XCTAssertEqual(try Data(contentsOf: empty), Data())

    let explicit = root.appendingPathComponent("explicit/flash.toml")
    XCTAssertNil(
      StarterConfig.seedIfNeeded(at: explicit, environment: ["FLASH_CONFIG": explicit.path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: explicit.path))
  }

  /// The layers `ConfigLoader.load()` builds on a first run: the bundled
  /// defaults, then the starter as the user's file.
  private func loadAsUserFile(_ text: String) throws -> Config {
    let defaultsURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // FlashTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("config.default.toml")
    let defaults = try String(contentsOf: defaultsURL, encoding: .utf8)
    return ConfigLoader.parseLayers([
      ConfigLoader.Layer(
        text: defaults, sourceURL: defaultsURL, diagnosticLabel: "config.default.toml"),
      ConfigLoader.Layer(
        text: text, sourceURL: URL(fileURLWithPath: "/tmp/flash-starter/flash.toml")),
    ])
  }

  private func command(_ config: Config, _ rawKey: String) -> URLCommand? {
    config.mode.all.first { $0.key == key(rawKey) }?.action.command
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}
