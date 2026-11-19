import XCTest

@testable import flash

/// The commands bundled plugins own under more than one word: they are no
/// topic of Flash's, and a mapping, the CLI and the command line reach them
/// with the words a core command would take.
final class BundledPluginCommandTests: XCTestCase {
  /// `command → subcommands` of every bundled manifest, as the command line
  /// reads them from the loaded plugins.
  private func bundledCommands() throws -> [String: [String]] {
    var commands: [String: [String]] = [:]
    for root in PluginRepository.officialPluginRoots() {
      for registration in try PluginManifest.load(from: root).pluginCommands {
        commands[registration.command, default: []].append(registration.subcommand)
      }
    }
    return commands
  }

  private func owner(of command: String) throws -> [String] {
    try PluginRepository.officialPluginRoots().compactMap { root in
      let manifest = try PluginManifest.load(from: root)
      return manifest.pluginCommands.contains { $0.command == command } ? manifest.id : nil
    }
  }

  func testTheMediaPluginOwnsTheVolumeAudioAndMediaWords() throws {
    let commands = try bundledCommands()
    XCTAssertEqual(commands["volume"]?.sorted(), ["down", "mute", "up"])
    XCTAssertEqual(commands["audio"]?.sorted(), ["input", "output"])
    XCTAssertEqual(commands["media"], ["status"])
    for word in ["volume", "audio", "media"] {
      XCTAssertFalse(URLEventHandler.isTopic(word), "\(word) is the plugin's, not a topic")
      XCTAssertEqual(try owner(of: word), ["media"], word)
    }
    let manifests = try PluginRepository.officialPluginRoots().map(PluginManifest.load(from:))
    XCTAssertEqual(PluginManifest.commandClaimFailures(manifests), [:])
  }

  /// A mapping keeps its words: `["flash", "volume", "up"]` binds the
  /// plugin's command, arguments included.
  func testMappingsBindTheWordsAndKeepTheirArguments() {
    let cases: [([String], URLCommand)] = [
      (["volume", "up"], .pluginCommand(command: "volume", subcommand: "up", args: [])),
      (["volume", "mute"], .pluginCommand(command: "volume", subcommand: "mute", args: [])),
      (["audio", "input"], .pluginCommand(command: "audio", subcommand: "input", args: [])),
      (
        ["audio", "output", "--device=Studio Speakers"],
        .pluginCommand(
          command: "audio", subcommand: "output", args: ["--device=Studio Speakers"])
      ),
      (["media", "status"], .pluginCommand(command: "media", subcommand: "status", args: [])),
    ]
    for (words, command) in cases {
      XCTAssertEqual(parseMappingCommand(argv: ["flash"] + words), .flashCommand(command))
      XCTAssertEqual(command.diagnosticDescription, "flash " + words.joined(separator: " "))
    }
    // A subcommand the plugin does not declare binds nothing, and playback
    // stays the function-row keys.
    for argv in [
      ["flash", "media", "volumedown"], ["flash", "media", "toggle"], ["flash", "volume"],
      ["flash", "media_play"], ["flash", "audio", "both"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: argv), "\(argv)")
    }
  }

  /// The command line resolves the words by prefix and hands the rest to
  /// the plugin, which reads `--device=` and the words after it as one name.
  func testTheCommandLineResolvesAndCompletesTheWords() throws {
    let inventory = NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: try bundledCommands())
    func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
    }
    XCTAssertEqual(resolve(":volume up"), .plugin(command: "volume", subcommand: "up", args: []))
    XCTAssertEqual(resolve(":vol d"), .plugin(command: "volume", subcommand: "down", args: []))
    XCTAssertEqual(
      resolve(":media status"), .plugin(command: "media", subcommand: "status", args: []))
    XCTAssertEqual(
      resolve(":audio output --device=Studio Speakers"),
      .plugin(command: "audio", subcommand: "output", args: ["--device=Studio", "Speakers"]))
    XCTAssertEqual(resolve(":media volumedown"), .unknown)
    XCTAssertEqual(resolve(":volume"), .incomplete("volume"))

    let subcommands = try bundledCommands()
    let completion = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":volume ", pluginCommands: subcommands.keys.sorted(), pluginSubcommands: subcommands))
    XCTAssertEqual(completion.items.map(\.label).sorted(), ["down", "mute", "up"])
    XCTAssertTrue(completion.items.allSatisfy { $0.kind == .pluginSubcommand })
    let topic = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":vol", pluginCommands: subcommands.keys.sorted(), pluginSubcommands: subcommands))
    XCTAssertEqual(topic.items.map(\.label), ["volume"])
  }
}
