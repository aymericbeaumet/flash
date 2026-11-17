import AppKit
import FlashCore
import XCTest

@testable import flash

/// Manifest `bindings`: the typed union a plugin declares per command and
/// app, keyed by the command line users type, its validation, the precedence
/// that picks one across plugins, and how the host dispatches each form.
final class CommandBindingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - Keys

  func testABindingKeyIsACommandLineWithItsBoolFlags() throws {
    let plain = try XCTUnwrap(CommandBindingKey("tab new"))
    XCTAssertEqual(plain.name, CommandName("tab", "new"))
    XCTAssertEqual(plain.flags, [])
    XCTAssertEqual(plain.description, "tab new")
    let forced = try XCTUnwrap(CommandBindingKey("app reload --force"))
    XCTAssertEqual(forced.name, CommandName("app", "reload"))
    XCTAssertEqual(forced.flags, ["force"])
    XCTAssertEqual(forced.description, "app reload --force")
    for malformed in [
      "tab_new", "tab", "tab new now", "tab new --index=2", "tab new -f", "Tab new", "",
    ] {
      XCTAssertNil(CommandBindingKey(malformed), malformed)
    }
    // The key of a command the host dispatches: value arguments drop out.
    let select = SourceCommand(name: CommandName("tab", "select"), arguments: ["--index=3"])
    XCTAssertEqual(CommandBindingKey(select), CommandBindingKey("tab select"))
    XCTAssertEqual(CommandBindingKey(select).description, "tab select")
    XCTAssertEqual(select.bindingKey, "tab select")
    XCTAssertEqual(select.argument("index"), "3")
    XCTAssertFalse(select.flag("index"))
    let reload = SourceCommand(name: CommandName("app", "reload"), arguments: ["--force"])
    XCTAssertEqual(reload.bindingKey, "app reload --force")
    XCTAssertTrue(reload.flag("force"))
    XCTAssertNil(reload.argument("force"))
    XCTAssertEqual(CommandBindingKey(reload), forced)
  }

  // MARK: - Forms

  func testEachFormDecodesFromItsManifestShape() throws {
    let manifest = try load(
      """
      "bindings": {
        "tab new": { "": "cmd+t" },
        "tab close": { "": ["cmd+k", "cmd+w"] },
        "window new": { "": { "menu": ["File", "New Window"] } },
        "app reload": { "": false },
        "app reload --force": { "": "cmd+shift+r" }
      }
      """)
    XCTAssertEqual(manifest.bindings[key("tab new")]?[""], .chords(["cmd+t"]))
    XCTAssertEqual(manifest.bindings[key("tab close")]?[""], .chords(["cmd+k", "cmd+w"]))
    XCTAssertEqual(manifest.bindings[key("window new")]?[""], .menu(["File", "New Window"]))
    XCTAssertEqual(manifest.bindings[key("app reload")]?[""], CommandBindingSpec.unbound)
    XCTAssertEqual(manifest.bindings[key("app reload --force")]?[""], .chords(["cmd+shift+r"]))
  }

  func testMalformedBindingsRejectTheManifest() {
    let malformed: [(String, String)] = [
      (#""tab new": { "": "" }"#, "empty chord"),
      (#""tab new": { "": "cmd+nonsense" }"#, "unparseable chord"),
      (#""tab new": { "": [] }"#, "empty sequence"),
      (#""tab new": { "": ["cmd+k", ""] }"#, "empty chord in a sequence"),
      (#""tab new": { "": true }"#, "true"),
      (#""tab new": { "": 3 }"#, "number"),
      (#""tab new": { "": { "menu": ["File"] } }"#, "one-title menu path"),
      (#""tab new": { "": { "menu": ["File", ""] } }"#, "empty menu title"),
      (#""tab new": { "": { "menu": ["File", "New"], "key": "x" } }"#, "extra menu key"),
      (#""tab new": { "": { "item": ["File", "New"] } }"#, "unknown object form"),
      (#""tab new": { "": "cmd+{index}" }"#, "{index} outside tab select"),
      (#""tab open": { "": "cmd+t" }"#, "unknown command"),
      (#""tab_new": { "": "cmd+t" }"#, "the retired underscore name"),
      (#""tab new --bogus": { "": "cmd+t" }"#, "a flag the command does not take"),
      (#""tab select --index=2": { "": "cmd+2" }"#, "a value argument in a key"),
      (#""tab sideways": { "": "cmd+t" }"#, "a command Flash does not have"),
      (#""screenshot window": { "": "cmd+t" }"#, "a plugin's own command is not bindable"),
      (#""app quit --force": { "": "cmd+q" }"#, "a command Flash performs itself"),
      (#""mode insert": { "": "cmd+i" }"#, "a command Flash performs itself"),
    ]
    for (fragment, label) in malformed {
      XCTAssertThrowsError(try load("\"bindings\": { \(fragment) }"), label)
    }
  }

  /// The retired manifest keys are unknown keys: no alias reads them.
  func testRetiredManifestKeysAreUnknownKeys() {
    for (fragment, retired) in [
      (#""action_keystrokes": { "tab_new": { "": "cmd+t" } }"#, "action_keystrokes"),
      (#""action_bindings": { "tab_new": { "": "cmd+t" } }"#, "action_bindings"),
      (#""exec": ["./p"], "actions": ["tab_close"]"#, "actions"),
      (#""exec": ["./p"], "action_confirmations": { "tab_close": "x" }"#, "action_confirmations"),
    ] {
      XCTAssertThrowsError(try load(fragment)) { error in
        XCTAssertTrue("\(error)".contains("unknown field \(retired)"), "\(error)")
      }
    }
  }

  /// `{index}` is allowed exactly where the command takes an `--index`.
  func testTabSelectSubstitutesItsIndex() throws {
    let chord = CommandBindingSpec.chords(["cmd+{index}"])
    XCTAssertNil(chord.validationError(for: key("tab select")))
    XCTAssertNotNil(chord.validationError(for: key("tab new")))
    XCTAssertNotNil(chord.validationError(for: key("app reload --force")))
    XCTAssertEqual(chord.binding(index: 3), .chords([try hotkey("cmd+3")]))
    XCTAssertEqual(chord.binding(index: 10), CommandBinding.unbound, "no chord for tab 10")
    let menu = CommandBindingSpec.menu(["Window", "Tab {index}"])
    XCTAssertNil(menu.validationError(for: key("tab select")))
    XCTAssertNotNil(menu.validationError(for: key("window new")))
    XCTAssertEqual(menu.binding(index: 2), .menu(["Window", "Tab 2"]))
  }

  // MARK: - Precedence

  func testAppSpecificBeatsPluginWideBeatsNothing() throws {
    let index = CommandBindingIndex(manifests: [
      try manifest(
        id: "a",
        """
        "bindings": { "tab new": { "": "cmd+t", "com.example.editor": "cmd+n" } }
        """)
    ])
    XCTAssertEqual(try resolved(index, "tab new", "com.example.editor"), "a:cmd+n")
    XCTAssertEqual(try resolved(index, "tab new", "com.example.other"), "a:cmd+t")
    XCTAssertNil(index.resolve(key("tab close"), in: context("com.example.other")))
  }

  func testAnotherPluginsAppEntryBeatsAPluginWideEntryOfAHigherPriority() throws {
    let index = CommandBindingIndex(manifests: [
      try manifest(id: "a", #""priority": 90, "bindings": { "tab new": { "": "cmd+t" } }"#),
      try manifest(
        id: "b", #""priority": 1, "bindings": { "tab new": { "com.x": "cmd+n" } }"#),
    ])
    XCTAssertEqual(try resolved(index, "tab new", "com.x"), "b:cmd+n")
  }

  func testSelectorSpecificityThenPriorityThenPluginID() throws {
    let generic = try manifest(
      id: "generic", #""priority": 90, "bindings": { "tab new": { "": "cmd+t" } }"#)
    let scoped = try manifest(
      id: "scoped",
      #""priority": 10, "only_bundle_ids": ["com.x"], "bindings": { "tab new": { "": "cmd+n" } }"#
    )
    XCTAssertEqual(
      try resolved(CommandBindingIndex(manifests: [generic, scoped]), "tab new", "com.x"),
      "scoped:cmd+n", "a matching selector beats a higher priority")
    XCTAssertEqual(
      try resolved(CommandBindingIndex(manifests: [generic, scoped]), "tab new", "com.y"),
      "generic:cmd+t", "a selector that doesn't match gates the plugin out")

    let low = try manifest(
      id: "low", #""priority": 10, "bindings": { "tab new": { "": "cmd+1" } }"#)
    let high = try manifest(
      id: "high", #""priority": 20, "bindings": { "tab new": { "": "cmd+2" } }"#)
    XCTAssertEqual(
      try resolved(CommandBindingIndex(manifests: [high, low]), "tab new", "com.x"), "high:cmd+2")

    let first = try manifest(id: "aa", #""bindings": { "tab new": { "": "cmd+1" } }"#)
    let second = try manifest(id: "bb", #""bindings": { "tab new": { "": "cmd+2" } }"#)
    XCTAssertEqual(
      try resolved(CommandBindingIndex(manifests: [first, second]), "tab new", "com.x"),
      "aa:cmd+1", "an exact tie keeps the first plugin by id")
  }

  func testOnlyTerminalsGatesBindingsToDeclaredEmulators() throws {
    let index = CommandBindingIndex(manifests: [
      try manifest(
        id: "term", #""only_terminals": true, "bindings": { "pane next": { "": "cmd+]" } }"#
      )
    ])
    XCTAssertEqual(try resolved(index, "pane next", "com.mitchellh.ghostty"), "term:cmd+]")
    XCTAssertNil(index.resolve(key("pane next"), in: context("com.apple.finder")))
  }

  func testFalseDeclaresTheAppHasNoSuchCommand() throws {
    let index = CommandBindingIndex(manifests: [
      try manifest(
        id: "a", #""bindings": { "tab new": { "": "cmd+t", "com.apple.Notes": false } }"#)
    ])
    XCTAssertEqual(
      index.binding(key("tab new"), in: context("com.apple.Notes")), CommandBinding.unbound)
    XCTAssertEqual(
      SourceCommandFallback.resolve(CommandName("tab", "new"), binding: .unbound),
      SourceCommandFallback.none)
  }

  /// A plugin-wide binding applies to every app, terminals included, so it
  /// never makes a Command chord safe in a terminal; only a binding a plugin
  /// declares for that emulator (or under a selector matching it) does.
  func testOnlyAppSpecificBindingsDeclareATerminalChord() throws {
    let index = CommandBindingIndex(manifests: [
      try manifest(id: "generic", #""bindings": { "app save": { "": "cmd+s" } }"#),
      try manifest(
        id: "term",
        #""bindings": { "pane next": { "com.mitchellh.ghostty": "cmd+]" } }"#),
    ])
    let ghostty = context("com.mitchellh.ghostty")
    let save = try hotkey("cmd+s")
    let pane = try hotkey("cmd+]")
    XCTAssertFalse(index.declares(key: save.keyCode, flags: save.eventFlags, in: ghostty))
    XCTAssertTrue(index.declares(key: pane.keyCode, flags: pane.eventFlags, in: ghostty))
  }

  // MARK: - Dispatch

  func testDispatchPlanForEachForm() throws {
    let never: (CGKeyCode, CGEventFlags) -> Bool = { _, _ in false }
    let t = try hotkey("cmd+t")
    let k = try hotkey("cmd+k")
    let w = try hotkey("cmd+w")
    XCTAssertEqual(
      CommandBindingDispatch.plan(.chords([t]), typesText: never),
      .sendChords([BindingChord(t)]))
    XCTAssertEqual(
      CommandBindingDispatch.plan(.chords([k, w]), typesText: never),
      .sendChords([BindingChord(k), BindingChord(w)]))
    XCTAssertEqual(
      CommandBindingDispatch.plan(.menu(["File", "New Tab"]), typesText: never),
      .pressMenu(["File", "New Tab"]))
    XCTAssertEqual(CommandBindingDispatch.plan(.unbound, typesText: never), .unavailable)
  }

  /// A chord a terminal would type is refused, the whole sequence with it;
  /// a menu press never types, so it is allowed.
  func testTerminalRefusesTypingChordsButNotMenus() throws {
    let s = try hotkey("cmd+s")
    let w = try hotkey("cmd+w")
    let typesS: (CGKeyCode, CGEventFlags) -> Bool = { key, _ in key == s.keyCode }
    XCTAssertEqual(CommandBindingDispatch.plan(.chords([s]), typesText: typesS), .refused)
    XCTAssertEqual(CommandBindingDispatch.plan(.chords([w, s]), typesText: typesS), .refused)
    XCTAssertEqual(
      CommandBindingDispatch.plan(.menu(["File", "Save"]), typesText: { _, _ in true }),
      .pressMenu(["File", "Save"]))
  }

  func testMenuPressRunsOffMainAndReportsEachOutcome() {
    final class Presser: MenuPathPresser, @unchecked Sendable {
      var pressed: [([String], pid_t, Bool)] = []
      let succeeds: Bool
      init(succeeds: Bool) { self.succeeds = succeeds }
      func press(_ path: [String], pid: pid_t) -> Bool {
        pressed.append((path, pid, Thread.isMainThread))
        return succeeds
      }
    }
    let queue = DispatchQueue(label: "test.menu")
    for succeeds in [true, false] {
      let presser = Presser(succeeds: succeeds)
      let done = expectation(description: "pressed \(succeeds)")
      CommandBindingDispatch.pressMenu(
        ["File", "New Tab"], pid: 42, repeatCount: 3, presser: presser, queue: queue
      ) { ok in
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(ok, succeeds)
        done.fulfill()
      }
      wait(for: [done], timeout: 2)
      XCTAssertEqual(presser.pressed.count, succeeds ? 3 : 1, "a failed press stops the repeat")
      XCTAssertTrue(presser.pressed.allSatisfy { $0.0 == ["File", "New Tab"] && $0.1 == 42 })
      XCTAssertFalse(presser.pressed.contains { $0.2 }, "never on the main thread")
    }
  }

  func testQueuedMenuPressStopsWhenCapturedTargetLosesOwnership() {
    final class Presser: MenuPathPresser, @unchecked Sendable {
      var calls = 0
      func press(_ path: [String], pid: pid_t) -> Bool {
        calls += 1
        return true
      }
    }
    let presser = Presser()
    let queue = DispatchQueue(label: "test.menu.ownership")
    let done = expectation(description: "cancelled menu")
    CommandBindingDispatch.pressMenu(
      ["Edit", "Copy"], pid: 42, repeatCount: 3, presser: presser, queue: queue,
      shouldContinue: { false },
      completion: { succeeded in
        XCTAssertFalse(succeeded)
        done.fulfill()
      })
    wait(for: [done], timeout: 2)
    XCTAssertEqual(presser.calls, 0)
  }

  // MARK: - Commands

  /// The `:`-commands that act in the app are those commands. `:q` and
  /// `:wq` run `app close`, Flash's own composite over `tab close`
  /// (`AppCloseTests`).
  func testCommandLineAppCommandsAreTheirCommands() {
    let expected: [(String, [String])] = [
      ("w", ["app save"]), ("e", ["document open"]), ("new", ["window new"]),
      ("tabnew", ["tab new"]), ("tabc", ["tab close"]), ("bd", ["tab close"]),
      ("clo", ["window close"]), ("u", ["app undo"]), ("red", ["app redo"]),
      ("sp", ["pane split_horizontal"]), ("vs", ["pane split_vertical"]),
      ("tabn", ["tab next"]), ("tabp", ["tab previous"]),
    ]
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    for (raw, names) in expected {
      guard
        case .commands(let commands) = NormalModeDispatcher.resolveCommandLine(
          raw, inventory: inventory)
      else { return XCTFail(raw) }
      XCTAssertEqual(
        commands.compactMap { $0.sourceCommand?.name }, names.map { CommandName($0)! }, raw)
    }
  }

  // MARK: - Helpers

  private func key(_ text: String) -> CommandBindingKey {
    CommandBindingKey(text)!
  }

  private func context(_ bundle: String) -> PluginSelectorContext {
    PluginSelectorContext(bundleID: bundle)
  }

  private func hotkey(_ value: String) throws -> ParsedHotkey {
    try XCTUnwrap(HotkeySyntax.parse(hotkey: value), value)
  }

  /// `plugin:chord` for the winning binding, to assert who won and with what.
  private func resolved(
    _ index: CommandBindingIndex, _ text: String, _ bundle: String
  ) throws -> String {
    let resolution = try XCTUnwrap(index.resolve(key(text), in: context(bundle)))
    return "\(resolution.pluginID):\(resolution.spec.display)"
  }

  private func load(_ fragment: String) throws -> PluginManifest {
    try manifest(id: "example", fragment)
  }

  private func manifest(id: String, _ fragment: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-command-bindings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = """
      {
        "id": "\(id)", "name": "\(id)", "version": "0.1.0", "description": "test",
        \(fragment)
      }
      """
    try json.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }
}
