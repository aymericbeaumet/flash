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
    XCTAssertEqual(config.statusSegmentsRead()["caffeinate"], ["state"])
    let retired = bar("flash.caffeinate").loadingDiagnostics.map(\.message)
    XCTAssertTrue(
      retired.contains { $0.contains("unknown Flash value flash.caffeinate") }, "\(retired)")
  }

  /// The next meeting is the `calendar` plugin's: its eight segments, its
  /// two commands under a word that is no topic of Flash's, and its
  /// settings. `flash.calendar.next` and `[calendar]` name nothing, while
  /// `flash.calendar`, the three-month view, stays Flash's own value.
  func testTheCalendarPluginOwnsTheCalendarWordItsValuesAndItsSettings() throws {
    XCTAssertEqual(try bundledCommands()["calendar"]?.sorted(), ["join", "next"])
    XCTAssertFalse(URLEventHandler.isTopic("calendar"), "calendar is the plugin's, not a topic")
    XCTAssertEqual(try owner(of: "calendar"), ["calendar"])
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "calendar" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.pluginCommands.map { "\($0.command) \($0.subcommand): \($0.prompt ?? "")" },
      ["calendar join: ", "calendar next: "], "neither asks first")
    XCTAssertEqual(manifest.sourceCommands, [], "it performs no core command")
    let segments = [
      "next", "next_title", "next_in", "next_minutes", "next_start", "next_end", "next_ongoing",
      "next_link",
    ]
    XCTAssertEqual(manifest.status, segments)
    XCTAssertTrue(manifest.isStatusBound)
    XCTAssertEqual(
      manifest.activation(statusObserved: false), .onDemand, "no process until a value is shown")
    XCTAssertEqual(manifest.activation(statusObserved: true), .resident)
    XCTAssertEqual(manifest.capabilities, [.calendarEvents, .open])
    XCTAssertEqual(
      manifest.listen, [HostEvent.statusObserved.rawValue, HostEvent.calendarChanged.rawValue])
    XCTAssertEqual(manifest.sandboxSpec, PluginSandboxSpec(), "the default sandbox, no allowance")
    XCTAssertEqual(manifest.sources.count, 0)
    XCTAssertEqual(manifest.mappings.count, 0, "no default key was bound to it")
    XCTAssertEqual(manifest.settings["calendars"]?.type, .stringArray)
    XCTAssertEqual(manifest.settings["all_day"]?.type, .boolean)
    XCTAssertEqual(manifest.settings["declined"]?.type, .boolean)
    XCTAssertEqual(manifest.settings["lookahead_hours"]?.type, .integer)
    let manifests = try PluginRepository.officialPluginRoots().map(PluginManifest.load(from:))
    XCTAssertEqual(PluginManifest.commandClaimFailures(manifests), [:])

    // A mapping, the CLI and the command line keep the words.
    for subcommand in ["join", "next"] {
      let command = URLCommand.pluginCommand(command: "calendar", subcommand: subcommand, args: [])
      XCTAssertEqual(
        parseMappingCommand(argv: ["flash", "calendar", subcommand]), .flashCommand(command))
      XCTAssertEqual(command.argv, ["flash", "calendar", subcommand])
    }
    XCTAssertNil(parseMappingCommand(argv: ["flash", "calendar"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "calendar", "agenda"]))
    let inventory = NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: try bundledCommands())
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":calendar join", inventory: inventory),
      .plugin(command: "calendar", subcommand: "join", args: []))
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":calendar", inventory: inventory),
      .incomplete("calendar"), "the word alone joins nothing")

    // Every segment validates wherever a status format reads it: the bar, a
    // text popup, a widget and a monitor, which all keep its plugin running.
    let names = segments.map { "flash.plugin.calendar.\($0)" }
    let all = names.map { "#{\($0)}" }.joined(separator: " ")
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "\(all) #{flash.calendar}"

      [popup.meeting]
      text = "\(all)"

      [widgets.meeting]
      template = "\(all)"

      [monitors.meeting]
      value = "#{flash.plugin.calendar.next_minutes}"
      direction = "below"
      warning = 2
      message = "#{flash.plugin.calendar.next}"
      detail = "#{flash.plugin.calendar.next_link}"

      [plugins.calendar]
      calendars = ["Work", "Family"]
      all_day = true
      declined = true
      lookahead_hours = 8
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      config.plugins.settings["calendar"],
      [
        "calendars": .stringArray(["Work", "Family"]), "all_day": .bool(true),
        "declined": .bool(true), "lookahead_hours": .int(8),
      ])
    XCTAssertEqual(
      config.statusSegmentsRead()["calendar"], Set(segments),
      "a widget and a monitor read them with the bar off")
    let monitorOnly = ConfigLoader.parse(
      """
      [monitors.meeting]
      value = "#{flash.plugin.calendar.next_minutes}"
      direction = "below"
      warning = 2
      """)
    XCTAssertEqual(monitorOnly.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(monitorOnly.statusSegmentsRead()["calendar"], ["next_minutes"])

    func diagnostics(_ toml: String) -> [String] {
      ConfigLoader.parse(toml).loadingDiagnostics.map(\.message)
    }
    for retired in ["flash.calendar.next", "flash.calendar.next_minutes"] {
      let reported = diagnostics("[statusbar]\ntemplate = \"#{\(retired)}\"")
      XCTAssertTrue(
        reported.contains { $0.contains("unknown Flash value \(retired)") }, "\(reported)")
    }
    let section = diagnostics("[calendar]\nlookahead_hours = 8")
    XCTAssertTrue(section.contains { $0.contains("calendar") }, "\(section)")
    // `flash config check` holds the settings to the manifest's types.
    let invalid = ConfigLoader.parseLayers(
      [
        ConfigLoader.Layer(
          text: """
            [plugins.calendar]
            calendars = "Work"
            all_day = "yes"
            lookahead_hours = 0
            unknown = 1
            """)
      ], pluginSettings: .bundled()
    ).loadingDiagnostics.map(\.message)
    XCTAssertEqual(
      invalid,
      [
        "plugins.calendar.all_day must be true or false",
        "plugins.calendar.calendars must be an array of strings",
        "plugins.calendar.lookahead_hours must be an integer between 1 and 168",
        "unknown config key 'plugins.calendar.unknown'",
      ])
  }

  /// The templates docs/calendar.md shows, over segments as the plugin
  /// publishes them: empty while no event is next, and a title from someone
  /// else's invitation as text, never a style, a link or a click range.
  func testTheDocumentedCalendarTemplatesRenderOverThePluginsSegments() {
    func render(_ template: String, _ segments: [String: String]) -> [FlashStatusTextSegment] {
      let context = FlashStatusBarContext(pluginStatuses: [
        PluginStatusBarInfo(
          id: "calendar", state: "running", hasError: false,
          statusSegments: segments.mapValues(PluginStatusSegment.text))
      ])
      return FlashStatusBarTemplateEngine.evaluate(
        template: .init(template: "#[align=right]" + template), context: context
      ).model.rightDocument.filter { !$0.text.isEmpty }
    }
    func text(_ template: String, _ segments: [String: String]) -> String {
      render(template, segments).map(\.text).joined()
    }
    let soon = [
      "next": "Standup in 12m", "next_title": "Standup", "next_in": "in 12m",
      "next_minutes": "12",
    ]
    let later = [
      "next": "Review in 3h", "next_title": "Review", "next_in": "in 3h", "next_minutes": "180",
    ]
    let none = ["next": "", "next_title": "", "next_in": "", "next_minutes": ""]
    let bar =
      "#{?flash.plugin.calendar.next,#[range=user|join]#[shrink]#{flash.plugin.calendar.next_title}"
      + "#[noshrink] #{flash.plugin.calendar.next_in}#[norange] · ,}X"
    XCTAssertEqual(text(bar, soon), "Standup in 12m · X")
    XCTAssertEqual(Set(render(bar, soon).compactMap(\.range)), ["join"])
    XCTAssertNil(render(bar, soon).last?.range)
    XCTAssertEqual(text(bar, none), "X")
    XCTAssertEqual(text(bar, [:]), "X", "before the plugin published anything")
    let gated =
      "#{?#{&&:#{flash.plugin.calendar.next},#{e|<=:#{flash.plugin.calendar.next_minutes},120}},"
      + "#{flash.plugin.calendar.next} · ,}X"
    XCTAssertEqual(text(gated, soon), "Standup in 12m · X")
    XCTAssertEqual(text(gated, later), "X")
    XCTAssertEqual(text(gated, none), "X")

    // The plugin doubles `#` in a title and in a link (`Markup::text`).
    let hostile = render(
      "#{flash.plugin.calendar.next} #{flash.plugin.calendar.next_link}",
      [
        "next": "##[range=user|x]1:1 ##2 in 5m",
        "next_link": "https://facetime.apple.com/join##v=1&p=AbC",
      ])
    XCTAssertEqual(
      hostile.map(\.text).joined(),
      "#[range=user|x]1:1 #2 in 5m https://facetime.apple.com/join#v=1&p=AbC")
    XCTAssertTrue(hostile.allSatisfy { $0.range == nil && $0.link == nil })
  }

  /// Every next-meeting value the manual, the README and the reference
  /// configuration name is a segment the plugin declares, the calendar
  /// guide documents each of them, and none still uses a retired name.
  func testTheDocumentedNextMeetingValuesAreThePluginsSegments() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "calendar" })
    let names = Set(
      try PluginManifest.load(from: root).status.map { "flash.plugin.calendar.\($0)" })
    let segment = try NSRegularExpression(pattern: #"flash\.plugin\.calendar\.[a-z_]+"#)
    let retired = try NSRegularExpression(
      pattern: #"flash\.calendar\.next[a-z_]*|\[calendar\](?!\()"#)
    func tokens(_ pattern: NSRegularExpression, _ path: String) throws -> Set<String> {
      let text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
      return Set(
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
          Range($0.range, in: text).map { String(text[$0]) }
        })
    }
    XCTAssertEqual(try tokens(segment, "docs/calendar.md"), names)
    let docs = repository.appendingPathComponent("docs")
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: docs.path))
    let pages = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }
      .map { "docs/\($0)" }
    for path in pages + ["README.md", "config.default.toml"] {
      let unknown = try tokens(segment, path).subtracting(names)
      XCTAssertTrue(unknown.isEmpty, "\(path) names \(unknown.sorted())")
      XCTAssertEqual(try tokens(retired, path), [], path)
    }
  }

  /// The process tables, the focused app's summary, `@processes` and
  /// `process kill` are the `processes` plugin's: its segments, its live
  /// source of the shared `processes` type, and a word that is no topic of
  /// Flash's. `flash.top_cpu` and `[statusbar] top_count` name nothing.
  func testTheProcessesPluginOwnsTheProcessWordItsValuesAndItsType() throws {
    XCTAssertEqual(try bundledCommands()["process"], ["kill"])
    XCTAssertFalse(URLEventHandler.isTopic("process"), "process is the plugin's, not a topic")
    XCTAssertEqual(try owner(of: "process"), ["processes"])
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "processes" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.pluginCommands.map { "\($0.command) \($0.subcommand): \($0.prompt ?? "")" },
      ["process kill: Kill this process?"])
    XCTAssertEqual(manifest.sourceCommands, [], "it performs no core command")
    XCTAssertEqual(manifest.liveSources, .perQuery)
    XCTAssertEqual(manifest.sources.map(\.type), ["processes"])
    XCTAssertEqual(ResourceTypes.byName["processes"]?.owner, .shared)
    XCTAssertEqual(manifest.status, ["focused_app_details", "top_cpu", "top_mem"])
    XCTAssertTrue(manifest.isStatusBound)
    XCTAssertEqual(
      manifest.activation(statusObserved: false), .onDemand, "no process until a value is shown")
    XCTAssertEqual(manifest.activation(statusObserved: true), .resident)
    XCTAssertEqual(manifest.capabilities, [.appControl, .processInfo, .processSignal])
    XCTAssertEqual(manifest.sandboxSpec, PluginSandboxSpec(), "the default sandbox, no allowance")
    XCTAssertEqual(manifest.mappings.count, 0, "no default key was bound to it")

    // A mapping, the CLI and the command line keep the words.
    let kill = URLCommand.pluginCommand(
      command: "process", subcommand: "kill", args: ["--pid=4242"])
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "process", "kill", "--pid=4242"]), .flashCommand(kill))
    XCTAssertEqual(kill.argv, ["flash", "process", "kill", "--pid=4242"])
    XCTAssertNil(parseMappingCommand(argv: ["flash", "process"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "process", "renice"]))
    let inventory = NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: try bundledCommands())
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":proc kill --pid=42", inventory: inventory),
      .plugin(command: "process", subcommand: "kill", args: ["--pid=42"]), "proc is process")
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandLine(":process", inventory: inventory),
      .incomplete("process"), "the word alone terminates nothing")

    // The values are plugin segments, sized by a plugin setting.
    func diagnostics(_ toml: String) -> [String] {
      ConfigLoader.parse(toml).loadingDiagnostics.map(\.message)
    }
    let bar = ConfigLoader.parse(
      """
      [statusbar]
      enabled = true
      template = "#{flash.plugin.processes.top_cpu}"

      [popup.app]
      text = "#{flash.plugin.processes.focused_app_details}"
      """)
    XCTAssertEqual(bar.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      bar.statusSegmentsRead()["processes"], ["top_cpu", "focused_app_details"])
    for retired in ["flash.top_cpu", "flash.top_mem", "flash.focused_app_details"] {
      let reported = diagnostics("[statusbar]\ntemplate = \"#{\(retired)}\"")
      XCTAssertTrue(
        reported.contains { $0.contains("unknown Flash value \(retired)") }, "\(reported)")
    }
    let moved = diagnostics("[statusbar]\ntop_count = 5")
    XCTAssertTrue(moved.contains { $0.contains("top_count") }, "\(moved)")
    XCTAssertEqual(manifest.settings["top_count"]?.type, .integer)
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
