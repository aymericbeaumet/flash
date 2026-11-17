import FlashCore
import Foundation
import XCTest

@testable import flash

/// Every Flash command is `flash <topic> <action>`: two words of
/// `[a-z][a-z0-9_]*`, the topic first. Core commands, CLI queries and bundled
/// plugin commands share the shape and one topic namespace.
final class CommandGrammarTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  func testEveryCoreCommandIsATopicAndAnAction() {
    let keys = URLEventHandler.commandTableKeys
    XCTAssertFalse(keys.isEmpty)
    for key in keys {
      XCTAssertNotNil(CommandName(key), "\(key) is not `<topic> <action>`")
    }
    XCTAssertEqual(URLEventHandler.commandNames.count, keys.count)
    for query in FlashQuery.allCases {
      XCTAssertNotNil(CommandName(query.name.description), query.name.description)
      XCTAssertTrue(URLEventHandler.isTopic(query.name.topic), query.name.description)
      XCTAssertNil(
        URLEventHandler.summary(of: query.name), "\(query.name) is a query, not a command")
    }
    XCTAssertTrue(
      URLEventHandler.commandNames.allSatisfy {
        !(URLEventHandler.summary(of: $0) ?? "").isEmpty
      })
  }

  func testWordsAreLowercaseIdentifiers() {
    for word in ["tab", "half_page_up", "f1", "look_up"] {
      XCTAssertTrue(CommandName.isWord(word), word)
    }
    for word in ["", "Tab", "1tab", "_tab", "tab-next", "tab next", "tab.next", "é"] {
      XCTAssertFalse(CommandName.isWord(word), word)
    }
    XCTAssertNil(CommandName("tab"))
    XCTAssertNil(CommandName("tab next now"))
    XCTAssertNil(CommandName("tab  next"))
    XCTAssertEqual(CommandName("tab next"), CommandName("tab", "next"))
  }

  /// Arguments for the commands that cannot run bare.
  private static let sampleArguments: [String: [String: String]] = [
    "alert confirm": ["prompt": "Close it?", "command": "tab close"],
    "alert show": ["message": "hello"],
    "app open": ["name": "Safari"],
    "clipboard delete": ["id": String(repeating: "a", count: 32)],
    "clipboard pin": ["id": String(repeating: "a", count: 32)],
    "clipboard restore": [
      "id": String(repeating: "a", count: 32), "paste": "true", "plain": "true",
    ],
    "clipboard unpin": ["id": String(repeating: "a", count: 32)],
    "cursor line": ["index": "5"],
    "key arrow": ["direction": "left"],
    "key function": ["key": "f1"],
    "key send": ["keys": "cmd+t"],
    "key sequence": ["keys": "g,i"],
    "key system": ["key": "brightness_down"],
    "mark jump": ["letter": "a"],
    "mark set": ["letter": "a"],
    "menu choose": ["file": "/tmp/branches.txt"],
    "menu press": ["path": "File,Print…"],
    "macro record": ["register": "a"],
    "status clear": ["name": "workspace"],
    "status refresh": ["name": "workspace"],
    "status set": ["name": "workspace", "value": "3"],
    "logs write": ["message": "hello"],
    "metrics record": ["name": "build.duration", "value": "42"],
    "notify send": ["title": "Build done"],
    "mode layer": ["name": "resize"],
    "mouse button": ["state": "down"],
    "mouse gesture": ["fingers": "3", "motion": "swipe_up"],
    "mouse nudge": ["direction": "down"],
    "mouse position": ["action": "save"],
    "mouse step": ["direction": "up"],
    "process kill": ["pid": "4242"],
    "tile join": ["direction": "left"],
    "tile layout": ["type": "accordion"],
    "tile move": ["direction": "right"],
    "tile resize": ["dimension": "width", "amount": "-50"],
    "tile swap": ["direction": "up"],
    "window focus": ["direction": "left"],
    "window move": ["position": "lefthalf"],
    "workspace move_to_monitor": ["direction": "next"],
    "workspace move_window": ["name": "2"],
    "workspace switch": ["name": "web"],
  ]

  /// Every command parses, and writes itself back as the same two words
  /// through a mapping and the command line.
  func testEveryCommandRoundTripsThroughItsArgv() throws {
    for name in URLEventHandler.commandNames {
      let args = Self.sampleArguments[name.description] ?? [:]
      let command = try XCTUnwrap(
        URLEventHandler.parse(topic: name.topic, action: name.action, args: args),
        "\(name) \(args)")
      XCTAssertEqual(Array(command.argv.prefix(3)), ["flash", name.topic, name.action])
      XCTAssertEqual(
        parseMappingCommand(argv: command.argv), .flashCommand(command), name.description)
      XCTAssertEqual(
        NormalModeDispatcher.commandLineCoreCommand(
          ":" + command.argv.dropFirst().joined(separator: " ")),
        command, name.description)
    }
    XCTAssertEqual(
      Set(Self.sampleArguments.keys).subtracting(URLEventHandler.commandNames.map(\.description)),
      [], "every sample names a command")
  }

  /// One word is never a canonical command: `["flash", "tab_next"]` and
  /// `["flash", "quit"]` are unknown in a mapping. What is typed (`:quit`,
  /// `flash quit`) reads vim's ex commands instead (`CommandInvocationTests`).
  func testOneWordFormsAreRejected() {
    for word in ["tab_next", "quit", "enter_normal_mode", "mouse_target", "status", "tab"] {
      XCTAssertNil(parseMappingCommand(argv: ["flash", word]), word)
      XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(":" + word), word)
    }
    XCTAssertNil(parseMappingCommand(argv: ["flash", "tab", "next", "now"]))
  }

  /// Every command that asks the focused app for something is a source
  /// command: its name is a key of the table, and every binding key a plugin
  /// may declare is that name plus the bool flags that still yield one.
  func testSourceCommandsAreCommandsOfTheTable() throws {
    let names = URLEventHandler.sourceCommandNames
    XCTAssertEqual(names.count, 112)
    XCTAssertTrue(names.isSubset(of: Set(URLEventHandler.commandNames)))
    for name in names {
      let command = try XCTUnwrap(
        URLEventHandler.parse(topic: name.topic, action: name.action, args: [:]), "\(name)")
      XCTAssertEqual(command.sourceCommand?.name, name)
      XCTAssertEqual(command.sourceCommand?.arguments, [])
      XCTAssertEqual(command.sourceCommand?.bindingKey, name.description)
    }
    for name in ["app quit", "app open", "mode insert", "window move", "scroll down", "key send"] {
      XCTAssertFalse(names.contains(CommandName(name)!), "\(name) is Flash's own")
    }
    let keys = URLEventHandler.sourceCommandBindingKeys
    XCTAssertEqual(keys.count, 114)
    XCTAssertEqual(keys, keys.sorted(), "rows and the inspector read them in one order")
    XCTAssertEqual(Set(keys.map(\.name)), names)
    XCTAssertEqual(
      keys.filter { !$0.flags.isEmpty }.map(\.description),
      ["app reload --force", "window new --private"])
    XCTAssertTrue(keys.contains(CommandBindingKey("tab select")!))
    XCTAssertEqual(
      URLEventHandler.parse(topic: "app", action: "reload", args: ["force": "1"])?.sourceCommand?
        .bindingKey, "app reload --force")
    let select = URLEventHandler.parse(topic: "tab", action: "select", args: ["index": "3"])?
      .sourceCommand
    XCTAssertEqual(
      select, SourceCommand(name: CommandName("tab", "select"), arguments: ["--index=3"]))
    XCTAssertEqual(select?.argument("index"), "3")
    XCTAssertEqual(select?.bindingKey, "tab select")
    XCTAssertEqual(URLCommand.scroll(.top).sourceCommand?.name, CommandName("scroll", "top"))
    XCTAssertNil(URLCommand.scroll(.down).sourceCommand, "a wheel scroll is Flash's own")
    XCTAssertFalse(URLCommand.tabFirst.sourceCommandRepeats)
    XCTAssertTrue(URLCommand.tabNext.sourceCommandRepeats)
  }

  /// Bundled plugin commands are two words of `[a-z][a-z0-9_]*`. An entry
  /// under one of Flash's topics is a core command the plugin performs, so it
  /// names a source command; any other entry is the plugin's own.
  func testBundledPluginCommandsShareTheShapeAndCoreTopicsNameSourceCommands() throws {
    let plugins = Self.root.appendingPathComponent("Plugins")
    var commands: [(plugin: String, command: String, subcommand: String, confirm: String?)] = []
    for entry in try FileManager.default.contentsOfDirectory(atPath: plugins.path).sorted() {
      let manifest = plugins.appendingPathComponent(entry).appendingPathComponent("manifest.json")
      guard let data = FileManager.default.contents(atPath: manifest.path) else { continue }
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      for command in object["commands"] as? [[String: Any]] ?? [] {
        commands.append(
          (
            entry, command["command"] as? String ?? "",
            command["subcommand"] as? String ?? "", command["confirm"] as? String
          ))
      }
    }
    XCTAssertFalse(commands.isEmpty)
    var core: [String: [String]] = [:]
    for (plugin, command, subcommand, confirm) in commands {
      XCTAssertNotNil(
        CommandName("\(command) \(subcommand)"),
        "\(plugin): flash \(command) \(subcommand) is not two words of [a-z][a-z0-9_]*")
      if URLEventHandler.isTopic(command) {
        XCTAssertTrue(
          URLEventHandler.sourceCommandNames.contains(CommandName(command, subcommand)),
          "\(plugin): flash \(command) \(subcommand) is not a command Flash asks of the app")
        core[plugin, default: []].append("\(command) \(subcommand)" + (confirm == nil ? "" : "?"))
      } else {
        XCTAssertNil(confirm, "\(plugin): only a core command is gated by the host")
      }
    }
    XCTAssertEqual(
      core["browsers"],
      [
        "tab select", "tab next", "tab previous", "tab first", "tab last", "tab move_previous",
        "tab move_next",
      ])
    XCTAssertEqual(core["terminals"]?.count, 17)
    XCTAssertTrue(core["terminals"]?.contains("tab close?") == true)
    XCTAssertTrue(core["terminals"]?.contains("pane close?") == true)
    XCTAssertTrue(core["terminals"]?.contains("app reload") == true)
    XCTAssertNil(core["defaults"], "a manifest-only plugin performs nothing")
  }

  /// A manifest command that breaks the shape fails to load.
  func testManifestRejectsAMalformedCommand() {
    for (command, subcommand) in [
      ("kitty", "focus-tab"), ("Kitty", "tab"), ("kitty_", "Tab"), ("2fa", "show"),
    ] {
      let manifest = PluginManifest(
        id: "fixture", name: "fixture", version: "1", description: "fixture",
        exec: ["/usr/bin/true"],
        commands: [PluginCommandRegistration(command: command, subcommand: subcommand)])
      XCTAssertThrowsError(try manifest.validate(), "\(command) \(subcommand)") { error in
        XCTAssertTrue("\(error)".contains("two words"), "\(error)")
      }
    }
    let wildcard = PluginManifest(
      id: "fixture", name: "fixture", version: "1", description: "fixture",
      exec: ["/usr/bin/true"],
      commands: [PluginCommandRegistration(command: "calc", subcommand: "*")])
    XCTAssertNoThrow(try wildcard.validate())
  }

  /// `[plugins.<id>]` sits beside `[plugins]`' own keys, so no plugin may take
  /// one of them as its id.
  func testManifestRejectsAnIdThatIsAPluginsSetting() {
    for id in ConfigLoader.pluginsSettingKeys {
      let manifest = PluginManifest(
        id: id, name: id, version: "1", description: "fixture", exec: ["/usr/bin/true"])
      XCTAssertThrowsError(try manifest.validate(), id) { error in
        XCTAssertTrue("\(error)".contains("is a [plugins] setting"), "\(error)")
      }
    }
  }

  /// The inspector groups bindings by topic: its table names exactly
  /// Flash's topics, so every other topic is a plugin command.
  /// A topic is the noun of what its commands act on, in one number: the
  /// plural when that noun is a collection the commands add to, read or
  /// show as a whole (`logs write`, `plugins reload`), the singular when
  /// each command addresses one thing, named or focused (`mark set`,
  /// `tab close`); a verb topic (`notify send`) has no number. Every topic
  /// picks a side here, so one noun never appears in both (`log` beside
  /// `logs`), and a new topic has to say which it is.
  enum TopicKind { case one, many, verb }

  private static let topicKinds: [String: TopicKind] = [
    "about": .one, "alert": .one, "app": .one, "appearance": .one, "appwindows": .many,
    "audio": .one, "caffeinate": .verb, "calendar": .one, "cli": .one, "clipboard": .one,
    "commands": .many, "config": .one, "contacts": .many, "controlcenter": .one,
    "cursor": .one, "desktop": .one, "display": .one, "document": .one, "events": .many,
    "help": .one, "hints": .many, "history": .one, "input": .one, "key": .one,
    "launchpad": .one, "logs": .many, "macro": .one, "mappings": .many,
    "mark": .one, "media": .one, "menu": .one, "metrics": .many, "missioncontrol": .one,
    "mode": .one, "monitors": .many, "mouse": .one, "move": .verb, "movement": .one,
    "notes": .many, "notificationcenter": .one, "notify": .verb, "pane": .one,
    "plugins": .many, "popup": .one, "process": .one, "register": .one, "reminders": .many,
    "resident": .one, "resource": .one, "screen": .one, "screensaver": .one, "scroll": .verb,
    "selection": .one, "startup": .one, "status": .one, "system": .one, "tab": .one,
    "telemetry": .one,
    "tile": .verb, "trash": .one, "updates": .many, "url": .one, "volume": .one,
    "window": .one, "workspace": .one,
  ]

  /// Singular nouns that end in `s` anyway.
  private static let singularNounsEndingInS: Set<String> = ["status", "process"]

  func testEveryTopicNamesItsNounKind() {
    XCTAssertEqual(
      Set(Self.topicKinds.keys), URLEventHandler.topics,
      "every topic is listed with its kind, and only topics are")
    for (topic, kind) in Self.topicKinds {
      switch kind {
      case .many:
        XCTAssertTrue(topic.hasSuffix("s"), "\(topic) acts on a collection: plural")
      case .one:
        XCTAssertTrue(
          !topic.hasSuffix("s") || Self.singularNounsEndingInS.contains(topic),
          "\(topic) acts on one thing: singular")
      case .verb:
        XCTAssertFalse(topic.hasSuffix("s"), "\(topic) is a verb")
      }
    }
    for topic in URLEventHandler.topics {
      XCTAssertFalse(
        URLEventHandler.isTopic(topic + "s"), "\(topic) and \(topic)s would be one noun twice")
    }
  }

  /// A renamed topic has no alias: its old spelling parses nothing, and the
  /// rejection, in a mapping and under `config check` alike, names the new
  /// one.
  func testARenamedTopicIsRejectedWithItsNewSpelling() {
    for (old, new) in [
      ("log write --message=hi", "logs write"), ("marks set --letter=a", "mark set"),
      ("marks jump --letter=a", "mark jump"),
    ] {
      let words = old.split(separator: " ").map(String.init)
      XCTAssertFalse(URLEventHandler.isTopic(words[0]), words[0])
      XCTAssertNil(URLEventHandler.parse(words: words), old)
      let message = URLEventHandler.rejectionMessage("flash " + old)
      XCTAssertTrue(message.contains("Did you mean `\(new)`?"), message)
    }
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<leader>a" = ["flash", "marks", "jump", "--letter=a"]
      "<leader>l" = ["flash", "log", "write", "--message=hi"]
      """)
    for new in ["mark jump", "logs write"] {
      XCTAssertTrue(
        config.loadingDiagnostics.contains { $0.message.contains("Did you mean `\(new)`?") },
        "\(new): \(config.loadingDiagnostics.map(\.message))")
    }
  }

  func testInspectorTopicTableMatchesTheTopics() throws {
    let source = try String(
      contentsOf: Self.root.appendingPathComponent("Inspector/src/lib/keyboard.ts"),
      encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "export const topicCategories"))
    let end = try XCTUnwrap(source.range(of: "};", range: start.upperBound..<source.endIndex))
    let table = source[start.upperBound..<end.lowerBound]
    let regex = try NSRegularExpression(
      pattern: #"^\s*([a-z][a-z0-9_]*):"#, options: .anchorsMatchLines)
    let text = String(table)
    let topics = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
    XCTAssertEqual(Set(topics), URLEventHandler.topics)
    XCTAssertEqual(topics.count, Set(topics).count)
  }

  /// `docs/commands.md` carries the full command table: one row per
  /// command, in order, with its syntax and summary.
  func testTheCommandManualListsEveryCommand() throws {
    let manual = try String(
      contentsOf: Self.root.appendingPathComponent("docs/commands.md"), encoding: .utf8)
    let rows = manual.split(separator: "\n").map(String.init).filter {
      $0.hasPrefix("| `")
        && CommandName(
          $0.dropFirst(3).split(separator: " ").prefix(2).joined(separator: " ")
            .replacingOccurrences(of: "`", with: "")) != nil
    }
    let expected = URLEventHandler.commandNames.map { name in
      "| `\(URLEventHandler.syntax(for: name, prefix: "") ?? "")` | "
        + "\(URLEventHandler.summary(of: name) ?? "") |"
    }
    XCTAssertEqual(rows, expected, "docs/commands.md's table drifted from the command table")
    for (row, line) in zip(rows, expected) where row != line {
      XCTFail("expected \(line)\n     got \(row)")
    }
    for query in FlashQuery.allCases {
      XCTAssertTrue(manual.contains("flash \(query.name)"), "\(query.name)")
    }
  }
}
