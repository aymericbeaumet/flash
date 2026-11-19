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

  /// Keep-awake is the `caffeinate` plugin's: its four commands and the
  /// `state` segment a status format reads. `flash.caffeinate` names nothing.
  func testTheCaffeinatePluginOwnsItsWordsAndItsStateSegment() throws {
    XCTAssertEqual(
      try bundledCommands()["caffeinate"]?.sorted(), ["off", "on", "status", "toggle"])
    XCTAssertFalse(URLEventHandler.isTopic("caffeinate"))
    XCTAssertEqual(try owner(of: "caffeinate"), ["caffeinate"])
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "caffeinate", "toggle", "--minutes=60"]),
      .flashCommand(
        .pluginCommand(command: "caffeinate", subcommand: "toggle", args: ["--minutes=60"])))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "caffeinate"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "caffeinate", "nap"]))

    func bar(_ value: String) -> Config {
      ConfigLoader.parse(
        """
        [statusbar]
        enabled = true
        template = "#[align=right]#{?\(value),AWAKE,} %H:%M"
        """)
    }
    let config = bar("flash.plugin.caffeinate.state")
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(config.observedStatusSegments()["caffeinate"], ["state"])
    let retired = bar("flash.caffeinate").loadingDiagnostics.map(\.message)
    XCTAssertTrue(
      retired.contains { $0.contains("unknown Flash value flash.caffeinate") }, "\(retired)")
  }

  /// Lock, sleep, restart, shut down, log out, the Trash, dark mode and the
  /// screen saver are the `system` plugin's: six words that are no topic of
  /// Flash's, nine commands a mapping, the CLI and the command line reach
  /// with the words the core commands had, and the four questions they asked.
  func testTheSystemPluginOwnsTheMachineAndSessionWords() throws {
    let commands = try bundledCommands()
    XCTAssertEqual(commands["system"]?.sorted(), ["logout", "restart", "shutdown", "sleep"])
    XCTAssertEqual(commands["screen"], ["lock"])
    XCTAssertEqual(commands["display"], ["sleep"])
    XCTAssertEqual(commands["trash"], ["empty"])
    XCTAssertEqual(commands["appearance"], ["toggle"])
    XCTAssertEqual(commands["screensaver"], ["start"])
    for word in ["screen", "system", "display", "trash", "appearance", "screensaver"] {
      XCTAssertFalse(URLEventHandler.isTopic(word), "\(word) is the plugin's, not a topic")
      XCTAssertEqual(try owner(of: word), ["system"], word)
    }
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "system" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.pluginCommands.reduce(into: [String: String]()) { asked, command in
        asked["\(command.command) \(command.subcommand)"] = command.prompt
      },
      [
        "system restart": "Restart this Mac?", "system shutdown": "Shut down this Mac?",
        "system logout": "Log out of macOS?", "trash empty": "Empty the Trash?",
      ], "only what nothing undoes asks first")
    XCTAssertEqual(manifest.sourceCommands, [], "it performs no core command")
    XCTAssertEqual(manifest.liveSources, .perScope)
    XCTAssertEqual(manifest.sources.map(\.type), ["system"])
    XCTAssertEqual(manifest.activation, .onDemand, "no process until it is used")
    XCTAssertEqual(manifest.capabilities, [.systemActions])
    XCTAssertEqual(manifest.sandboxSpec, PluginSandboxSpec(), "the default sandbox, no allowance")
    XCTAssertEqual(manifest.mappings.count, 0, "no default key was bound to these commands")

    // A mapping and the CLI keep the words.
    for words in [
      ["screen", "lock"], ["system", "sleep"], ["system", "restart"], ["system", "shutdown"],
      ["system", "logout"], ["display", "sleep"], ["trash", "empty"], ["appearance", "toggle"],
      ["screensaver", "start"],
    ] {
      let command = URLCommand.pluginCommand(command: words[0], subcommand: words[1], args: [])
      XCTAssertEqual(parseMappingCommand(argv: ["flash"] + words), .flashCommand(command))
      XCTAssertEqual(command.argv, ["flash"] + words)
      XCTAssertEqual(command.diagnosticDescription, "flash " + words.joined(separator: " "))
    }
    for argv in [
      ["flash", "system"], ["flash", "system", "hibernate"], ["flash", "screen", "unlock"],
      ["flash", "screen_lock"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: argv), "\(argv)")
    }
    XCTAssertEqual(
      parseMappingCommand(
        argv: ["flash", "alert", "confirm", "--prompt=Bye?", "--command=system shutdown"]),
      .flashCommand(
        .confirm(
          ConfirmCommand(
            prompt: "Bye?",
            command: .pluginCommand(command: "system", subcommand: "shutdown", args: [])))))

    // The command line resolves them by prefix; a word alone runs nothing.
    let inventory = NormalModeDispatcher.CommandLineInventory.core(pluginCommands: commands)
    func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
    }
    XCTAssertEqual(
      resolve(":screen lock"), .plugin(command: "screen", subcommand: "lock", args: []))
    XCTAssertEqual(
      resolve(":syst shut"), .plugin(command: "system", subcommand: "shutdown", args: []))
    XCTAssertEqual(resolve(":tr e"), .plugin(command: "trash", subcommand: "empty", args: []))
    XCTAssertEqual(
      resolve(":display sleep"), .plugin(command: "display", subcommand: "sleep", args: []),
      "vim's :di[splay] leaves its words to the command")
    XCTAssertEqual(resolve(":system"), .incomplete("system"))
    XCTAssertEqual(resolve(":screen"), .incomplete("screen"))
    XCTAssertEqual(resolve(":system hibernate"), .unknown)
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandWords(["system", "logout"], inventory: inventory),
      .plugin(command: "system", subcommand: "logout", args: []), "flash system logout")

    func completed(_ line: String) throws -> [String] {
      try XCTUnwrap(
        NormalModeDispatcher.commandLineCompletions(
          line, pluginCommands: commands.keys.sorted(), pluginSubcommands: commands)
      ).items.map(\.label).sorted()
    }
    XCTAssertEqual(try completed(":system "), ["logout", "restart", "shutdown", "sleep"])
    XCTAssertEqual(try completed(":display "), ["sleep"], "completion agrees with dispatch")
    XCTAssertEqual(try completed(":scree"), ["screen", "screensaver", "screenshot"])
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
