import AppKit
import FlashCore
import XCTest

@testable import flash

/// NORMAL maps keys to high-level actions only. Once no source performs an
/// action in the focused app, `SourceActionFallback` and the bundled
/// `action_keystrokes` decide what that app gets.
final class SourceActionFallbackTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testDeclaredChordBeatsTheConventionAndDeclaredNoneDoesNothing() throws {
    let controlTab = try XCTUnwrap(ActionKeystroke(manifestValue: "ctrl+tab"))
    XCTAssertEqual(SourceActionFallback.resolve(.tabNext, declared: controlTab), chord("ctrl+tab"))
    XCTAssertEqual(SourceActionFallback.resolve(.tabNext, declared: .unbound), .none)
    XCTAssertEqual(SourceActionFallback.resolve(.tabNext, declared: nil), chord("cmd+shift+]"))
    let reload = try XCTUnwrap(ActionKeystroke(manifestValue: "cmd+r"))
    XCTAssertEqual(SourceActionFallback.resolve(.appReload, declared: reload), chord("cmd+r"))
  }

  /// Only actions with a chord apps share have a convention; reload, reopen,
  /// the last tab, tab moves, panes and archiving act only where a source or a
  /// declaration knows the app.
  func testConventionsCoverOnlyActionsWithASharedChord() {
    let expected: [SourceActionName: SourceActionFallback] = [
      .tabNext: chord("cmd+shift+]"),
      .tabPrevious: chord("cmd+shift+["),
      .tabFirst: chord("cmd+1"),
      .tabNew: chord("cmd+t"),
      .tabClose: chord("cmd+w"),
      .historyBack: chord("cmd+["),
      .historyForward: chord("cmd+]"),
      .resourceNext: .scroll(.down),
      .resourcePrevious: .scroll(.up),
      .scrollTop: .scrollEdge(.top),
      .scrollBottom: .scrollEdge(.bottom),
    ]
    for name in SourceActionName.allCases {
      XCTAssertEqual(
        SourceActionFallback.resolve(name, declared: nil), expected[name] ?? .none, name.rawValue)
    }
  }

  func testTabSelectSendsTheCommandDigitForTheFirstNineTabs() {
    for index in 1...9 {
      XCTAssertEqual(SourceActionFallback.tabSelect(index: index), chord("cmd+\(index)"))
    }
    XCTAssertEqual(SourceActionFallback.tabSelect(index: 0), .none)
    XCTAssertEqual(SourceActionFallback.tabSelect(index: 10), .none)
  }

  /// What each default tab and reload key does in the apps no source claims,
  /// from the bundled manifests and the core conventions together.
  func testDefaultActionsResolvePerContextFromTheBundledManifests() throws {
    let index = ActionKeystrokeIndex(manifests: try Self.officialManifests())
    func effect(_ name: SourceActionName, _ bundle: String) -> SourceActionFallback {
      SourceActionFallback.resolve(
        name, declared: index.keystroke(name, in: PluginSelectorContext(bundleID: bundle)))
    }
    let firefox = "org.mozilla.firefox"
    let finder = "com.apple.finder"
    let alacritty = "org.alacritty"
    let vscode = "com.microsoft.VSCode"
    let cursor = "com.todesktop.230313mzl4w4u92"
    let notes = "com.apple.Notes"
    let messages = "com.apple.MobileSMS"
    let rows: [(SourceActionName, String, SourceActionFallback)] = [
      // Browsers: their own chords, Safari's hard reload included.
      (.tabNext, firefox, chord("cmd+shift+]")),
      (.tabNew, firefox, chord("cmd+t")),
      (.tabClose, firefox, chord("cmd+w")),
      (.tabReopen, firefox, chord("cmd+shift+t")),
      (.appReload, firefox, chord("cmd+r")),
      (.appReloadForce, firefox, chord("cmd+shift+r")),
      (.appReloadForce, "com.apple.Safari", chord("cmd+option+r")),
      // Native tabbed apps: the macOS convention, and nothing for reopen,
      // whose Command-Shift-T toggles Finder's tab bar.
      (.tabNext, finder, chord("cmd+shift+]")),
      (.tabPrevious, finder, chord("cmd+shift+[")),
      (.tabNew, finder, chord("cmd+t")),
      (.tabClose, finder, chord("cmd+w")),
      (.tabReopen, finder, .none),
      (.appReload, finder, .none),
      // A terminal without tmux: its own tabs, and no reload or reopen.
      (.tabNext, alacritty, chord("cmd+shift+]")),
      (.tabNew, alacritty, chord("cmd+t")),
      (.tabClose, alacritty, chord("cmd+w")),
      (.tabReopen, alacritty, .none),
      (.appReload, alacritty, .none),
      (.appReloadForce, alacritty, .none),
      // Editors: Command-T searches symbols, so a new tab is Command-N.
      (.tabNew, vscode, chord("cmd+n")),
      (.tabReopen, vscode, chord("cmd+shift+t")),
      (.tabNext, vscode, chord("cmd+shift+]")),
      (.tabNew, cursor, chord("cmd+n")),
      (.tabReopen, cursor, chord("cmd+shift+t")),
      // Apps without tabs or a reload do nothing.
      (.tabNew, notes, .none),
      (.tabReopen, notes, .none),
      (.appReload, notes, .none),
      (.appReload, "com.apple.mail", .none),
      (.appReload, "com.apple.dt.Xcode", .none),
      // Messages switches conversations with Control-Tab.
      (.tabNext, messages, chord("ctrl+tab")),
      (.tabPrevious, messages, chord("ctrl+shift+tab")),
    ]
    for (name, bundle, expected) in rows {
      XCTAssertEqual(effect(name, bundle), expected, "\(name.rawValue) in \(bundle)")
    }
  }

  /// Whatever a default action resolves to in a terminal emulator is a chord
  /// the emulator binds, never one it would type as text.
  func testNoDefaultActionTypesTextInATerminal() throws {
    let index = ActionKeystrokeIndex(manifests: try Self.officialManifests())
    XCTAssertFalse(TerminalEmulatorFixture.official.isEmpty)
    let names: [SourceActionName] = [
      .tabNext, .tabPrevious, .tabFirst, .tabNew, .tabClose, .tabReopen, .appReload,
      .appReloadForce,
    ]
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      let effects =
        names.map { SourceActionFallback.resolve($0, declared: index.keystroke($0, in: context)) }
        + (1...9).map(SourceActionFallback.tabSelect(index:))
      for case .chord(let key, let flags) in effects {
        XCTAssertFalse(
          AppDelegate.commandChordTypesTextInTerminal(key: key, flags: flags) {
            index.declares(key: key, flags: flags, in: context)
          }, "key \(key) flags \(flags.rawValue) in \(emulator)")
      }
    }
  }

  /// Keys map to high-level actions; `send_key` stays an explicit user
  /// escape hatch that no default or bundled plugin mapping uses.
  func testNoBuiltInOrBundledMappingSendsRawKeys() throws {
    let toml = try String(
      contentsOf: Self.repositoryRoot.appendingPathComponent("config.default.toml"),
      encoding: .utf8)
    for (label, mode) in [
      ("built-in", Config.default.mode), ("file", ConfigLoader.parse(toml).mode),
    ] {
      let mappings = mode.all + mode.normal + mode.insert + mode.command + mode.terminal
      XCTAssertFalse(mappings.isEmpty)
      for mapping in mappings {
        XCTAssertFalse(Self.sendsRawKeys(mapping.action), "\(label) \(mapping.key)")
      }
    }
    for manifest in try Self.officialManifests() {
      for registration in manifest.mappings {
        let action = try XCTUnwrap(
          parseMappingCommand(argv: registration.command), "\(manifest.id) \(registration.key)")
        XCTAssertFalse(Self.sendsRawKeys(action), "\(manifest.id) \(registration.key)")
      }
    }
  }

  private static func sendsRawKeys(_ action: MappingCommand) -> Bool {
    switch action {
    case .flashCommand(.sendKey), .flashCommand(.sendKeys):
      return true
    case .flashCommand, .shellCommand:
      return false
    }
  }

  private func chord(_ hotkey: String) -> SourceActionFallback {
    guard let parsed = HotkeySyntax.parse(hotkey: hotkey) else {
      XCTFail("unparseable chord \(hotkey)")
      return .none
    }
    return .chord(key: parsed.keyCode, flags: parsed.eventFlags)
  }

  private static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // FlashTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  /// Every bundled manifest in plugin-id order, as the plugin manager
  /// publishes them.
  private static func officialManifests() throws -> [PluginManifest] {
    let plugins = repositoryRoot.appendingPathComponent("Plugins")
    return try FileManager.default.contentsOfDirectory(
      at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    .filter {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
    }
    .map { try PluginManifest.load(from: $0) }
    .sorted { $0.id < $1.id }
  }
}
