import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// The everyday operations of an app as commands: the ones Flash asks of the
/// focused app (save as, export, revert, settings, a browser's bookmark and
/// history, …), resolved through plugin `bindings`; the ones Flash performs
/// itself (`app hide`, `app raise`, `menu press`); their `:` aliases; NORMAL's
/// Escape; and the question asked before the two that lose work.
final class AppOperationCommandsTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - Grammar

  /// Every operation asked of the focused app is a source command, and its
  /// name a key a manifest `bindings` entry may declare.
  func testTheAppOperationsAreCommandsAskedOfTheFocusedApp() throws {
    let asked: [(String, URLCommand)] = [
      ("document save_as", .documentSaveAs), ("document export_pdf", .documentExportPDF),
      ("document revert", .documentRevert), ("document duplicate", .documentDuplicate),
      ("document rename", .documentRename), ("document page_setup", .documentPageSetup),
      ("app settings", .appSettings), ("app select_all", .selectAll), ("app help", .appHelp),
      ("app cancel", .appCancel), ("app stop", .appStop), ("app downloads", .appDownloads),
      ("app developer_tools", .developerTools), ("window close_all", .windowCloseAll),
      ("window zoom", .windowZoom), ("url bookmark", .urlBookmark), ("url edit", .urlEdit),
      ("history show", .historyShow), ("tab duplicate", .tabDuplicate), ("tab pin", .tabPin),
      ("tab mute", .tabMute), ("tab detach", .tabDetach),
    ]
    let keys = Set(URLEventHandler.sourceCommandBindingKeys.map(\.description))
    for (line, expected) in asked {
      let words = line.split(separator: " ").map(String.init)
      let command = try XCTUnwrap(URLEventHandler.parse(words: words), line)
      XCTAssertEqual(command, expected, line)
      XCTAssertEqual(command.sourceCommand?.bindingKey, line, line)
      XCTAssertTrue(keys.contains(line), line)
      XCTAssertNil(URLEventHandler.parse(words: words + ["--force"]), "\(line) takes no flag")
    }
  }

  /// `window new --private` is a binding key of its own, the second flag
  /// variant after `app reload --force`.
  func testAPrivateWindowIsTheNewWindowsFlagVariant() throws {
    let privateWindow = try XCTUnwrap(URLEventHandler.parse(words: ["window", "new", "--private"]))
    XCTAssertEqual(privateWindow, .windowNew(private: true))
    XCTAssertEqual(privateWindow.argv, ["flash", "window", "new", "--private"])
    XCTAssertEqual(privateWindow.sourceCommand?.bindingKey, "window new --private")
    XCTAssertEqual(URLEventHandler.parse(words: ["window", "new"]), .windowNew(private: false))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["window", "new"])?.sourceCommand?.bindingKey, "window new")
    XCTAssertEqual(
      URLEventHandler.sourceCommandBindingKeys.filter { !$0.flags.isEmpty }.map(\.description),
      ["app reload --force", "window new --private"])
  }

  /// `app hide`, `hide_others`, `show_all` and `raise` and `menu press` are
  /// Flash's own: no plugin binding stands for them.
  func testHostActionsAreFlashsOwn() throws {
    let host: [(String, URLCommand)] = [
      ("app hide", .appVisibility(.hide)), ("app hide_others", .appVisibility(.hideOthers)),
      ("app show_all", .appVisibility(.showAll)), ("app raise", .appVisibility(.raise)),
    ]
    for (line, expected) in host {
      let words = line.split(separator: " ").map(String.init)
      let command = try XCTUnwrap(URLEventHandler.parse(words: words), line)
      XCTAssertEqual(command, expected, line)
      XCTAssertNil(command.sourceCommand, line)
      XCTAssertEqual(Array(command.argv.dropFirst()), words, line)
      XCTAssertTrue(
        AppDelegate.normalModeCommandMayChangeKeyboardFocus(command), "\(line) moves activation")
    }
    let press = try XCTUnwrap(
      URLEventHandler.parse(words: ["menu", "press", "--path=File,Export as PDF…"]))
    XCTAssertEqual(press, .menuPress(path: ["File", "Export as PDF…"]))
    XCTAssertNil(press.sourceCommand)
    XCTAssertEqual(press.argv, ["flash", "menu", "press", "--path=File,Export as PDF…"])
  }

  /// A menu path is the menu's title, then each item's, comma-separated, at
  /// least two of them and none blank.
  func testAMenuPathNeedsTheMenuAndAnItem() {
    func press(_ path: String) -> URLCommand? {
      URLEventHandler.parse(words: ["menu", "press", "--path=\(path)"])
    }
    XCTAssertEqual(
      press("File, Revert To ,Last Saved Version"),
      .menuPress(path: ["File", "Revert To", "Last Saved Version"]))
    XCTAssertEqual(press("Window,Zoom"), .menuPress(path: ["Window", "Zoom"]))
    for malformed in ["File", "", "File,", ",Zoom", "File,,Print…", " , "] {
      XCTAssertNil(press(malformed), malformed)
    }
    XCTAssertNil(URLEventHandler.parse(words: ["menu", "press"]), "the path is required")
  }

  // MARK: - Bindings

  /// What each operation does in a few apps, from the bundled manifests:
  /// a chord, a menu item, `false` (`unbound`) or nothing (nil).
  func testEachOperationResolvesPerAppFromTheBundledPlugins() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let unknown = "com.example.unknown"
    let textEdit = "com.apple.TextEdit"
    let pages = "com.apple.iWork.Pages"
    let safari = "com.apple.Safari"
    let chrome = "com.google.Chrome"
    let firefox = "org.mozilla.firefox"
    let vscode = "com.microsoft.VSCode"
    let ghostty = "com.mitchellh.ghostty"
    let alacritty = "org.alacritty"
    let wezterm = "com.github.wez.wezterm"
    let xcode = "com.apple.dt.Xcode"
    let arc = "company.thebrowser.Browser"
    let opera = "com.operasoftware.Opera"
    let rows: [(String, String, CommandBindingSpec?)] = [
      ("app print", unknown, .chords(["cmd+p"])),
      ("document save_as", unknown, .chords(["cmd+shift+s"])),
      ("document save_as", textEdit, .chords(["cmd+alt+shift+s"])),
      ("document save_as", pages, .chords(["cmd+alt+shift+s"])),
      ("document duplicate", unknown, nil),
      ("document duplicate", textEdit, .chords(["cmd+shift+s"])),
      ("document export_pdf", unknown, .menu(["File", "Export as PDF…"])),
      ("document export_pdf", pages, .unbound),
      ("document revert", unknown, .menu(["File", "Revert To", "Last Saved"])),
      ("document revert", xcode, .menu(["File", "Revert to Saved…"])),
      ("document revert", vscode, .menu(["File", "Revert File"])),
      ("document rename", unknown, .menu(["File", "Rename…"])),
      ("document rename", xcode, .unbound),
      ("document page_setup", unknown, .menu(["File", "Page Setup…"])),
      ("app settings", unknown, .chords(["cmd+,"])),
      ("app settings", ghostty, .chords(["cmd+,"])),
      ("app settings", alacritty, .unbound),
      ("app settings", wezterm, .unbound),
      ("app select_all", unknown, .chords(["cmd+a"])),
      ("app select_all", ghostty, .unbound),
      ("app help", unknown, .chords(["cmd+shift+/"])),
      ("window zoom", unknown, .menu(["Window", "Zoom"])),
      ("window zoom", alacritty, .unbound),
      ("window close_all", unknown, .chords(["cmd+alt+w"])),
      ("window close_all", vscode, .chords(["cmd+k", "cmd+w"])),
      ("window close_all", safari, .unbound),
      ("window close_all", chrome, .chords(["cmd+alt+shift+w"])),
      ("window close_all", firefox, .unbound),
      ("window close_all", ghostty, .unbound),
      ("app cancel", unknown, .chords(["escape"])),
      ("app cancel", ghostty, .unbound),
      ("app cancel", alacritty, .unbound),
      ("url bookmark", unknown, nil),
      ("url bookmark", safari, .chords(["cmd+d"])),
      ("url bookmark", arc, .unbound),
      ("url edit", chrome, .chords(["cmd+l"])),
      ("window new --private", unknown, nil),
      ("window new --private", safari, .chords(["cmd+shift+n"])),
      ("window new --private", chrome, .chords(["cmd+shift+n"])),
      ("window new --private", firefox, .chords(["cmd+shift+p"])),
      ("app developer_tools", firefox, .chords(["cmd+alt+i"])),
      ("app downloads", safari, .chords(["cmd+alt+l"])),
      ("app downloads", chrome, .chords(["cmd+shift+j"])),
      ("app downloads", firefox, .chords(["cmd+j"])),
      ("app downloads", arc, nil),
      ("app stop", safari, .chords(["cmd+."])),
      ("app stop", arc, nil),
      ("history show", safari, .chords(["cmd+y"])),
      ("history show", chrome, .chords(["cmd+y"])),
      ("history show", firefox, .chords(["cmd+y"])),
      ("history show", opera, .chords(["cmd+shift+h"])),
      ("tab mute", firefox, .chords(["ctrl+m"])),
      ("tab mute", safari, nil),
      ("tab pin", safari, .menu(["Window", "Pin Tab"])),
      ("tab pin", chrome, .menu(["Tab", "Pin Tab"])),
      ("tab detach", safari, .menu(["Window", "Move Tab to New Window"])),
      ("tab duplicate", safari, .menu(["Window", "Duplicate Tab"])),
      ("tab duplicate", chrome, .menu(["Tab", "Duplicate Tab"])),
      ("tab duplicate", unknown, nil),
    ]
    for (line, bundle, expected) in rows {
      let key = try XCTUnwrap(CommandBindingKey(line), line)
      XCTAssertEqual(
        index.resolve(key, in: PluginSelectorContext(bundleID: bundle))?.spec, expected,
        "\(line) in \(bundle)")
    }
  }

  /// Finder's Cmd-Shift-G is Go to Folder: `n` and `N` find nothing there
  /// rather than open it.
  func testFinderHasNoFindMatchesToStepThrough() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let finder = PluginSelectorContext(bundleID: "com.apple.finder")
    for line in ["app find_next", "app find_previous"] {
      XCTAssertEqual(index.resolve(CommandBindingKey(line)!, in: finder)?.spec, .unbound, line)
    }
    XCTAssertEqual(
      index.resolve(CommandBindingKey("app find")!, in: finder)?.spec, .chords(["cmd+f"]))
  }

  /// Escape is a key a shell or vim reads: in a terminal, `app cancel`
  /// sends nothing, nor does Select All.
  func testTerminalsReceiveNoEscapeOrSelectAll() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for line in ["app cancel", "app select_all", "window close_all"] {
        XCTAssertEqual(index.binding(CommandBindingKey(line)!, in: context), .unbound, emulator)
      }
    }
  }

  /// `menu press` is a user's escape hatch, like `key send`: no default or
  /// bundled mapping presses a menu item by title.
  func testNoBuiltInOrBundledMappingPressesAMenuItem() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let toml = try String(
      contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    for (label, mode) in [
      ("built-in", Config.default.mode), ("file", ConfigLoader.parse(toml).mode),
    ] {
      let mappings =
        mode.all + mode.normal + mode.insert + mode.command + mode.terminal + mode.text
        + mode.visual + mode.hold + mode.hyper
      XCTAssertFalse(mappings.isEmpty)
      for mapping in mappings {
        XCTAssertFalse(Self.pressesAMenu(mapping.action), "\(label) \(mapping.key)")
      }
    }
    for manifest in try SourceCommandFallbackTests.officialManifests() {
      for registration in manifest.mappings {
        let action = try XCTUnwrap(
          parseMappingCommand(argv: registration.command), "\(manifest.id) \(registration.key)")
        XCTAssertFalse(Self.pressesAMenu(action), "\(manifest.id) \(registration.key)")
      }
    }
  }

  private static func pressesAMenu(_ action: MappingCommand) -> Bool {
    if case .flashCommand(.menuPress) = action { return true }
    if case .flashCommand(.confirm(let request)) = action, case .menuPress = request.command {
      return true
    }
    return false
  }

  // MARK: - Confirmations

  /// Reverting a document drops its unsaved changes and closing every
  /// window may close unsaved ones: Flash asks first, where the app has the
  /// command. A plugin's own question for a command it performs wins.
  func testRevertAndCloseAllAskFirstWhereTheAppHasThem() {
    let menu = CommandBinding.menu(["File", "Revert To", "Last Saved Version"])
    let chord = CommandBinding.chords([HotkeySyntax.parse(hotkey: "cmd+alt+w")!])
    for (command, binding) in [
      (URLCommand.documentRevert, menu), (URLCommand.windowCloseAll, chord),
    ] {
      let question = command.hostConfirmation
      XCTAssertNotNil(question, command.diagnosticDescription)
      XCTAssertEqual(
        AppDelegate.appCommandConfirmation(command, pluginPrompt: nil, binding: binding), question)
      XCTAssertEqual(
        AppDelegate.appCommandConfirmation(command, pluginPrompt: "Mine?", binding: binding),
        "Mine?")
      XCTAssertNil(
        AppDelegate.appCommandConfirmation(command, pluginPrompt: nil, binding: .unbound),
        "an app without it is not asked")
      XCTAssertNil(AppDelegate.appCommandConfirmation(command, pluginPrompt: nil, binding: nil))
    }
    for command in [
      URLCommand.print, .save, .documentSaveAs, .documentExportPDF, .windowClose, .tabClose,
      .appCancel, .selectAll,
    ] {
      XCTAssertNil(command.hostConfirmation, command.diagnosticDescription)
      XCTAssertNil(
        AppDelegate.appCommandConfirmation(command, pluginPrompt: nil, binding: chord),
        command.diagnosticDescription)
    }
    XCTAssertEqual(
      AppDelegate.appCommandConfirmation(
        .tabClose, pluginPrompt: "Close this tmux window?",
        binding: nil),
      "Close this tmux window?")
  }

  // MARK: - Escape

  /// NORMAL's Escape is `app cancel`, in the built-in defaults and the
  /// reference file alike; an engaged field's text table and VISUAL keep
  /// `mode leave`.
  func testNormalsEscapeIsTheAppsCancel() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let toml = try String(
      contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    for mode in [Config.default.mode, ConfigLoader.parse(toml).mode] {
      XCTAssertEqual(
        mode.compiledNormal.mapping(for: key("<esc>"))?.action, .flashCommand(.appCancel))
      XCTAssertEqual(
        mode.compiledText.mapping(for: key("<esc>"))?.action, .flashCommand(.leaveMode))
      XCTAssertEqual(
        mode.visual.first { $0.key == key("<esc>") }?.action, .flashCommand(.leaveMode))
    }
  }

  /// Escape alone asks the app to cancel; after a half-typed sequence, a
  /// count, a register, a mark or a macro key it only abandons that, as in
  /// Vim, and nothing reaches the app.
  func testEscapeCancelsWhatIsHalfTypedBeforeTheApp() {
    let table = CompiledMappings(Config.default.mode.normal)
    func escape(after pending: String) -> NormalModeTransition {
      NormalModeInterpreter.interpret(
        pending: pending, repeatAnchor: nil, keyCode: UInt16(kVK_Escape), modifierFlags: [],
        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", mappings: table)
    }
    func type(_ chars: String, after pending: String = "") -> String {
      NormalModeInterpreter.interpret(
        pending: pending, repeatAnchor: nil, keyCode: 0xFFFF, modifierFlags: [],
        characters: chars, charactersIgnoringModifiers: chars.lowercased(), mappings: table
      ).pending
    }
    XCTAssertEqual(escape(after: "").command, .appCancel)
    for typed in ["g", "3", "\"", "q", "@", "'", "`", "m", "]"] {
      let pending = type(typed)
      XCTAssertFalse(pending.isEmpty, "\(typed) waits for a key")
      XCTAssertEqual(escape(after: pending), .consume, "Escape after \(typed)")
    }
    XCTAssertEqual(escape(after: type("a", after: type("\""))), .consume, "Escape after \"a")
  }

  /// A context menu or Mission Control closes on its own Escape: while one
  /// owns the screen, a key NORMAL maps to `app cancel` reaches it as typed.
  func testANativeSurfaceGetsTheKeyNormalMapsToTheAppsCancel() {
    let defaults = CompiledMappings(Config.default.mode.normal)
    XCTAssertTrue(
      NormalModeInterpreter.passesToNativeSurface(
        virtualKey: UInt32(kVK_Escape), modifierFlags: [], mappings: defaults))
    XCTAssertFalse(
      NormalModeInterpreter.passesToNativeSurface(
        virtualKey: UInt32(kVK_ANSI_F), modifierFlags: [], mappings: defaults))
    let remapped = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<esc>" = ["flash", "hints", "dismiss"]
      """
    ).mode.compiledNormal
    XCTAssertFalse(
      NormalModeInterpreter.passesToNativeSurface(
        virtualKey: UInt32(kVK_Escape), modifierFlags: [], mappings: remapped))
  }

  /// A terminal in web content (VS Code's, xterm.js) is no declared
  /// emulator, so no binding keeps Escape from it: the focus region does,
  /// since a shell or vim would read the Escape.
  func testTheAppsCancelSkipsATerminalTheFocusIsIn() {
    XCTAssertFalse(FocusRegion.terminal.takesTheAppsCancel)
    for region in [FocusRegion.document, .collection, .text(.singleLine), .text(.multiLine)] {
      XCTAssertTrue(region.takesTheAppsCancel, "\(region)")
    }
  }

  /// Escape cancels; it is no change for `.` to repeat.
  func testTheAppsCancelIsNoChangeToRepeat() {
    XCTAssertFalse(MacroState.repeats(.flashCommand(.appCancel)))
    XCTAssertTrue(MacroState.repeats(.flashCommand(.documentSaveAs)))
  }

  // MARK: - Command line

  private let inventory = NormalModeDispatcher.CommandLineInventory.core()

  private func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
    NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
  }

  /// Vim's names for these operations: `:p[rint]` and `:ha[rdcopy]` print,
  /// `:sav[eas]` saves as, `:e!` reverts, `:opt[ions]` opens the settings and
  /// `:hid[e]` hides the app. `:pr` is print now, not `process`.
  func testVimsNamesRunTheAppOperations() {
    for line in [":p", ":pr", ":print", ":ha", ":hardcopy"] {
      XCTAssertEqual(resolve(line), .commands([.print]), line)
    }
    for line in [":sav", ":saveas"] {
      XCTAssertEqual(resolve(line), .commands([.documentSaveAs]), line)
    }
    XCTAssertEqual(resolve(":e!"), .commands([.documentRevert]))
    XCTAssertEqual(resolve(":edit!"), .commands([.documentRevert]))
    XCTAssertEqual(resolve(":e"), .commands([.documentOpen]))
    for line in [":opt", ":options"] {
      XCTAssertEqual(resolve(line), .commands([.appSettings]), line)
    }
    for line in [":hid", ":hide"] {
      XCTAssertEqual(resolve(line), .commands([.appVisibility(.hide)]), line)
    }
    XCTAssertEqual(resolve(":pr kill --pid=42"), .unknown, "pr is print, which takes nothing")
    XCTAssertEqual(
      resolve(":proc kill --pid=42"), .commands([.processKill(pid: 42)]), "proc is process")
    XCTAssertEqual(resolve(":pu"), .commands([.paste(register: nil)]), "pu stays put")
    XCTAssertEqual(
      resolve(":menu press --path=File,Export as PDF…"),
      .commands([.menuPress(path: ["File", "Export as PDF…"])]),
      "a title's spaces survive the command line")
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}
