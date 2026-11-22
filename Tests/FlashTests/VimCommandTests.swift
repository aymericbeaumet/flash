import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// What a vim user types first: ex commands with their arguments, `.`,
/// macros, `:normal`, `:!` and the `ctrl+w` window keys — from the command
/// line and the CLI alike.
final class VimCommandTests: XCTestCase {
  private typealias Resolution = NormalModeDispatcher.CommandLineResolution
  private let inventory = NormalModeDispatcher.CommandLineInventory.core()

  private func resolve(_ line: String) -> Resolution {
    NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
  }

  private func command(_ words: String) -> URLCommand {
    URLEventHandler.parse(words: words.split(separator: " ").map(String.init))!
  }

  // MARK: - Ex commands

  func testBuffersAreTabs() {
    XCTAssertEqual(resolve(":bn"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":bp"), .commands([.tabPrev]))
    XCTAssertEqual(resolve(":bN"), .commands([.tabPrev]))
    XCTAssertEqual(resolve(":bf"), .commands([.tabFirst]))
    XCTAssertEqual(resolve(":br"), .commands([.tabFirst]))
    XCTAssertEqual(resolve(":bl"), .commands([.tabLast]))
    XCTAssertEqual(resolve(":b 3"), .commands([.tabSelect(index: 3)]))
    XCTAssertEqual(resolve(":buffer 12"), .commands([.tabSelect(index: 12)]))
    XCTAssertEqual(resolve(":b"), .incomplete("buffer"))
    XCTAssertEqual(resolve(":b x"), .unknown)
    XCTAssertEqual(resolve(":ls"), .commands([.windowSwitch]))
    XCTAssertEqual(resolve(":buffers"), .commands([.windowSwitch]))
    XCTAssertEqual(resolve(":files"), .commands([.windowSwitch]))
    XCTAssertEqual(resolve(":buffer"), .incomplete("buffer"), "`:buffer` still wants a position")
  }

  func testTabCommandsTakeAPositionOrAnOffset() {
    XCTAssertEqual(resolve(":tabn"), .commands([.tabNext]))
    XCTAssertEqual(resolve(":tabn 4"), .commands([.tabSelect(index: 4)]))
    XCTAssertEqual(resolve(":tabm +2"), .commands([.tabMoveNext, .tabMoveNext]))
    XCTAssertEqual(resolve(":tabmove -1"), .commands([.tabMovePrev]))
    XCTAssertEqual(resolve(":tabm 3"), .unknown, "an absolute position has no command")
    XCTAssertEqual(resolve(":tabm"), .unknown)
  }

  func testWincmdIsTheCtrlWWindowKey() {
    XCTAssertEqual(resolve(":winc l"), .commands([command("window focus --direction=right")]))
    XCTAssertEqual(resolve(":wincmd H"), .commands([command("window move --position=lefthalf")]))
    XCTAssertEqual(resolve(":winc o"), .commands([command("window move --position=maximized")]))
    XCTAssertEqual(resolve(":winc v"), .commands([.paneSplitVertical]))
    XCTAssertEqual(resolve(":winc z"), .unknown)
    XCTAssertEqual(resolve(":winc"), .unknown)
    // Every key `:winc` takes is a canonical command.
    for (key, words) in NormalModeDispatcher.windowCommandWords {
      XCTAssertNotNil(URLEventHandler.parse(words: words), "\(key)")
    }
  }

  func testRegistersAndTheRestOfTheVimVocabulary() {
    XCTAssertEqual(resolve(":up"), .commands([.save]))
    XCTAssertEqual(resolve(":y"), .commands([.yankSelection(register: nil)]))
    XCTAssertEqual(resolve(":y a"), .commands([.yankSelection(register: "a")]))
    XCTAssertEqual(resolve(":pu +"), .commands([.paste(register: "+")]))
    XCTAssertEqual(resolve(":y ab"), .unknown)
    XCTAssertEqual(resolve(":reg"), .commands([command("clipboard show")]))
    XCTAssertEqual(resolve(":so"), .commands([.configReload]))
    XCTAssertEqual(resolve(":source"), .commands([.configReload]))
    XCTAssertEqual(resolve(":ve"), .commands([.showAbout]))
    XCTAssertEqual(resolve(":star"), .commands([.insertMode]))
    XCTAssertEqual(resolve(":stopi"), .commands([.normalMode]))
    XCTAssertEqual(resolve(":sh"), .commands([.terminalMode(name: nil)]))
    XCTAssertEqual(resolve(":mes"), .commands([.showLogs]))
    XCTAssertEqual(resolve(":checkh"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(resolve(":stat"), .incomplete("status"), "a topic keeps its own prefix")
  }

  func testNormalAndShellTakeTheRestOfTheLine() {
    XCTAssertEqual(resolve(":norm 3gt"), .normalKeys("3gt"))
    XCTAssertEqual(resolve(":normal ctrl+w h"), .normalKeys("ctrl+w h"))
    XCTAssertEqual(resolve(":norm"), .incomplete("normal"))
    XCTAssertEqual(resolve(":!ls -la"), .shell("ls -la"))
    XCTAssertEqual(resolve(":! echo hi"), .shell("echo hi"))
    XCTAssertEqual(resolve(":!"), .incomplete("!"))
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandWords(["!git", "status"], inventory: inventory),
      .shell("git status"), "the CLI reads `flash '!git' status` alike")
  }

  func testNormalKeysReadACountARegisterAndTheLeader() throws {
    let plain = try XCTUnwrap(AppDelegate.normalKeys("3gt", leader: nil))
    XCTAssertEqual(plain.key, NormalModeInterpreter.canonicalizeMappingKey("gt"))
    XCTAssertEqual(plain.count, 3)
    XCTAssertNil(plain.register)
    let register = try XCTUnwrap(AppDelegate.normalKeys("\"ap", leader: nil))
    XCTAssertEqual(register.register, "a")
    XCTAssertEqual(register.key, NormalModeInterpreter.canonicalizeMappingKey("p"))
    let chord = try XCTUnwrap(AppDelegate.normalKeys("ctrl+w h", leader: nil))
    XCTAssertEqual(chord.key, NormalModeInterpreter.canonicalizeMappingKey("ctrl+w h"))
    let leader = try XCTUnwrap(AppDelegate.normalKeys("<leader>c", leader: "space"))
    XCTAssertFalse(leader.key.contains("<leader>"))
    XCTAssertNil(AppDelegate.normalKeys("<leader>c", leader: nil))
    XCTAssertNil(AppDelegate.normalKeys("3", leader: nil))
    // Every default the docs name resolves in the default table.
    let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)
    for keys in ["gt", "ctrl+w H", ".", "ZZ"] {
      let parsed = try XCTUnwrap(AppDelegate.normalKeys(keys, leader: nil), keys)
      XCTAssertNotNil(defaults.mapping(for: parsed.key), keys)
    }
  }

  /// The regression: `:normal 3gt` (and `flash normal 3gt`) ran `gt` three
  /// times, where typing `3gt` selects tab 3, and `:normal ma` was rejected,
  /// where typing it sets mark a. `:normal` keys mean what typing them means.
  func testNormalKeysMeanWhatTypingThemMeans() throws {
    let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)
    func action(_ keys: String) -> (action: MappingCommand, count: Int)? {
      AppDelegate.normalKeysAction(
        keys, leader: "space", mappings: defaults, recordingMacro: false)
    }
    let mark = try XCTUnwrap(MarkSlot(parsing: "a"))
    XCTAssertEqual(action("3gt")?.action, .flashCommand(.tabSelect(index: 3)))
    XCTAssertEqual(action("3gt")?.count, 1)
    XCTAssertEqual(action("gt")?.action, .flashCommand(.tabNext))
    XCTAssertEqual(action("ma")?.action, .flashCommand(.marks(.set(mark))))
    XCTAssertEqual(action("'a")?.action, .flashCommand(.marks(.jump(mark))))
    XCTAssertEqual(action("`a")?.action, .flashCommand(.marks(.jump(mark))))
    XCTAssertEqual(action("@a")?.action, .flashCommand(.macro(.play(register: "a"))))
    XCTAssertEqual(action("3@a")?.count, 3)
    XCTAssertEqual(action("\"ap")?.action, .flashCommand(.paste(register: "a")))
    XCTAssertEqual(action("3]t")?.action, .flashCommand(.tabNext))
    XCTAssertEqual(action("3]t")?.count, 3, "a count still repeats everything else")
    XCTAssertEqual(
      action("ctrl+w h")?.action, .flashCommand(command("window focus --direction=left")),
      "a chord is a mapping key")
    XCTAssertNil(action("gtx"), "keys after a command run nothing")
    XCTAssertNil(action("zzz"))
  }

  func testAShellCommandReportsItsStatusAndOutput() {
    let done = expectation(description: "shell")
    var result: (Int32, String)?
    AppDelegate.runShell("echo hi; echo err >&2; exit 3", directory: "/tmp") { status, output in
      result = (status, output)
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    XCTAssertEqual(result?.0, 3)
    XCTAssertEqual(result?.1, "hi\nerr")
  }

  // MARK: - Macros and `.`

  private let defaults = CompiledMappings(Config.Mode.defaultNormalMappings)

  private func key(
    _ char: String, pending: String = "", recording: Bool = false,
    mappings: CompiledMappings? = nil
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: 0, modifierFlags: char == "@" ? [.shift] : [],
      characters: char, charactersIgnoringModifiers: char == "@" ? "2" : char,
      mappings: mappings ?? defaults, recordingMacro: recording)
  }

  func testQAndAtNameARegisterToRecordAndPlay() {
    let q = key("q")
    XCTAssertNil(q.action)
    XCTAssertEqual(key("a", pending: q.pending).command, .macro(.record(register: "a")))
    XCTAssertEqual(key("q", recording: true).command, .macro(.stop), "q stops a recording")
    let at = key("@")
    XCTAssertEqual(key("b", pending: at.pending).command, .macro(.play(register: "b")))
    XCTAssertEqual(key("@", pending: at.pending).command, .macro(.play(register: nil)))
    // A count before `@` repeats the play.
    let count = key("3")
    let counted = key("@", pending: count.pending)
    let play = key("a", pending: counted.pending)
    XCTAssertEqual(play.command, .macro(.play(register: "a")))
    XCTAssertEqual(play.repeatCount, 3)
    // A key that names no register abandons the prefix and runs nothing.
    XCTAssertEqual(key(".", pending: q.pending), .consume)
    // A mapping on `q` wins over the macro key.
    let mapped = CompiledMappings(
      Config.Mode.defaultNormalMappings + [
        ModeMapping(key: "q", action: .flashCommand(.tabClose), repeatsOnFinalKey: false)
      ])
    XCTAssertEqual(key("q", mappings: mapped).command, .tabClose)
    // `.` is the default repeat.
    XCTAssertEqual(key(".").command, .macro(.repeatLast(count: nil)))
  }

  func testTheMacroStateRecordsCommandsAndRepeatsTheLastChange() {
    var state = MacroState()
    let next = MacroStep(action: .flashCommand(.tabNext), repeatCount: 2)
    let insert = MacroStep(action: .flashCommand(.insertMode), repeatCount: 1)
    state.note(next)
    XCTAssertEqual(state.lastStep, next)
    state.note(insert)
    XCTAssertEqual(state.lastStep, next, "a mode change is no change to repeat")
    state.startRecording("a")
    state.note(next)
    state.note(MacroStep(action: .flashCommand(.macro(.repeatLast(count: nil))), repeatCount: 1))
    state.note(insert)
    XCTAssertTrue(state.isRecording)
    XCTAssertEqual(state.stopRecording()?.count, 2, "macro commands are not recorded")
    XCTAssertFalse(state.isRecording)
    XCTAssertEqual(state.steps(for: "a")?.steps, [next, insert])
    XCTAssertEqual(state.steps(for: nil)?.register, "a", "@@ replays the last played")
    XCTAssertNil(state.steps(for: "z"))
    XCTAssertNil(state.stopRecording())
  }

  /// The regression: playing a macro while recording another recorded
  /// nothing, so `qb` `@a` `q` left `b` empty and the nested replay the
  /// manual promises (a macro replaying another, eight deep) never ran.
  func testARecordingKeepsTheMacrosItPlays() {
    var state = MacroState()
    let next = MacroStep(action: .flashCommand(.tabNext), repeatCount: 1)
    let playA = MacroStep(action: .flashCommand(.macro(.play(register: "a"))), repeatCount: 2)
    state.startRecording("b")
    state.note(next)
    state.note(playA)
    state.note(MacroStep(action: .flashCommand(.macro(.repeatLast(count: nil))), repeatCount: 1))
    state.note(MacroStep(action: .flashCommand(.macro(.record(register: "c"))), repeatCount: 1))
    XCTAssertEqual(state.stopRecording()?.count, 2)
    XCTAssertEqual(state.steps(for: "b")?.steps, [next, playA])
    XCTAssertEqual(state.lastStep, next, "a play is not what . repeats")
  }

  func testTheMacroCommandsAreCanonicalCommands() {
    XCTAssertEqual(command("macro record --register=a"), .macro(.record(register: "a")))
    XCTAssertEqual(command("macro play"), .macro(.play(register: nil)))
    XCTAssertEqual(command("macro play --register=Q"), .macro(.play(register: "q")))
    XCTAssertNil(URLEventHandler.parse(words: ["macro", "record", "--register=ab"]))
    XCTAssertNil(URLEventHandler.parse(words: ["macro", "record"]))
    XCTAssertEqual(command("macro repeat"), .macro(.repeatLast(count: nil)))
    XCTAssertEqual(command("config reload"), .configReload)
  }

  // MARK: - Marks, counts and the keys vim and Vimium users reach for

  private func keys(_ chars: String..., mappings: CompiledMappings? = nil) -> NormalModeTransition {
    var transition = NormalModeTransition.consume
    for char in chars {
      transition = key(char, pending: transition.pending, mappings: mappings)
    }
    return transition
  }

  func testMVimsMarkKeysSaveAndBringBackApps() throws {
    let a = try XCTUnwrap(MarkSlot(parsing: "a"))
    XCTAssertEqual(keys("m", "a").command, .marks(.set(a)), "m only begins mf, mF and ms")
    XCTAssertEqual(keys("'", "a").command, .marks(.jump(a)))
    XCTAssertEqual(keys("`", "a").command, .marks(.jump(a)))
    XCTAssertEqual(keys("m", "f").command, .mouseTarget(.move), "a mapping wins over a mark")
    XCTAssertEqual(keys("'").pending.isEmpty, false, "' waits for its mark")
    // A key that names no mark abandons the prefix and runs nothing.
    XCTAssertEqual(keys("'", "/"), .consume)
    XCTAssertEqual(keys("m", "/"), .consume)
    XCTAssertEqual(keys("'", "u").command, .marks(.jump(try XCTUnwrap(MarkSlot(parsing: "u")))))
  }

  func testAConfigMarkLikeMappingWinsAndOtherLettersStillJump() throws {
    let configured = CompiledMappings(
      Config.Mode.defaultNormalMappings + [
        ModeMapping(
          key: NormalModeInterpreter.canonicalizeMappingKey("'a")!,
          action: .flashCommand(.openApp(name: "Alacritty")))
      ])
    XCTAssertEqual(keys("'", "a", mappings: configured).command, .openApp(name: "Alacritty"))
    XCTAssertEqual(
      keys("'", "d", mappings: configured).command,
      .marks(.jump(try XCTUnwrap(MarkSlot(parsing: "d")))),
      "the config's ' prefix leaves unmapped letters to the marks")
  }

  func testACountBeforeGtGoesToThatTabAsInVim() {
    XCTAssertEqual(keys("g", "t").command, .tabNext)
    XCTAssertEqual(keys("3", "g", "t").command, .tabSelect(index: 3))
    let back = keys("3", "g", "T")
    XCTAssertEqual(back.command, .tabPrev)
    XCTAssertEqual(back.repeatCount, 3, "gT counts back, as in vim")
    let forward = keys("3", "]", "t")
    XCTAssertEqual(forward.command, .tabNext)
    XCTAssertEqual(forward.repeatCount, 3, "]t repeats")
  }

  func testTheNewDefaultKeysAreHighLevelCommands() {
    let actions = Dictionary(
      Config.Mode.defaultNormalMappings.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a }
    )
    func bound(_ raw: String) -> URLCommand? {
      actions[NormalModeInterpreter.canonicalizeMappingKey(raw)!]?.command
    }
    XCTAssertEqual(
      bound("v"), .visualMode(.charwise), "v is VISUAL; HOLD keeps its one toggle, cmd+ctrl+h")
    XCTAssertEqual(bound("zi"), .zoomIn)
    XCTAssertEqual(bound("zo"), .zoomOut)
    XCTAssertEqual(bound("z0"), .zoomReset)
    XCTAssertEqual(bound("gs"), .viewSource)
    XCTAssertEqual(bound("ctrl+w p"), .windowLast)
    XCTAssertNil(bound("yy"), "y resolves at once, so yy ships unbound")
    for command in [URLCommand.zoomIn, .zoomOut, .zoomReset, .viewSource] {
      XCTAssertNotNil(command.sourceCommand, "\(command) is the focused app's to perform")
    }
  }

  func testTheNewCommandsParse() {
    XCTAssertEqual(command("app zoom_in"), .zoomIn)
    XCTAssertEqual(command("app zoom_out"), .zoomOut)
    XCTAssertEqual(command("app zoom_reset"), .zoomReset)
    XCTAssertEqual(command("app view_source"), .viewSource)
    XCTAssertEqual(command("window last"), .windowLast)
    XCTAssertEqual(command("mouse target --copy-url"), .mouseTarget(.copyURL))
    for words in [
      "mouse target --copy-url --move", "mouse target --copy-url --secondary",
      "mouse target --copy-url --multi", "mouse target --copy-url --scope=screen",
      "mouse target --copy-url --words", "mouse grid --copy-url", "mouse bigram --copy-url",
      "window last --now",
    ] {
      XCTAssertNil(
        URLEventHandler.parse(words: words.split(separator: " ").map(String.init)), words)
    }
    XCTAssertEqual(
      URLCommand.mouseTarget(.copyURL).argv, ["flash", "mouse", "target", "--copy-url"])
  }

  /// `mouse target --copy-url` (Vimium's `yf`) labels only what has a URL.
  func testCopyURLLabelsOnlyTargetsWithAURL() {
    let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    let targets = [
      JumpTarget(id: "link", frame: frame, url: "https://example.test/", providerID: "ax"),
      JumpTarget(id: "button", frame: frame, providerID: "ax"),
      JumpTarget(id: "empty", frame: frame, url: "", providerID: "ax"),
    ]
    XCTAssertEqual(AppDelegate.urlTargets(targets).map(\.id), ["link"])
  }

  /// `mouse target --copy-text` (Wooshy's ⌘C) copies a target's text: it
  /// labels only targets with some, and takes no click shape.
  func testCopyTextParsesAndLabelsOnlyTargetsWithText() {
    XCTAssertEqual(command("mouse target --copy-text"), .mouseTarget(.copyText))
    XCTAssertEqual(
      URLCommand.mouseTarget(.copyText).argv, ["flash", "mouse", "target", "--copy-text"])
    for words in [
      "mouse target --copy-text --copy-url", "mouse target --copy-text --move",
      "mouse target --copy-text --multi", "mouse grid --copy-text",
      "mouse bigram --copy-text",
    ] {
      XCTAssertNil(
        URLEventHandler.parse(words: words.split(separator: " ").map(String.init)), words)
    }
    let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    let targets = [
      JumpTarget(id: "save", frame: frame, accessibilityLabel: "Save", providerID: "ax"),
      JumpTarget(id: "blank", frame: frame, accessibilityLabel: "  ", providerID: "ax"),
      JumpTarget(id: "none", frame: frame, providerID: "ax"),
    ]
    XCTAssertEqual(AppDelegate.textTargets(targets).map(\.id), ["save"])
    XCTAssertNil(
      HintSurfaceSwitching.request(from: .target(.copyText, nil), kind: .grid),
      "the grid has no text to copy")
  }
}
