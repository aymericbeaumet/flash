import FlashTerminal
import Foundation
import XCTest

@testable import flash

final class ConfigurationBoundaryTests: XCTestCase {
  func testFileBackedMappingsPreserveOpaqueArguments() {
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+a" = ["open", "https://example.com/a"]
      "cmd+ctrl+b" = ["sh", "-c", "cat /tmp/example"]
      "cmd+ctrl+c" = ["./tool", "--config=dir/file"]
      """, sourceURL: URL(fileURLWithPath: "/tmp/flash-config/flash.toml"))
    XCTAssertTrue(config.warnings.isEmpty)
    XCTAssertEqual(
      config.mode.all.first { $0.key == "cmd+ctrl+a" }?.action,
      .shellCommand(["open", "https://example.com/a"]))
    XCTAssertEqual(
      config.mode.all.first { $0.key == "cmd+ctrl+b" }?.action,
      .shellCommand(["sh", "-c", "cat /tmp/example"]))
    XCTAssertEqual(
      config.mode.all.first { $0.key == "cmd+ctrl+c" }?.action,
      .shellCommand(["/tmp/flash-config/tool", "--config=dir/file"]))
  }

  func testEnvironmentIsAppliedBeforeDerivingEffectiveModifiers() {
    let config = ConfigLoader.parse(
      "[hints]\nkeys = \"as;d\"",
      environment: ["FLASH_HINTS_KEYS": "ab"])
    let equivalent = ConfigLoader.parse("[hints]\nkeys = \"ab\"")
    XCTAssertEqual(config.hints.keys, equivalent.hints.keys)
    XCTAssertEqual(config.hints.magicModifiers, equivalent.hints.magicModifiers)
    XCTAssertEqual(config.warnings, equivalent.warnings)
  }

  func testInvalidBuiltinCannotFallThroughToAPlugin() {
    XCTAssertNil(
      URLEventHandler.parseOrPluginVerb(
        verb: "mouse_target", args: ["scope": "bogus"]))
  }

  func testMappingsRejectMalformedAndDuplicateArguments() {
    for tail in [["secondary=1"], ["--"], ["--=x"], ["--double", "--double=0"]] {
      XCTAssertNil(parseMappingCommand(argv: ["flash", "mouse_target"] + tail), "\(tail)")
    }
  }

  func testBuiltinsRejectUnknownAndMalformedTypedArguments() {
    XCTAssertNil(URLEventHandler.parse(verb: "mouse_target", args: ["secondary": "perhaps"]))
    XCTAssertNil(URLEventHandler.parse(verb: "app_reload", args: ["force": "perhaps"]))
    XCTAssertNil(URLEventHandler.parse(verb: "scroll_down", args: ["typo": "1"]))
    XCTAssertNil(URLEventHandler.parse(verb: "tab_select", args: ["index": "invalid"]))
    for variant in ["secondary", "double", "middle", "triple"] {
      XCTAssertNil(URLEventHandler.parse(verb: "mouse_target", args: ["move": "1", variant: "1"]))
    }
    for verb in ["mouse_grid", "mouse_snipe"] {
      XCTAssertNil(URLEventHandler.parse(verb: verb, args: ["adjust": "1"]))
      XCTAssertNil(URLEventHandler.parse(verb: verb, args: ["search": "1"]))
    }
  }

  func testResolutionPreservesAuthoredModifiersAndIsIdempotent() {
    var config = ConfigLoader.parse("[hints]\nkeys = \"as;d\"")
    XCTAssertTrue(config.hints.magicModifiers.contains("shift"))
    XCTAssertFalse(config.effectiveMagicModifiers.contains("shift"))
    config.prepareDerivedValues()
    XCTAssertEqual(config.warnings.count, 1)
    config.hints.keys = "asdf"
    config.prepareDerivedValues()
    XCTAssertTrue(config.effectiveMagicModifiers.contains("shift"))
    XCTAssertTrue(config.warnings.isEmpty)
  }

  func testEnvironmentUsesTheSameValidationAsTOML() {
    let config = ConfigLoader.parse(
      "[hints]\nmin_length = 2",
      environment: [
        "FLASH_HINTS_MIN_LENGTH": "0",
        "FLASH_HINTS_MAGIC_MODIFIERS": "[\"cmd\", \"bogus\"]",
        "FLASH_DEBUG_SHOW_HINTS_BOUNDS": "yes",
      ])
    XCTAssertEqual(config.hints.minLength, 2)
    XCTAssertEqual(config.hints.magicModifiers, ["cmd"])
    XCTAssertFalse(config.debug.showHintsBounds)
    XCTAssertEqual(config.warnings.count, 3)
    XCTAssertTrue(config.warnings.allSatisfy { $0.hasPrefix("FLASH_") })
  }

  func testFileBackedStatusAndTerminalArgumentsRemainOpaque() {
    let config = ConfigLoader.parse(
      """
      [statusbar.sources.news]
      command = ["sh", "-c", "cat /tmp/news"]
      [terminal.docs]
      command = ["open", "https://example.com/docs"]
      """, sourceURL: URL(fileURLWithPath: "/tmp/flash-config/flash.toml"))
    XCTAssertTrue(config.warnings.isEmpty, "\(config.warnings)")
    XCTAssertEqual(config.statusBar.sources["news"]?.command, ["sh", "-c", "cat /tmp/news"])
    XCTAssertEqual(config.terminals["docs"]?.command, ["open", "https://example.com/docs"])
  }

  func testWorkingDirectoriesResolveDotPathsAgainstTheirConfigurationFile() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-config-\(UUID().uuidString)", isDirectory: true)
    let source = directory.appendingPathComponent("flash.toml")
    for path in [".", "..", ".cache", "status", "./status", "../status"] {
      let config = ConfigLoader.parse(
        """
        [statusbar.sources.example]
        command = ["/bin/pwd"]
        working_directory = "\(path)"
        [terminal.example]
        command = ["/bin/pwd"]
        working_directory = "\(path)"
        """, sourceURL: source)
      let expected = directory.appendingPathComponent(path).standardizedFileURL.path
      XCTAssertTrue(config.warnings.isEmpty, "\(config.warnings)")
      XCTAssertEqual(config.statusBar.sources["example"]?.workingDirectory, expected, path)
      XCTAssertEqual(config.terminals["example"]?.workingDirectory, expected, path)
    }
  }

  func testTerminalCanReadRelativeResourcesBesideItsConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-config-\(UUID().uuidString)", isDirectory: true)
    let resources = directory.appendingPathComponent("status", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("config-relative-resource".utf8).write(to: resources.appendingPathComponent("value"))
    let config = ConfigLoader.parse(
      """
      [terminal.example]
      command = ["/bin/cat", "status/value"]
      working_directory = "."
      """, sourceURL: directory.appendingPathComponent("flash.toml"))
    let definition = try XCTUnwrap(config.terminals["example"])
    XCTAssertEqual(definition.command, ["/bin/cat", "status/value"])
    let session = TerminalSession(
      configuration: StatusTerminalRegistry.configuration(for: definition, environment: [:]))
    defer { session.shutdown() }
    let exited = expectation(description: "relative resource read completes")
    session.onStateChange = { state in
      switch state {
      case .exited(let code):
        XCTAssertEqual(code, 0)
        XCTAssertEqual(
          session.frame?.text.trimmingCharacters(in: .whitespacesAndNewlines),
          "config-relative-resource")
        exited.fulfill()
      case .failed(let message):
        XCTFail(message)
        exited.fulfill()
      default: break
      }
    }
    session.start()
    wait(for: [exited], timeout: 5)
    session.onStateChange = nil
  }

  func testCommandCatalogDescriptionsCoverEveryDeclaredCommand() {
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    XCTAssertTrue(catalog.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
    XCTAssertEqual(
      catalog.first { $0["name"] as? String == ":quit" }?["description"] as? String,
      "Close the focused window")
    XCTAssertEqual(
      catalog.first { $0["name"] as? String == ":qall" }?["description"] as? String,
      "Quit the focused app")
  }

  func testMappingsAndTerminalsShareEnvironmentExpansionWithoutShellEvaluation() throws {
    let environment = ["BIN": "/tmp/bin", "VALUE": "literal $(touch /tmp/never)"]
    let command = ["$BIN/tool", "${VALUE}", "$MISSING", "https://example.com/a"]
    let mapping = try XCTUnwrap(
      CommandMappingRunner.launchPlan(for: command, environment: environment))
    let terminal = StatusTerminalRegistry.configuration(
      for: .init(command: command), environment: environment)
    XCTAssertEqual([mapping.executableURL.path] + mapping.arguments, terminal.command)
    XCTAssertEqual(
      mapping.arguments, ["literal $(touch /tmp/never)", "$MISSING", "https://example.com/a"])
  }
}
