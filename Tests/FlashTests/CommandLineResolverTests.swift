import Foundation
import XCTest

@testable import flash

/// The command line, and the `flash` CLI with it, resolves each word by its
/// unique prefix among the commands available right now, and a vim ex alias
/// by its declared minimum. Config files and mappings stay canonical.
final class CommandLineResolverTests: XCTestCase {
  private typealias Resolution = NormalModeDispatcher.CommandLineResolution

  /// Flash's own table plus a few plugin commands and help topics.
  private let inventory = NormalModeDispatcher.CommandLineInventory.core(
    pluginCommands: [
      "screenshot": ["window", "screen", "selection"],
      "tmux": ["session", "window"],
      "calc": ["*"],
    ],
    helpTopics: ["plugins", "config", "commands", "normal-mode"])

  private func resolve(_ line: String) -> Resolution {
    NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
  }

  private func core(_ words: String) -> URLCommand {
    URLEventHandler.parse(words: words.split(separator: " ").map(String.init))!
  }

  // MARK: - CLI words

  /// The regression: an empty CLI word (a quoted variable that is unset)
  /// matched every topic as a prefix, so `flash ""` and `flash tab "" next`
  /// were ambiguous where the command line ignores the extra space.
  func testEmptyWordsReadAsTheCommandLineReadsExtraSpaces() {
    func words(_ words: [String]) -> Resolution {
      NormalModeDispatcher.resolveCommandWords(words, inventory: inventory)
    }
    XCTAssertEqual(words([""]), resolve(":"))
    XCTAssertEqual(words(["  "]), .empty)
    XCTAssertEqual(words(["tab", "", "next"]), resolve(":tab  next"))
    XCTAssertEqual(words(["", "tab", "next"]), .commands([.tabNext]))
    XCTAssertEqual(words(["tab", "next", " "]), .commands([.tabNext]))
  }

  // MARK: - Unique prefixes

  func testAWordResolvesByItsUniquePrefixAtItsPosition() {
    XCTAssertEqual(resolve(":ta nex"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":tab nex"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":mou gr"), .commands([core("mouse grid")]))
    XCTAssertEqual(
      resolve(":screensh w"), .plugin(command: "screenshot", subcommand: "window", args: []))
    XCTAssertEqual(resolve("ta nex"), .commands([.tabNext]), "the prompt's colon is optional")
    XCTAssertEqual(
      resolve(":win foc --direction=left"), .commands([.focusWindow(.direction(.left))]))
  }

  func testAnAmbiguousOrUnknownPrefixResolvesNothing() {
    XCTAssertEqual(resolve(":ta n"), .ambiguous(["new", "next"]))
    XCTAssertEqual(resolve(":ta ne"), .ambiguous(["new", "next"]))
    XCTAssertEqual(resolve(":ma"), .ambiguous(["macro", "mappings", "mark"]))
    XCTAssertEqual(resolve(":sta"), .ambiguous(["startup", "status"]))
    // `mouse` has both `gesture` and `grid`.
    XCTAssertEqual(resolve(":mou g"), .ambiguous(["gesture", "grid"]))
    // `scr` starts `screen`, `screensaver`, `screenshot` and `scroll` alike.
    XCTAssertEqual(
      resolve(":scr w"), .ambiguous(["screen", "screensaver", "screenshot", "scroll"]))
    XCTAssertEqual(resolve(":zzz"), .unknown)
    XCTAssertEqual(resolve(":tab zzz"), .unknown)
    XCTAssertEqual(resolve(":"), .empty)
    XCTAssertEqual(resolve(":   "), .empty)
  }

  func testAnExactWordWinsOverALongerWordItPrefixes() {
    XCTAssertEqual(
      NormalModeDispatcher.matchCommandLineWord("tab", among: ["tabs", "tab"]), .exact("tab"))
    XCTAssertEqual(
      NormalModeDispatcher.matchCommandLineWord("ta", among: ["tabs", "tab"]),
      .ambiguous(["tab", "tabs"]))
    XCTAssertEqual(
      NormalModeDispatcher.matchCommandLineWord("tabs", among: ["tabs", "tab"]), .exact("tabs"))
    XCTAssertEqual(
      NormalModeDispatcher.matchCommandLineWord("x", among: ["tabs", "tab"]), .none)
    // `new` is exact even though `next` shares its first two letters.
    XCTAssertEqual(resolve(":tab new"), .commands([.tabNew]))
  }

  func testFlagsAreNeverAbbreviated() {
    XCTAssertEqual(resolve(":win foc --dir=left"), .unknown)
    XCTAssertEqual(resolve(":app rel --force"), .commands([.reload(force: true)]))
    XCTAssertEqual(resolve(":app rel --forc"), .unknown)
    // A word that is not a flag continues the value before it.
    XCTAssertEqual(
      resolve(":alert sh --message=hello there"),
      .commands([
        URLEventHandler.parse(topic: "alert", action: "show", args: ["message": "hello there"])!
      ]))
  }

  func testPluginCommandsAndSubcommandsAbbreviateToo() {
    XCTAssertEqual(
      resolve(":tm ses main"), .plugin(command: "tmux", subcommand: "session", args: ["main"]))
    XCTAssertEqual(resolve(":tmux w"), .plugin(command: "tmux", subcommand: "window", args: []))
    XCTAssertEqual(resolve(":tmux x"), .unknown)
    XCTAssertEqual(resolve(":tmux"), .incomplete("tmux"))
    // A wildcard subcommand takes the words as typed.
    XCTAssertEqual(
      resolve(":calc 2 + 2"), .plugin(command: "calc", subcommand: "2", args: ["+", "2"]))
  }

  /// A topic alone runs its only action when that action only shows a page
  /// or a surface (`impliedByItsTopic`); one that changes anything, as
  /// `screen lock` does, waits for its action to be typed.
  func testATopicAloneIsIncompleteUnlessItsOneActionOnlyShows() {
    XCTAssertEqual(resolve(":tab"), .incomplete("tab"))
    XCTAssertEqual(resolve(":ta"), .incomplete("tab"))
    XCTAssertEqual(resolve(":mappings"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":about"), .commands([.showAbout]))
    XCTAssertEqual(resolve(":plugins"), .incomplete("plugins"), "show and reload")
    XCTAssertEqual(resolve(":monitors"), .commands([.showMonitors]))
    XCTAssertEqual(resolve(":logs"), .commands([.showLogs]))
    XCTAssertEqual(resolve(":commands"), .commands([.showCommands]))
    XCTAssertEqual(resolve(":screen"), .incomplete("screen"), "screen lock changes something")
    XCTAssertEqual(resolve(":mappings s"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":cl"), .ambiguous(["cli", "clipboard"]), "`cl` is not `close`")
    XCTAssertEqual(resolve(":cli"), .incomplete("cli"), "completion and manpage")
  }

  /// The pages and the plugin reload are commands like `monitors show`, so
  /// a mapping can name them; only `doctor`, `open` and `flashlight` stay
  /// words of the command line.
  func testThePagesAndThePluginReloadAreCommands() {
    XCTAssertEqual(resolve(":plugins reload"), .commands([.reloadPlugins]))
    XCTAssertEqual(resolve(":plugins rel"), .commands([.reloadPlugins]))
    XCTAssertEqual(resolve(":logs show"), .commands([.showLogs]))
    XCTAssertEqual(resolve(":commands show"), .commands([.showCommands]))
    XCTAssertEqual(resolve(":doctor"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(resolve(":doct"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(resolve(":doctor now"), .unknown)
    XCTAssertEqual(resolve(":plugins reload extra"), .unknown)
    XCTAssertEqual(resolve(":plugins bogus"), .unknown)
    for words in [["plugins", "reload"], ["logs", "show"], ["commands", "show"]] {
      XCTAssertNotNil(parseMappingCommand(argv: ["flash"] + words), "\(words)")
    }
  }

  /// Abbreviations and aliases belong to what is typed — the command line
  /// and the CLI. A mapping and a config file reject them, because an
  /// abbreviation in a file would change meaning when a plugin adds a word.
  func testConfigAndMappingsRejectAbbreviationsAndAliases() {
    for argv in [
      ["flash", "ta", "nex"], ["flash", "tab", "nex"], ["flash", "q"], ["flash", "tabn"],
      ["flash", "wq"], ["flash", "mou", "grid"],
    ] {
      XCTAssertNil(parseMappingCommand(argv: argv), argv.joined(separator: " "))
    }
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "Q" = ["flash", "ta", "nex"]
      """
    )
    XCTAssertFalse(config.diagnostics.isEmpty)
  }

  // MARK: - Vim ex aliases

  func testEveryAliasResolvesFromItsMinimumToItsFullName() {
    for alias in NormalModeDispatcher.commandLineSpecs {
      // Alone, an alias runs its commands or its query; one that needs its
      // argument asks for it (`VimCommandTests`).
      let expected: Resolution
      if let query = alias.query {
        expected = .query(query, arguments: [:])
      } else {
        switch alias.trailing {
        case .tabIndex(required: true), .keys: expected = .incomplete(alias.names[0].full)
        case .tabOffset, .windowKey: expected = .unknown
        default: expected = .commands(alias.commands)
        }
      }
      for name in alias.names {
        let full = Array(name.full)
        for length in name.minimumLength...full.count {
          let typed = String(full.prefix(length))
          XCTAssertEqual(resolve(":" + typed), expected, typed)
        }
        if name.minimumLength > 1, expected != .unknown {
          let short = String(full.prefix(name.minimumLength - 1))
          XCTAssertNotEqual(resolve(":" + short), expected, short)
        }
      }
    }
  }

  func testTheAliasTableRunsTheMaintainedCommands() {
    XCTAssertEqual(resolve(":q"), .commands([.appClose]))
    XCTAssertEqual(resolve(":bd"), .commands([.tabClose]))
    XCTAssertEqual(resolve(":quit"), .commands([.appClose]))
    XCTAssertEqual(resolve(":qa"), .commands([.quitApp(force: false)]))
    XCTAssertEqual(resolve(":quita"), .commands([.quitApp(force: false)]))
    XCTAssertEqual(resolve(":clo"), .commands([.windowClose]))
    XCTAssertEqual(resolve(":close"), .commands([.windowClose]))
    XCTAssertEqual(resolve(":w"), .commands([.save]))
    XCTAssertEqual(resolve(":wq"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":x"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":xit"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":exi"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":wqa"), .commands([.saveAndQuit(force: false)]))
    XCTAssertEqual(resolve(":xa"), .commands([.saveAndQuit(force: false)]))
    XCTAssertEqual(resolve(":tabnew"), .commands([.tabNew]))
    XCTAssertEqual(resolve(":tabe"), .commands([.tabNew]))
    XCTAssertEqual(resolve(":tabc"), .commands([.tabClose]))
    XCTAssertEqual(resolve(":tabn"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":tabp"), .commands([.tabPrev]))
    XCTAssertEqual(resolve(":tabN"), .commands([.tabPrev]))
    XCTAssertEqual(resolve(":tabfir"), .commands([.tabFirst]))
    XCTAssertEqual(resolve(":tabr"), .commands([.tabFirst]))
    XCTAssertEqual(resolve(":tabl"), .commands([.tabLast]))
    XCTAssertEqual(resolve(":new"), .commands([.windowNew(private: false)]))
    XCTAssertEqual(resolve(":vne"), .commands([.windowNew(private: false)]))
    XCTAssertEqual(resolve(":sp"), .commands([.paneSplitHorizontal]))
    XCTAssertEqual(resolve(":vs"), .commands([.paneSplitVertical]))
    XCTAssertEqual(resolve(":u"), .commands([.undo]))
    XCTAssertEqual(resolve(":red"), .commands([.redo]))
    XCTAssertEqual(resolve(":e"), .commands([.documentOpen]))
    XCTAssertEqual(resolve(":h"), .commands([.showUsage(topic: nil)]))
    XCTAssertEqual(resolve(":map"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":ter"), .commands([.terminalMode(name: nil)]))
  }

  func testAliasCaseMattersAsInVim() {
    XCTAssertEqual(resolve(":tabN"), .commands([.tabPrev]))
    XCTAssertEqual(resolve(":tabn"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":TabN"), .unknown)
    XCTAssertEqual(resolve(":Q"), .unknown)
  }

  func testAnAliasMatchWinsOverAPrefix() {
    // `h` would be ambiguous among `help`, `hints` and `history`; `map` the
    // unique prefix of `mappings`; `u` of `url`; `w` of `window`.
    XCTAssertEqual(resolve(":h"), .commands([.showUsage(topic: nil)]))
    XCTAssertEqual(resolve(":map"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":u"), .commands([.undo]))
    XCTAssertEqual(resolve(":w"), .commands([.save]))
    XCTAssertEqual(resolve(":wr"), .commands([.save]))
    XCTAssertEqual(resolve(":wi"), .incomplete("window"), "not a spelling of write")
  }

  func testAnExactFlashCommandWinsOverTheHelpAlias() {
    XCTAssertEqual(resolve(":help show"), .commands([.showUsage(topic: nil)]))
    XCTAssertEqual(
      resolve(":help show --topic=plugins"), .commands([.showUsage(topic: "plugins")]))
    XCTAssertEqual(resolve(":help plugins"), .commands([.showUsage(topic: "plugins")]))
    XCTAssertEqual(resolve(":h plug"), .commands([.showUsage(topic: "plugins")]))
    XCTAssertEqual(resolve(":help c"), .ambiguous(["commands", "config"]))
    XCTAssertEqual(
      resolve(":help tmux"), .commands([.showUsage(topic: "tmux")]),
      "an unlisted topic goes through: the help server knows plugin guides")
  }

  func testAliasesTakeNoTrailingWordsUnlessDeclared() {
    XCTAssertEqual(resolve(":q now"), .unknown)
    XCTAssertEqual(resolve(":wq file"), .unknown)
    XCTAssertEqual(resolve(":help --topic=x"), .unknown)
  }

  /// `!` forces where the command can; the vim forms that discard changes
  /// (`:q!`, `:w!`, `:wq!`) run as without it, since Flash discards nothing;
  /// `:e!` is vim's revert, the app's, after asking; every other `!` is
  /// rejected.
  func testTheBangFormForcesOnlyWhereTheCommandCan() {
    XCTAssertEqual(resolve(":qa!"), .commands([.quitApp(force: true)]))
    XCTAssertEqual(resolve(":quitall!"), .commands([.quitApp(force: true)]))
    XCTAssertEqual(resolve(":wqa!"), .commands([.saveAndQuit(force: true)]))
    XCTAssertEqual(resolve(":xall!"), .commands([.saveAndQuit(force: true)]))
    XCTAssertEqual(resolve(":q!"), .commands([.appClose]))
    XCTAssertEqual(resolve(":w!"), .commands([.save]))
    XCTAssertEqual(resolve(":wq!"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":x!"), .commands([.save, .appClose]))
    XCTAssertEqual(resolve(":e!"), .commands([.documentRevert]), "vim's revert")
    XCTAssertEqual(resolve(":tabn!"), .unknown)
    XCTAssertEqual(resolve(":qa!!"), .unknown)
    XCTAssertEqual(resolve(":tab! next"), .unknown)
    XCTAssertEqual(resolve(":tab next!"), .unknown)
  }

  /// `:wq` saves, then runs `:q`; a save that fails stops the sequence.
  func testATwoStepAliasStopsAfterAFailedStep() {
    func run(saveOutcome: NormalModeCommandOutcome) -> [URLCommand] {
      var performed: [URLCommand] = []
      NormalModeDispatcher.runCommandSequence([.save, .appClose]) { command, done in
        performed.append(command)
        done(command == .save ? saveOutcome : .performed)
      }
      return performed
    }
    XCTAssertEqual(run(saveOutcome: .performed), [.save, .appClose])
    XCTAssertEqual(run(saveOutcome: .chordSent), [.save, .appClose])
    XCTAssertEqual(run(saveOutcome: .failed), [.save])
    XCTAssertEqual(run(saveOutcome: .noTarget), [.save])
  }

  /// An alias never hides a topic, a plugin command or another alias. Two
  /// are spelled like a topic: `h[elp]`, which runs that topic's only
  /// command, `help show`, and forwards its word to `--topic`, and vim's
  /// `di[splay]`, the registers, which leaves the words after it to the
  /// `display` topic. An exact `help show` or `display sleep` still wins.
  func testAliasNamesCollideWithNoTopicPluginOrEachOther() throws {
    let plugins = try SourceCommandFallbackTests.officialManifests().flatMap { manifest in
      manifest.commands.map(\.command)
    }
    let builtins = NormalModeDispatcher.commandLineBuiltinWords
    var claimed: [String: String] = [:]
    for alias in NormalModeDispatcher.commandLineSpecs {
      for name in alias.names {
        let full = name.full
        if URLEventHandler.isTopic(full) {
          // `h[elp]` runs its topic's only command; `di[splay]`, vim's
          // registers, leaves the words after it to its topic.
          XCTAssertTrue(["help", "display"].contains(full), "\(full) hides the \(full) topic")
          if full == "help" {
            XCTAssertEqual(alias.commands, [.showUsage(topic: nil)])
            XCTAssertEqual(alias.trailing, .helpTopic)
          } else {
            XCTAssertTrue(alias.yieldsWordsToTopic, full)
          }
        }
        XCTAssertFalse(plugins.contains(full), "\(full) hides a plugin command")
        XCTAssertFalse(builtins.contains(full), "\(full) hides a command-line builtin")
        XCTAssertFalse(full.contains("["), name.documented)
        for length in name.minimumLength...full.count {
          let typed = String(full.prefix(length))
          if let other = claimed[typed] {
            XCTFail("\(typed) is both \(other) and \(name.documented)")
          }
          claimed[typed] = name.documented
        }
      }
      // An alias runs something: its commands, its query, or what its
      // argument names.
      XCTAssertTrue(
        !alias.commands.isEmpty || alias.query != nil || alias.trailing != .rejected,
        alias.names.map(\.documented).joined())
    }
  }

  // MARK: - Completion agrees with dispatch

  private func completions(_ line: String) -> NormalModeDispatcher.CommandLineCompletionContext? {
    NormalModeDispatcher.commandLineCompletions(line, inventory: inventory)
  }

  func testCompletionSelectsWhatEnterWouldRun() throws {
    let next = try XCTUnwrap(completions(":ta nex"))
    XCTAssertEqual(next.prefix, ":tab ")
    XCTAssertEqual(next.selectedLabel, "next")
    XCTAssertFalse(next.ambiguous)

    let ambiguous = try XCTUnwrap(completions(":ta n"))
    XCTAssertNil(ambiguous.selectedLabel)
    XCTAssertTrue(ambiguous.ambiguous)
    XCTAssertTrue(ambiguous.items.map(\.label).contains("new"))
    XCTAssertTrue(ambiguous.items.map(\.label).contains("next"))

    let quit = try XCTUnwrap(completions(":q"))
    XCTAssertEqual(quit.selectedLabel, "quit")
    let item = try XCTUnwrap(quit.items.first { $0.label == "quit" })
    XCTAssertEqual(item.detail, "app close")
    XCTAssertEqual(item.kind, .terminal)
    XCTAssertTrue(quit.items.contains { $0.label == "qall" })
    XCTAssertEqual(completions(":qa")?.selectedLabel, "qall")

    let exit = try XCTUnwrap(completions(":ex"))
    XCTAssertNil(exit.selectedLabel, "`ex` is below `exi[t]`'s minimum")
    XCTAssertFalse(exit.ambiguous)
    XCTAssertTrue(exit.items.contains { $0.label == "exit" })

    let wq = try XCTUnwrap(completions(":wq"))
    XCTAssertEqual(wq.selectedLabel, "wq")
    XCTAssertEqual(wq.items.first { $0.label == "wq" }?.detail, "app save, then app close")
  }

  func testCompletionOfAnActionPositionFollowsTheSameRule() throws {
    let tab = try XCTUnwrap(completions(":tab "))
    XCTAssertNil(tab.selectedLabel)
    XCTAssertTrue(tab.ambiguous, "an empty action is every action")
    let mappings = try XCTUnwrap(completions(":mappings "))
    XCTAssertEqual(mappings.selectedLabel, "show")
    let plugin = try XCTUnwrap(completions(":screensh w"))
    XCTAssertEqual(plugin.prefix, ":screenshot ")
    XCTAssertEqual(plugin.selectedLabel, "window")
    let help = try XCTUnwrap(completions(":h "))
    XCTAssertEqual(help.prefix, ":help ")
    XCTAssertEqual(help.items.map(\.label), ["commands", "config", "normal-mode", "plugins"])
    XCTAssertEqual(completions(":he con")?.selectedLabel, "config")
    XCTAssertEqual(completions(":help c")?.ambiguous, true)
    XCTAssertNil(completions(":ta nex now"), "arguments end completion")
  }

  func testTheCatalogListsTheAliasesWithWhatTheyRun() {
    let catalog = NormalModeDispatcher.coreCommandCatalog()
    let quit = catalog.first { $0["name"] as? String == ":quit" }
    XCTAssertEqual(quit?["syntax"] as? String, ":q[uit]")
    XCTAssertEqual(quit?["description"] as? String, "app close")
    let xit = catalog.first { $0["name"] as? String == ":wq" }
    XCTAssertEqual(xit?["aliases"] as? [String], [":wq", ":x[it]", ":exi[t]"])
    XCTAssertTrue(catalog.contains { $0["name"] as? String == ":tab next" })
    XCTAssertTrue(catalog.contains { $0["name"] as? String == ":doctor" })
  }
}
