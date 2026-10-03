import AppKit
import FlashCore
import XCTest

@testable import flash

/// `action_bindings`: the typed union a plugin declares per action and app,
/// its validation, the precedence that picks one across plugins, and how the
/// host dispatches each form.
final class ActionBindingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - Forms

  func testEachFormDecodesFromItsManifestShape() throws {
    let manifest = try load(
      """
      "action_bindings": {
        "tab_new": { "": "cmd+t" },
        "tab_close": { "": ["cmd+k", "cmd+w"] },
        "window_new": { "": { "menu": ["File", "New Window"] } },
        "app_reload": { "": false }
      }
      """)
    XCTAssertEqual(manifest.actionBindings[.tabNew]?[""], .chords(["cmd+t"]))
    XCTAssertEqual(manifest.actionBindings[.tabClose]?[""], .chords(["cmd+k", "cmd+w"]))
    XCTAssertEqual(manifest.actionBindings[.windowNew]?[""], .menu(["File", "New Window"]))
    XCTAssertEqual(manifest.actionBindings[.appReload]?[""], ActionBindingSpec.unbound)
  }

  func testMalformedBindingsRejectTheManifest() {
    let malformed: [(String, String)] = [
      (#""tab_new": { "": "" }"#, "empty chord"),
      (#""tab_new": { "": "cmd+nonsense" }"#, "unparseable chord"),
      (#""tab_new": { "": [] }"#, "empty sequence"),
      (#""tab_new": { "": ["cmd+k", ""] }"#, "empty chord in a sequence"),
      (#""tab_new": { "": true }"#, "true"),
      (#""tab_new": { "": 3 }"#, "number"),
      (#""tab_new": { "": { "menu": ["File"] } }"#, "one-title menu path"),
      (#""tab_new": { "": { "menu": ["File", ""] } }"#, "empty menu title"),
      (#""tab_new": { "": { "menu": ["File", "New"], "key": "x" } }"#, "extra menu key"),
      (#""tab_new": { "": { "item": ["File", "New"] } }"#, "unknown object form"),
      (#""tab_new": { "": "cmd+{index}" }"#, "{index} outside tab_select"),
      (#""tab_open": { "": "cmd+t" }"#, "unknown action"),
    ]
    for (fragment, label) in malformed {
      XCTAssertThrowsError(try load("\"action_bindings\": { \(fragment) }"), label)
    }
  }

  func testTheRetiredKeystrokeTableIsRejected() {
    XCTAssertThrowsError(
      try load(#""action_keystrokes": { "tab_new": { "": "cmd+t" } }"#)
    ) { error in
      XCTAssertTrue("\(error)".contains("action_keystrokes"), "\(error)")
    }
  }

  func testTabSelectSubstitutesItsIndex() throws {
    let chord = ActionBindingSpec.chords(["cmd+{index}"])
    XCTAssertEqual(chord.binding(index: 3), .chords([try hotkey("cmd+3")]))
    XCTAssertEqual(chord.binding(index: 10), ActionBinding.unbound, "no chord for tab 10")
    let menu = ActionBindingSpec.menu(["Window", "Tab {index}"])
    XCTAssertEqual(menu.binding(index: 2), .menu(["Window", "Tab 2"]))
  }

  // MARK: - Precedence

  func testAppSpecificBeatsPluginWideBeatsNothing() throws {
    let index = ActionBindingIndex(manifests: [
      try manifest(
        id: "a",
        """
        "action_bindings": { "tab_new": { "": "cmd+t", "com.example.editor": "cmd+n" } }
        """)
    ])
    XCTAssertEqual(try resolved(index, .tabNew, "com.example.editor"), "a:cmd+n")
    XCTAssertEqual(try resolved(index, .tabNew, "com.example.other"), "a:cmd+t")
    XCTAssertNil(index.resolve(.tabClose, in: context("com.example.other")))
  }

  func testAnotherPluginsAppEntryBeatsAPluginWideEntryOfAHigherPriority() throws {
    let index = ActionBindingIndex(manifests: [
      try manifest(id: "a", #""priority": 90, "action_bindings": { "tab_new": { "": "cmd+t" } }"#),
      try manifest(
        id: "b", #""priority": 1, "action_bindings": { "tab_new": { "com.x": "cmd+n" } }"#),
    ])
    XCTAssertEqual(try resolved(index, .tabNew, "com.x"), "b:cmd+n")
  }

  func testSelectorSpecificityThenPriorityThenPluginID() throws {
    let generic = try manifest(
      id: "generic", #""priority": 90, "action_bindings": { "tab_new": { "": "cmd+t" } }"#)
    let scoped = try manifest(
      id: "scoped",
      #""priority": 10, "only_bundle_ids": ["com.x"], "action_bindings": { "tab_new": { "": "cmd+n" } }"#
    )
    XCTAssertEqual(
      try resolved(ActionBindingIndex(manifests: [generic, scoped]), .tabNew, "com.x"),
      "scoped:cmd+n", "a matching selector beats a higher priority")
    XCTAssertEqual(
      try resolved(ActionBindingIndex(manifests: [generic, scoped]), .tabNew, "com.y"),
      "generic:cmd+t", "a selector that doesn't match gates the plugin out")

    let low = try manifest(
      id: "low", #""priority": 10, "action_bindings": { "tab_new": { "": "cmd+1" } }"#)
    let high = try manifest(
      id: "high", #""priority": 20, "action_bindings": { "tab_new": { "": "cmd+2" } }"#)
    XCTAssertEqual(
      try resolved(ActionBindingIndex(manifests: [high, low]), .tabNew, "com.x"), "high:cmd+2")

    let first = try manifest(id: "aa", #""action_bindings": { "tab_new": { "": "cmd+1" } }"#)
    let second = try manifest(id: "bb", #""action_bindings": { "tab_new": { "": "cmd+2" } }"#)
    XCTAssertEqual(
      try resolved(ActionBindingIndex(manifests: [first, second]), .tabNew, "com.x"), "aa:cmd+1",
      "an exact tie keeps the first plugin by id")
  }

  func testOnlyTerminalsGatesBindingsToDeclaredEmulators() throws {
    let index = ActionBindingIndex(manifests: [
      try manifest(
        id: "term", #""only_terminals": true, "action_bindings": { "pane_next": { "": "cmd+]" } }"#
      )
    ])
    XCTAssertEqual(try resolved(index, .paneNext, "com.mitchellh.ghostty"), "term:cmd+]")
    XCTAssertNil(index.resolve(.paneNext, in: context("com.apple.finder")))
  }

  func testFalseDeclaresTheAppHasNoSuchAction() throws {
    let index = ActionBindingIndex(manifests: [
      try manifest(
        id: "a", #""action_bindings": { "tab_new": { "": "cmd+t", "com.apple.Notes": false } }"#)
    ])
    XCTAssertEqual(index.binding(.tabNew, in: context("com.apple.Notes")), ActionBinding.unbound)
    XCTAssertEqual(
      SourceActionFallback.resolve(.tabNew, binding: .unbound), SourceActionFallback.none)
  }

  /// A plugin-wide binding applies to every app, terminals included, so it
  /// never makes a Command chord safe in a terminal; only a binding a plugin
  /// declares for that emulator (or under a selector matching it) does.
  func testOnlyAppSpecificBindingsDeclareATerminalChord() throws {
    let index = ActionBindingIndex(manifests: [
      try manifest(id: "generic", #""action_bindings": { "app_save": { "": "cmd+s" } }"#),
      try manifest(
        id: "term",
        #""action_bindings": { "pane_next": { "com.mitchellh.ghostty": "cmd+]" } }"#),
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
      ActionBindingDispatch.plan(.chords([t]), typesText: never),
      .sendChords([ActionChord(t)]))
    XCTAssertEqual(
      ActionBindingDispatch.plan(.chords([k, w]), typesText: never),
      .sendChords([ActionChord(k), ActionChord(w)]))
    XCTAssertEqual(
      ActionBindingDispatch.plan(.menu(["File", "New Tab"]), typesText: never),
      .pressMenu(["File", "New Tab"]))
    XCTAssertEqual(ActionBindingDispatch.plan(.unbound, typesText: never), .unavailable)
  }

  /// A chord a terminal would type is refused, the whole sequence with it;
  /// a menu press never types, so it is allowed.
  func testTerminalRefusesTypingChordsButNotMenus() throws {
    let s = try hotkey("cmd+s")
    let w = try hotkey("cmd+w")
    let typesS: (CGKeyCode, CGEventFlags) -> Bool = { key, _ in key == s.keyCode }
    XCTAssertEqual(ActionBindingDispatch.plan(.chords([s]), typesText: typesS), .refused)
    XCTAssertEqual(ActionBindingDispatch.plan(.chords([w, s]), typesText: typesS), .refused)
    XCTAssertEqual(
      ActionBindingDispatch.plan(.menu(["File", "Save"]), typesText: { _, _ in true }),
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
      ActionBindingDispatch.pressMenu(
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

  // MARK: - Verbs

  /// Every verb that asks the focused app to do something reaches its
  /// bindable action of the same name, so a plugin binding is all it takes
  /// to change what any of them does in an app.
  func testEveryAppVerbDispatchesItsBindableAction() throws {
    let verbs = SourceActionName.allCases.map(\.rawValue).filter {
      !["tab_select", "app_reload_force", "scroll_top", "scroll_bottom"].contains($0)
    }
    for verb in verbs {
      let command = try XCTUnwrap(URLEventHandler.parse(verb: verb, args: [:]), verb)
      XCTAssertEqual(command.sourceAction?.name.rawValue, verb, verb)
    }
    XCTAssertEqual(
      URLEventHandler.parse(verb: "app_reload", args: ["force": "1"])?.sourceAction?.name,
      .appReloadForce)
  }

  /// The `:`-commands that act in the app are those verbs.
  func testCommandLineAppCommandsAreTheirVerbs() {
    let expected: [(String, SourceActionName)] = [
      ("w", .appSave), ("print", .appPrint), ("e", .documentOpen), ("new", .windowNew),
      ("tabnew", .tabNew), ("close", .tabClose), ("q", .windowClose), ("find", .appFind),
      ("undo", .appUndo), ("redo", .appRedo), ("copy", .clipboardCopy), ("cut", .clipboardCut),
      ("paste", .clipboardPaste),
    ]
    for (raw, action) in expected {
      let command = NormalModeDispatcher.commandLineCommand(raw)
      XCTAssertEqual(
        command.flatMap(NormalModeDispatcher.verb(for:))?.sourceAction?.name, action, raw)
    }
  }

  // MARK: - Helpers

  private func context(_ bundle: String) -> PluginSelectorContext {
    PluginSelectorContext(bundleID: bundle)
  }

  private func hotkey(_ value: String) throws -> ParsedHotkey {
    try XCTUnwrap(HotkeySyntax.parse(hotkey: value), value)
  }

  /// `plugin:chord` for the winning binding, to assert who won and with what.
  private func resolved(
    _ index: ActionBindingIndex, _ name: SourceActionName, _ bundle: String
  ) throws -> String {
    let resolution = try XCTUnwrap(index.resolve(name, in: context(bundle)))
    return "\(resolution.pluginID):\(resolution.spec.display)"
  }

  private func load(_ fragment: String) throws -> PluginManifest {
    try manifest(id: "example", fragment)
  }

  private func manifest(id: String, _ fragment: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-action-bindings-\(UUID().uuidString)")
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
