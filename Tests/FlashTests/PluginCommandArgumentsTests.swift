import AppKit
import XCTest

@testable import flash

/// A plugin's own command declares its arguments in its manifest entry, and
/// the host holds every invocation to them before anything else happens: a
/// mapping when the configuration loads, the command line and the CLI when
/// the words resolve, and a question before it is asked.
final class PluginCommandArgumentsTests: XCTestCase {
  /// The bundled plugins these tests load: none starts a process until one
  /// of its commands runs, and no test here lets one run.
  private static let loaded: Set<String> = ["processes", "caffeinate", "system"]

  private static func config() throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(loaded)
    config.plugins.watchingEnabled = false
    return config
  }

  /// A resident with the plugins loaded and the host's signal mechanism
  /// replaced by one that records and signals nothing.
  private func resident() throws -> (delegate: AppDelegate, signals: ProcessSignalStub) {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let manager = delegate.pluginManager
    let signals = ProcessSignalStub()
    manager.hostRPC.processSignals = signals
    let config = try Self.config()
    delegate.config = config
    delegate.registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    delegate.monitor = AppMonitor(registry: delegate.registry, config: config)
    delegate.overlay = OverlayPanel()
    addTeardownBlock {
      manager.stop()
      delegate.overlay.dismissAlert()
      delegate.overlay.orderOut(nil)
    }
    manager.start(config: config)
    waitUntilTrue("plugins loaded") {
      Set(manager.pluginStatuses().map(\.id)) == Self.loaded
    }
    return (delegate, signals)
  }

  private func run(_ delegate: AppDelegate, _ words: [String]) -> CommandInvocationResult {
    let answered = expectation(description: words.joined(separator: " "))
    var result = CommandInvocationResult.failed("no answer")
    delegate.runInvocation(CommandInvocation(words: words), surface: .cli) {
      result = $0
      answered.fulfill()
    }
    wait(for: [answered], timeout: 15)
    return result
  }

  // MARK: - Before a confirmation

  /// `flash process kill --pid=1` and `flash process kill` are refused when
  /// the words resolve, as a core command's bad arguments are: no question
  /// is asked and no plugin is started. A pid the declaration accepts asks.
  func testArgumentsAreRefusedBeforeTheQuestionIsAsked() throws {
    let (delegate, signals) = try resident()
    for words in [
      ["process", "kill", "--pid=1"], ["process", "kill"], ["process", "kill", "--pid=0"],
      ["process", "kill", "--pid=abc"], ["process", "kill", "--pid=4242", "--force"],
      ["process", "kill", "4242"], ["process", "kill", "--pid=4242", "--pid=4243"],
      ["system", "restart", "--now"], ["trash", "empty", "all"],
    ] {
      XCTAssertEqual(
        run(delegate, words),
        .rejected("unknown command or invalid arguments: \(words.joined(separator: " "))"),
        "\(words)")
      XCTAssertNil(delegate.hintSession.confirmation, "\(words) asked")
    }
    // A key reaches dispatch with the command its mapping parsed: words the
    // declaration refuses ask nothing there either.
    for args in [["--pid=1"], [], ["--pid=4242", "--force"]] {
      let kill = URLCommand.pluginCommand(command: "process", subcommand: "kill", args: args)
      XCTAssertTrue(delegate.handleURLCommand(kill))
      XCTAssertNil(delegate.hintSession.confirmation, "\(args) asked")
    }
    XCTAssertTrue(
      delegate.pluginManager.pluginStatuses().allSatisfy { $0.pid == nil },
      "a refused command starts no plugin")

    XCTAssertEqual(run(delegate, ["process", "kill", "--pid=4242"]), .succeeded())
    XCTAssertEqual(delegate.hintSession.confirmation?.prompt, "Kill this process?")
    delegate.overlayDidConfirm(accepted: false)
    XCTAssertNil(delegate.hintSession.confirmation)
    settleRunLoop(0.2)
    XCTAssertEqual(signals.sent, [], "nothing was signalled")
  }

  // MARK: - flash config check

  private func checked(_ argv: [String]) -> [String] {
    let words = argv.map { "\"\($0)\"" }.joined(separator: ", ")
    return ConfigCheck.rows(
      fileURL: URL(fileURLWithPath: "/tmp/flash.toml"),
      text: "[mode.all.mappings]\n\"cmd+shift+[\" = [\(words)]\n",
      defaultLayer: nil, pluginSettings: nil
    ).map(\.message)
  }

  /// A mapping to a plugin command is held to the command's declaration
  /// when the configuration loads, with the message a core command's bad
  /// arguments get.
  func testConfigCheckHoldsAMappingToTheDeclaredArguments() {
    for argv in [
      ["flash", "process", "kill", "--pid=abc"], ["flash", "process", "kill"],
      ["flash", "process", "kill", "--pid=1"], ["flash", "process", "kill", "--pid=2", "--now"],
      ["flash", "caffeinate", "on", "--minutes=x"], ["flash", "caffeinate", "on", "--minutes=0"],
      ["flash", "caffeinate", "toggle", "--hours=1"],
      ["flash", "caffeinate", "off", "--minutes=5"],
      ["flash", "screen", "lock", "--now"], ["flash", "system", "sleep", "now"],
      ["flash", "audio", "output", "--device=Studio Speakers", "--loud"],
      ["flash", "audio", "input", "--device="], ["flash", "audio", "output", "Studio"],
      ["flash", "volume", "up", "--steps=2"], ["flash", "media", "status", "--json"],
      ["flash", "calendar", "join", "--now"], ["flash", "notes", "open", "today"],
      ["flash", "tmux", "session"], ["flash", "tmux", "window", "main:1", "extra"],
      ["flash", "tmux", "session", "--name=main"], ["flash", "screenshot", "window", "--quiet"],
    ] {
      XCTAssertEqual(
        checked(argv),
        [
          "mapping \"cmd+shift+[\": Unsupported command or invalid arguments: "
            + "\(argv.joined(separator: " ")). Check the command and its configuration or mapping."
        ], "\(argv)")
    }
    for argv in [
      ["flash", "process", "kill", "--pid=4242"], ["flash", "caffeinate", "on"],
      ["flash", "caffeinate", "on", "--minutes=60"], ["flash", "caffeinate", "toggle"],
      ["flash", "screen", "lock"], ["flash", "audio", "output"],
      ["flash", "audio", "output", "--device=Studio Speakers"], ["flash", "volume", "up"],
      ["flash", "tmux", "session", "main"], ["flash", "tmux", "window", "main:1"],
      ["flash", "screenshot", "window"],
    ] {
      XCTAssertEqual(checked(argv), [], "\(argv)")
    }
  }

  // MARK: - The declaration

  private func manifest(_ commands: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-command-args-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = """
      {
        "id": "example", "name": "example", "version": "0.1.0", "description": "test",
        "exec": ["./p"], "commands": [\(commands)]
      }
      """
    try json.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }

  private func declared(_ args: String) throws -> DeclaredArguments {
    let manifest = try manifest(
      #"{ "command": "example", "subcommand": "run", "args": [\#(args)] }"#)
    return try XCTUnwrap(manifest.pluginCommands.first?.arguments)
  }

  /// The four types, a required argument and the positional, each held to
  /// what it declares, and the one spelling the plugin receives.
  func testAnInvocationIsHeldToTheDeclarationAndGivenOneSpelling() throws {
    let arguments = try declared(
      """
      { "name": "target", "type": "string", "positional": true, "required": true },
      { "name": "pid", "type": "integer", "min": 2, "max": 99, "required": true },
      { "name": "mode", "type": "enum", "values": ["fast", "slow"] },
      { "name": "label", "type": "string" },
      { "name": "dry_run", "type": "flag" }
      """)
    XCTAssertEqual(
      arguments.syntax, "<target> --pid=<n> [--mode=<fast|slow>] [--label=<label>] [--dry-run]")
    XCTAssertTrue(arguments.requiresArguments)
    // Any order in, declaration order out; a number in plain decimal, a flag
    // only when on, `-` and `_` one name.
    XCTAssertEqual(
      arguments.canonical(["--dry-run", "--mode=slow", "--pid=+007", "main:1"]),
      ["main:1", "--pid=7", "--mode=slow", "--dry-run"])
    XCTAssertEqual(
      arguments.canonical(["two words", "--pid=99", "--dry_run=true", "--label=a b"]),
      ["two words", "--pid=99", "--label=a b", "--dry-run"])
    XCTAssertEqual(arguments.canonical(["x", "--pid=2", "--dry-run=0"]), ["x", "--pid=2"])
    XCTAssertEqual(arguments.canonical(["x", "--pid=2", "--dry-run=false"]), ["x", "--pid=2"])
    let canonical = try XCTUnwrap(arguments.canonical(["x", "--pid=2", "--mode=fast"]))
    XCTAssertEqual(arguments.canonical(canonical), canonical, "its own spelling is accepted")
    for refused in [
      ["--pid=2"],  // the positional is required
      ["x"],  // so is the pid
      ["x", "y", "--pid=2"],  // one bare word
      ["x", "--pid=1"], ["x", "--pid=100"], ["x", "--pid=2.5"], ["x", "--pid="],
      ["x", "--pid"], ["x", "--pid=two"], ["x", "--pid=2", "--pid=3"],
      ["x", "--pid=2", "--mode=medium"], ["x", "--pid=2", "--mode"],
      ["x", "--pid=2", "--label="], ["x", "--pid=2", "--label= "],
      ["x", "--pid=2", "--dry-run=yes"], ["x", "--pid=2", "--force"],
      ["x", "--pid=2", "--target=y"], [" ", "--pid=2"], ["", "--pid=2"],
      ["x", "--pid=2", "--"], ["x", "--pid=2", "--=1"],
    ] {
      XCTAssertNil(arguments.canonical(refused), "\(refused)")
    }
    // Bounds are each optional.
    let open = try declared(#"{ "name": "offset", "type": "integer" }"#)
    XCTAssertEqual(open.canonical(["--offset=-12"]), ["--offset=-12"])
    XCTAssertEqual(open.canonical([]), [])
    XCTAssertFalse(open.requiresArguments)
  }

  /// An entry without `args` takes no arguments, and the `*` wildcard keeps
  /// the words after the command as typed: it declares nothing.
  func testWithoutADeclarationACommandTakesNoArguments() throws {
    let manifest = try manifest(
      """
      { "command": "example", "subcommand": "run" },
      { "command": "example", "subcommand": "*" }
      """)
    let run = try XCTUnwrap(manifest.pluginCommands.first { $0.subcommand == "run" })
    XCTAssertEqual(run.arguments, DeclaredArguments.none)
    XCTAssertEqual(run.arguments?.canonical([]), [])
    for words in [["now"], ["--now"], ["--pid=4"], [""]] {
      XCTAssertNil(run.arguments?.canonical(words), "\(words)")
    }
    let wildcard = try XCTUnwrap(manifest.pluginCommands.first { $0.subcommand == "*" })
    XCTAssertNil(wildcard.arguments, "the wildcard's words are the plugin's")
  }

  /// A malformed declaration fails the load, as the SDK's `plugin!` fails
  /// the build (`command_args` in protocol.json).
  func testAMalformedDeclarationFailsTheLoad() throws {
    func error(_ commands: String) -> String {
      do {
        _ = try manifest(commands)
        return "loaded"
      } catch {
        return "\(error)"
      }
    }
    func run(_ args: String) -> String {
      error(#"{ "command": "example", "subcommand": "run", "args": [\#(args)] }"#)
    }
    let cases: [(String, String)] = [
      (#"{ "name": "pid", "type": "number" }"#, "type must be integer, string, enum, flag"),
      (#"{ "name": "Pid", "type": "integer" }"#, "name must be a word"),
      (#"{ "name": "pid", "type": "integer", "minimum": 1 }"#, "unknown field minimum"),
      (#"{ "name": "pid", "type": "integer", "min": 9, "max": 1 }"#, "min is above max"),
      (#"{ "name": "who", "type": "string", "max": 9 }"#, "min and max come with an integer"),
      (#"{ "name": "mode", "type": "enum" }"#, "an enum lists 1 to 64 distinct values"),
      (#"{ "name": "mode", "type": "enum", "values": [] }"#, "an enum lists"),
      (#"{ "name": "mode", "type": "enum", "values": ["a", "a"] }"#, "an enum lists"),
      (#"{ "name": "mode", "type": "enum", "values": ["a b"] }"#, "an enum lists"),
      (#"{ "name": "mode", "type": "enum", "values": ["--a"] }"#, "an enum lists"),
      (#"{ "name": "who", "type": "string", "values": ["a"] }"#, "values come with an enum"),
      (#"{ "name": "now", "type": "flag", "required": true }"#, "cannot be required"),
      (#"{ "name": "n", "type": "integer", "positional": true }"#, "only a string"),
      (#"{ "name": "who", "type": "string", "description": " " }"#, "one non-empty line"),
      (#"{ "name": "who", "type": "string", "description": "a\nb" }"#, "one non-empty line"),
      (
        #"{ "name": "who", "type": "string" }, { "name": "who", "type": "flag" }"#,
        "args repeat a name"
      ),
      (
        """
        { "name": "a", "type": "string", "positional": true },
        { "name": "b", "type": "string", "positional": true }
        """, "takes one positional at most"
      ),
      (
        (0...PluginProtocol.maxCommandArgs).map { #"{ "name": "a\#($0)", "type": "flag" }"# }
          .joined(separator: ","), "declares more than 16 args"
      ),
    ]
    for (args, expected) in cases {
      let reported = run(args)
      XCTAssertTrue(reported.contains(expected), "\(args): \(reported)")
      XCTAssertTrue(reported.contains("manifest.json commands"), reported)
    }
    XCTAssertTrue(run(#"{ "type": "integer" }"#) != "loaded", "a name is required")
    XCTAssertTrue(run(#"{ "name": "pid" }"#) != "loaded", "a type is required")
    // Only a named command of the plugin's own declares arguments.
    let who = #""args": [{ "name": "who", "type": "string" }]"#
    XCTAssertTrue(
      error(#"{ "command": "example", "subcommand": "*", \#(who) }"#)
        .contains("the * wildcard takes its words as typed"))
    XCTAssertTrue(
      error(#"{ "command": "tab", "subcommand": "close", \#(who) }"#)
        .contains("a core command's arguments are Flash's"))
    XCTAssertEqual(
      error(#"{ "command": "tab", "subcommand": "close", "args": [] }"#), "loaded",
      "no arguments declared is no declaration")
  }

  // MARK: - Completion and help

  /// The command line offers a plugin command's declared arguments, and
  /// keeps the line open for one it requires.
  func testTheCommandLineOffersTheDeclaredArguments() throws {
    let (delegate, _) = try resident()
    let inventory = delegate.makeCommandLineInventory()
    func completions(_ line: String) -> NormalModeDispatcher.CommandLineCompletionContext? {
      NormalModeDispatcher.commandLineCompletions(line, inventory: inventory)
    }
    // `process kill` needs its pid: Enter on the row leaves the line open.
    let kill = try XCTUnwrap(completions(":process ")?.items.first { $0.label == "kill" })
    XCTAssertEqual(kill.insertion, "kill ")
    XCTAssertEqual(kill.kind, .acceptsArgs)
    // `caffeinate on` runs as it is; its bound is optional.
    let on = try XCTUnwrap(completions(":caffeinate ")?.items.first { $0.label == "on" })
    XCTAssertEqual(on.insertion, "on")
    XCTAssertEqual(on.kind, .pluginSubcommand)

    let pid = try XCTUnwrap(completions(":process kill "))
    XCTAssertEqual(pid.prefix, ":process kill ")
    XCTAssertEqual(pid.query, "")
    XCTAssertEqual(pid.items.map(\.label), ["--pid="])
    XCTAssertEqual(pid.items.map(\.insertion), ["--pid="])
    XCTAssertEqual(pid.items.map(\.kind), [.acceptsArgs])
    XCTAssertEqual(pid.items.map(\.detail), ["The process to terminate"])
    XCTAssertNil(pid.selectedLabel, "nothing typed selects nothing")

    let minutes = try XCTUnwrap(completions(":caffeinate on --m"))
    XCTAssertEqual(minutes.prefix, ":caffeinate on ")
    XCTAssertEqual(minutes.query, "--m")
    XCTAssertEqual(minutes.items.map(\.label), ["--minutes="])
    XCTAssertEqual(minutes.selectedLabel, "--minutes=", "the typed prefix names it")
    // Prefixes resolve as dispatch resolves them.
    XCTAssertEqual(completions(":caff tog ")?.items.map(\.label), ["--minutes="])
    // A value the manifest cannot know, an argument already given and a
    // command without arguments list nothing.
    XCTAssertNil(completions(":process kill --pid="))
    XCTAssertNil(completions(":process kill --pid=42 "))
    XCTAssertNil(completions(":caffeinate off "))
    XCTAssertNil(completions(":screen lock "))
  }

  /// The shell completions and the man page list the bundled plugins'
  /// commands with their arguments, as they list Flash's own.
  func testTheShellCompletionsAndTheManPageListTheDeclaredArguments() {
    let zsh = CLIReference.completion(for: .zsh)
    XCTAssertTrue(zsh.contains("'process kill')"), "process kill has options")
    XCTAssertTrue(zsh.contains("'--pid=:--pid=<n>'"), "its pid is one")
    XCTAssertTrue(zsh.contains("'caffeinate on')"))
    XCTAssertTrue(zsh.contains("'--minutes=:[--minutes=<n>]'"))
    XCTAssertTrue(zsh.contains("'--device=:[--device=<device>]'"))
    let bash = CLIReference.completion(for: .bash)
    XCTAssertTrue(bash.contains("\"process kill\") options=\"--pid=\" ;;"))
    XCTAssertTrue(bash.contains("\"audio output\") options=\"--device=\" ;;"))
    let fish = CLIReference.completion(for: .fish)
    XCTAssertTrue(fish.contains("'__flash_at_command caffeinate toggle' -l minutes"))
    let man = CLIReference.manPage()
    XCTAssertTrue(man.contains("\\fBflash process kill\\fR \\-\\-pid=<n>"))
    XCTAssertTrue(man.contains("\\fBflash tmux session\\fR <name>"))
    XCTAssertTrue(man.contains("\\fBflash screen lock\\fR\n"))
  }

  /// A mapping to a plugin command is explained by what the command does,
  /// with the arguments it was given.
  func testAMappingIsExplainedByItsCommandsDescription() {
    XCTAssertEqual(
      URLCommand.pluginCommand(command: "screen", subcommand: "lock", args: []).explanation,
      "Lock the screen.")
    XCTAssertEqual(
      URLCommand.pluginCommand(
        command: "caffeinate", subcommand: "on", args: ["--minutes=30"]
      ).explanation,
      "Keep the Mac awake, for --minutes or until caffeinate off (--minutes=30).")
    XCTAssertEqual(
      URLCommand.pluginCommand(
        command: "process", subcommand: "kill", args: ["--pid=4242"]
      ).explanation,
      "Terminate one process, after asking (--pid=4242).")
  }

  /// The rows survive the list's ranking, and a typed prefix highlights
  /// the one row it names.
  func testTheArgumentRowsRankAndHighlightInTheList() throws {
    let inventory = NormalModeDispatcher.CommandLineInventory.core(
      pluginCommands: ["example": ["run"]],
      pluginArguments: [
        "example run": DeclaredArguments(parameters: [
          CommandParameter(name: "target", kind: .text("target"), required: true, positional: true),
          CommandParameter(
            name: "pid", kind: .integer(min: 2, max: nil), required: true, summary: "The process"),
          CommandParameter(name: "mode", kind: .choice(["fast", "slow", "safe"]), required: false),
          CommandParameter(name: "dry_run", kind: .flag, required: false),
        ])
      ])
    func completions(_ line: String) -> NormalModeDispatcher.CommandLineCompletionContext? {
      NormalModeDispatcher.commandLineCompletions(line, inventory: inventory)
    }
    // The positional is a bare word: nothing lists it, and typing it lists
    // nothing.
    let all = try XCTUnwrap(completions(":example run "))
    XCTAssertEqual(all.items.map(\.label), ["--pid=", "--mode=", "--dry-run"])
    XCTAssertEqual(all.items.map(\.kind), [.acceptsArgs, .acceptsArgs, .terminal])
    XCTAssertEqual(all.items.map(\.detail), ["The process", nil, nil])
    XCTAssertNil(completions(":example run ma"))
    var list = CommandLineCompletionList()
    list.update(context: all, boost: { _ in 0 })
    XCTAssertEqual(
      list.matches.map(\.completion.label).sorted(), ["--dry-run", "--mode=", "--pid="])
    XCTAssertNil(list.selected, "the empty word highlights no row")

    // Arguments already given are not offered again, `_` or `-`.
    let rest = try XCTUnwrap(completions(":example run main --pid=4 --dry_run --"))
    XCTAssertEqual(rest.prefix, ":example run main --pid=4 --dry_run ")
    XCTAssertEqual(rest.items.map(\.label), ["--mode="])
    list.update(context: rest, boost: { _ in 0 })
    XCTAssertEqual(list.selected?.label, "--mode=")
    XCTAssertEqual(
      list.buffer(inserting: try XCTUnwrap(list.selected)),
      ":example run main --pid=4 --dry_run --mode=")

    // After `--mode=`, the values it enumerates.
    let values = try XCTUnwrap(completions(":example run main --mode="))
    XCTAssertEqual(values.prefix, ":example run main --mode=")
    XCTAssertEqual(values.query, "")
    XCTAssertEqual(values.items.map(\.label), ["fast", "slow", "safe"])
    XCTAssertTrue(values.items.allSatisfy { $0.kind == .terminal })
    XCTAssertNil(values.selectedLabel)
    let typed = try XCTUnwrap(completions(":example run main --mode=s"))
    XCTAssertEqual(typed.items.map(\.label), ["slow", "safe"])
    XCTAssertTrue(typed.ambiguous, "two values share the prefix")
    let one = try XCTUnwrap(completions(":example run main --mode=sl"))
    XCTAssertEqual(one.selectedLabel, "slow")
    list.update(context: one, boost: { _ in 0 })
    XCTAssertEqual(
      list.buffer(inserting: try XCTUnwrap(list.selected)), ":example run main --mode=slow")
    XCTAssertNil(completions(":example run main --mode=x"))
    XCTAssertNil(completions(":example run main --mode=slow"), "a whole value")
    XCTAssertNil(completions(":example run main --dry-run"), "a whole flag")
    XCTAssertNil(completions(":example run main --pid="), "a number has no list")
    XCTAssertNil(completions(":example run main --color="), "not an argument")
    XCTAssertNil(completions(":example nope "), "no such subcommand")
  }

  /// Flash's own commands list their arguments the same way, from the
  /// command table; an ex command takes none.
  func testFlashsOwnCommandsOfferTheirArgumentsToo() throws {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    func labels(_ line: String) -> [String]? {
      NormalModeDispatcher.commandLineCompletions(line, inventory: inventory)?.items.map(\.label)
    }
    XCTAssertEqual(labels(":app open "), ["--name="])
    XCTAssertEqual(labels(":app quit --"), ["--force"])
    XCTAssertEqual(labels(":app qui "), ["--force"], "the action resolves by its prefix")
    XCTAssertEqual(labels(":mouse warp --area="), ["window", "screen"])
    XCTAssertEqual(labels(":config check "), ["--file="], "a query's options")
    XCTAssertEqual(labels(":cli completion --shell="), ["zsh", "bash", "fish"])
    XCTAssertNil(labels(":app open --name=Saf"), "free text")
    XCTAssertNil(labels(":tab next "), "no argument to offer")
    XCTAssertNil(labels(":tabn 3 "), "an ex command")
    XCTAssertNil(labels(":open -a "), "open forwards its words")
  }

  /// The catalog shows a plugin command with the arguments it declares, as
  /// it shows Flash's own.
  func testTheCatalogSyntaxOfABundledCommandIsItsDeclaration() throws {
    func syntax(_ command: String, _ subcommand: String) -> String? {
      PluginRepository.declaredCommand(command, subcommand: subcommand)?.arguments?.syntax
    }
    XCTAssertEqual(syntax("process", "kill"), "--pid=<n>")
    XCTAssertEqual(syntax("caffeinate", "on"), "[--minutes=<n>]")
    XCTAssertEqual(syntax("caffeinate", "toggle"), "[--minutes=<n>]")
    XCTAssertEqual(syntax("audio", "input"), "[--device=<device>]")
    XCTAssertEqual(syntax("audio", "output"), "[--device=<device>]")
    XCTAssertEqual(syntax("tmux", "session"), "<name>")
    XCTAssertEqual(syntax("tmux", "window"), "<target>")
    XCTAssertEqual(syntax("screen", "lock"), "")
  }
}
