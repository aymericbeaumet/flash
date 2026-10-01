import AppKit
import FlashCore
import XCTest

@testable import flash

/// NORMAL maps keys to high-level actions only. Once no source performs an
/// action in the focused app, the bundled plugins' `action_bindings` decide
/// what that app gets; the host knows no chord.
final class SourceActionFallbackTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  /// Parity with the host conventions, plugin chords and hard-coded verb
  /// chords this table replaced: for each bundled-plugin app, each action
  /// resolves to the chord it got before, refused where a terminal would
  /// type it. Deliberate change: `app_save`, `app_print` and
  /// `document_open` went through a plugin verb that skipped the terminal
  /// rule and typed `s` / `p` / `o` into the shell; they are now refused.
  func testEveryActionResolvesAsBeforeForTheBundledApps() throws {
    let index = ActionBindingIndex(manifests: try Self.officialManifests())
    var checked = 0
    for line in Self.parity.split(separator: "\n") {
      let fields = line.split(separator: "\t").map(String.init)
      XCTAssertEqual(fields.count, 3, String(line))
      let (action, bundle, expected) = (fields[0], fields[1], fields[2])
      let parts = action.split(separator: ":")
      let name = try XCTUnwrap(SourceActionName(rawValue: String(parts[0])), action)
      let tab = parts.count > 1 ? Int(parts[1]) : nil
      let effect = Self.effect(name, index: tab, in: bundle, bindings: index)
      XCTAssertEqual(effect, Self.canonical(expected), "\(action) in \(bundle)")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 600)
  }

  /// Every action the host dispatches resolves to something in a generic
  /// app from the `defaults` plugin alone, except those apps disagree on.
  func testDefaultsBindTheSharedConventionsForEveryApp() throws {
    let defaults = try XCTUnwrap(try Self.officialManifests().first { $0.id == "defaults" })
    let index = ActionBindingIndex(manifests: [defaults])
    let unknown = "com.example.unknown"
    let unbound: Set<SourceActionName> = [
      .tabLast, .tabReopen, .tabMoveNext, .tabMovePrevious, .paneNext, .panePrevious,
      .paneSplitVertical, .paneSplitHorizontal, .paneClose, .appReload, .appReloadForce,
      .resourceArchive, .resourceNext, .resourcePrevious, .scrollTop, .scrollBottom,
    ]
    for name in SourceActionName.allCases {
      let resolution = index.resolve(name, in: PluginSelectorContext(bundleID: unknown))
      XCTAssertEqual(resolution == nil, unbound.contains(name), name.rawValue)
      if let resolution { XCTAssertEqual(resolution.pluginID, "defaults") }
    }
  }

  /// With `plugins.disabled = ["defaults"]` no plugin binds an app's
  /// generic actions, so they do nothing; scrolling stays Flash's own.
  func testWithoutTheDefaultsPluginGenericActionsDoNothing() throws {
    let index = ActionBindingIndex(
      manifests: try Self.officialManifests().filter { $0.id != "defaults" })
    let finder = PluginSelectorContext(bundleID: "com.apple.finder")
    for name in SourceActionName.allCases {
      let fallback = SourceActionFallback.resolve(
        name, binding: index.binding(name, index: 1, in: finder))
      XCTAssertEqual(
        fallback, SourceActionFallback.flashOwned[name] ?? SourceActionFallback.none,
        name.rawValue)
    }
  }

  /// Whatever a default action resolves to in a terminal emulator is a chord
  /// the emulator binds, or refused — never one it would type as text.
  func testNoDefaultActionTypesTextInATerminal() throws {
    let index = ActionBindingIndex(manifests: try Self.officialManifests())
    XCTAssertFalse(TerminalEmulatorFixture.official.isEmpty)
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for name in SourceActionName.allCases {
        guard
          case .binding(let binding) = SourceActionFallback.resolve(
            name, binding: index.binding(name, index: 1, in: context))
        else { continue }
        let plan = ActionBindingDispatch.plan(binding) { key, flags in
          Self.typesText(key: key, flags: flags, in: emulator, bindings: index)
        }
        guard case .sendChords(let chords) = plan else { continue }
        for chord in chords {
          XCTAssertFalse(
            Self.typesText(key: chord.key, flags: chord.flags, in: emulator, bindings: index),
            "\(name.rawValue) in \(emulator)")
        }
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

  // MARK: - Helpers

  private static func sendsRawKeys(_ action: MappingCommand) -> Bool {
    switch action {
    case .flashCommand(.sendKey), .flashCommand(.sendKeys):
      return true
    case .flashCommand, .shellCommand:
      return false
    }
  }

  /// What the action does in `bundle`, as the parity table writes it.
  private static func effect(
    _ name: SourceActionName, index: Int?, in bundle: String, bindings: ActionBindingIndex
  ) -> String {
    let context = PluginSelectorContext(bundleID: bundle)
    switch SourceActionFallback.resolve(
      name, binding: bindings.binding(name, index: index, in: context))
    {
    case .binding(let binding):
      let plan = ActionBindingDispatch.plan(binding) { key, flags in
        typesText(key: key, flags: flags, in: bundle, bindings: bindings)
      }
      switch plan {
      case .sendChords(let chords):
        return chords.map { "\($0.key):\($0.flags.rawValue)" }.joined(separator: ",")
      case .pressMenu(let path): return "menu \(path.joined(separator: "/"))"
      case .refused: return "refused"
      case .unavailable: return "none"
      }
    case .scroll(let kind): return "scroll(\(kind))"
    case .scrollEdge(let kind): return "edge(\(kind))"
    case .none: return "none"
    }
  }

  private static func typesText(
    key: CGKeyCode, flags: CGEventFlags, in bundle: String, bindings: ActionBindingIndex
  ) -> Bool {
    TerminalEmulators.contains(bundle)
      && AppDelegate.commandChordTypesTextInTerminal(key: key, flags: flags) {
        bindings.declares(key: key, flags: flags, in: PluginSelectorContext(bundleID: bundle))
      }
  }

  /// A table chord as `key:flags`; other effects as written.
  private static func canonical(_ value: String) -> String {
    guard let chord = HotkeySyntax.parse(hotkey: value), value.contains("+") else { return value }
    return "\(chord.keyCode):\(chord.eventFlags.rawValue)"
  }

  private static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // FlashTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  /// Every bundled manifest in plugin-id order, as the plugin manager
  /// publishes them.
  static func officialManifests() throws -> [PluginManifest] {
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

  /// Action (`tab_select:<n>` for a tab), bundle id, effect before the
  /// migration: a chord, `refused`, `none`, `scroll(<dir>)`, `edge(<edge>)`.
  private static let parity = """
    tab_next	org.mozilla.firefox	cmd+shift+]
    tab_previous	org.mozilla.firefox	cmd+shift+[
    tab_first	org.mozilla.firefox	cmd+1
    tab_last	org.mozilla.firefox	cmd+9
    tab_new	org.mozilla.firefox	cmd+t
    tab_close	org.mozilla.firefox	cmd+w
    tab_reopen	org.mozilla.firefox	cmd+shift+t
    tab_move_next	org.mozilla.firefox	ctrl+shift+pagedown
    tab_move_previous	org.mozilla.firefox	ctrl+shift+pageup
    pane_next	org.mozilla.firefox	none
    pane_previous	org.mozilla.firefox	none
    pane_split_vertical	org.mozilla.firefox	none
    pane_split_horizontal	org.mozilla.firefox	none
    pane_close	org.mozilla.firefox	none
    app_reload	org.mozilla.firefox	cmd+r
    app_reload_force	org.mozilla.firefox	cmd+shift+r
    resource_archive	org.mozilla.firefox	none
    resource_next	org.mozilla.firefox	scroll(down)
    resource_previous	org.mozilla.firefox	scroll(up)
    scroll_top	org.mozilla.firefox	cmd+up
    scroll_bottom	org.mozilla.firefox	cmd+down
    history_back	org.mozilla.firefox	cmd+[
    history_forward	org.mozilla.firefox	cmd+]
    tab_select:1	org.mozilla.firefox	cmd+1
    tab_select:2	org.mozilla.firefox	cmd+2
    tab_select:9	org.mozilla.firefox	cmd+9
    app_undo	org.mozilla.firefox	cmd+z
    app_redo	org.mozilla.firefox	cmd+shift+z
    app_find	org.mozilla.firefox	cmd+f
    app_save	org.mozilla.firefox	cmd+s
    app_print	org.mozilla.firefox	cmd+p
    document_open	org.mozilla.firefox	cmd+o
    window_new	org.mozilla.firefox	cmd+n
    window_close	org.mozilla.firefox	cmd+w
    clipboard_copy	org.mozilla.firefox	cmd+c
    clipboard_cut	org.mozilla.firefox	cmd+x
    clipboard_paste	org.mozilla.firefox	cmd+v
    tab_next	com.apple.Safari	cmd+shift+]
    tab_previous	com.apple.Safari	cmd+shift+[
    tab_first	com.apple.Safari	cmd+1
    tab_last	com.apple.Safari	cmd+9
    tab_new	com.apple.Safari	cmd+t
    tab_close	com.apple.Safari	cmd+w
    tab_reopen	com.apple.Safari	cmd+shift+t
    tab_move_next	com.apple.Safari	ctrl+shift+pagedown
    tab_move_previous	com.apple.Safari	ctrl+shift+pageup
    pane_next	com.apple.Safari	none
    pane_previous	com.apple.Safari	none
    pane_split_vertical	com.apple.Safari	none
    pane_split_horizontal	com.apple.Safari	none
    pane_close	com.apple.Safari	none
    app_reload	com.apple.Safari	cmd+r
    app_reload_force	com.apple.Safari	cmd+option+r
    resource_archive	com.apple.Safari	none
    resource_next	com.apple.Safari	scroll(down)
    resource_previous	com.apple.Safari	scroll(up)
    scroll_top	com.apple.Safari	cmd+up
    scroll_bottom	com.apple.Safari	cmd+down
    history_back	com.apple.Safari	cmd+[
    history_forward	com.apple.Safari	cmd+]
    tab_select:1	com.apple.Safari	cmd+1
    tab_select:2	com.apple.Safari	cmd+2
    tab_select:9	com.apple.Safari	cmd+9
    app_undo	com.apple.Safari	cmd+z
    app_redo	com.apple.Safari	cmd+shift+z
    app_find	com.apple.Safari	cmd+f
    app_save	com.apple.Safari	cmd+s
    app_print	com.apple.Safari	cmd+p
    document_open	com.apple.Safari	cmd+o
    window_new	com.apple.Safari	cmd+n
    window_close	com.apple.Safari	cmd+w
    clipboard_copy	com.apple.Safari	cmd+c
    clipboard_cut	com.apple.Safari	cmd+x
    clipboard_paste	com.apple.Safari	cmd+v
    tab_next	com.google.Chrome	cmd+shift+]
    tab_previous	com.google.Chrome	cmd+shift+[
    tab_first	com.google.Chrome	cmd+1
    tab_last	com.google.Chrome	cmd+9
    tab_new	com.google.Chrome	cmd+t
    tab_close	com.google.Chrome	cmd+w
    tab_reopen	com.google.Chrome	cmd+shift+t
    tab_move_next	com.google.Chrome	ctrl+shift+pagedown
    tab_move_previous	com.google.Chrome	ctrl+shift+pageup
    pane_next	com.google.Chrome	none
    pane_previous	com.google.Chrome	none
    pane_split_vertical	com.google.Chrome	none
    pane_split_horizontal	com.google.Chrome	none
    pane_close	com.google.Chrome	none
    app_reload	com.google.Chrome	cmd+r
    app_reload_force	com.google.Chrome	cmd+shift+r
    resource_archive	com.google.Chrome	none
    resource_next	com.google.Chrome	scroll(down)
    resource_previous	com.google.Chrome	scroll(up)
    scroll_top	com.google.Chrome	cmd+up
    scroll_bottom	com.google.Chrome	cmd+down
    history_back	com.google.Chrome	cmd+[
    history_forward	com.google.Chrome	cmd+]
    tab_select:1	com.google.Chrome	cmd+1
    tab_select:2	com.google.Chrome	cmd+2
    tab_select:9	com.google.Chrome	cmd+9
    app_undo	com.google.Chrome	cmd+z
    app_redo	com.google.Chrome	cmd+shift+z
    app_find	com.google.Chrome	cmd+f
    app_save	com.google.Chrome	cmd+s
    app_print	com.google.Chrome	cmd+p
    document_open	com.google.Chrome	cmd+o
    window_new	com.google.Chrome	cmd+n
    window_close	com.google.Chrome	cmd+w
    clipboard_copy	com.google.Chrome	cmd+c
    clipboard_cut	com.google.Chrome	cmd+x
    clipboard_paste	com.google.Chrome	cmd+v
    tab_next	com.apple.finder	cmd+shift+]
    tab_previous	com.apple.finder	cmd+shift+[
    tab_first	com.apple.finder	cmd+1
    tab_last	com.apple.finder	none
    tab_new	com.apple.finder	cmd+t
    tab_close	com.apple.finder	cmd+w
    tab_reopen	com.apple.finder	none
    tab_move_next	com.apple.finder	none
    tab_move_previous	com.apple.finder	none
    pane_next	com.apple.finder	none
    pane_previous	com.apple.finder	none
    pane_split_vertical	com.apple.finder	none
    pane_split_horizontal	com.apple.finder	none
    pane_close	com.apple.finder	none
    app_reload	com.apple.finder	none
    app_reload_force	com.apple.finder	none
    resource_archive	com.apple.finder	none
    resource_next	com.apple.finder	scroll(down)
    resource_previous	com.apple.finder	scroll(up)
    scroll_top	com.apple.finder	edge(top)
    scroll_bottom	com.apple.finder	edge(bottom)
    history_back	com.apple.finder	cmd+[
    history_forward	com.apple.finder	cmd+]
    tab_select:1	com.apple.finder	cmd+1
    tab_select:2	com.apple.finder	cmd+2
    tab_select:9	com.apple.finder	cmd+9
    app_undo	com.apple.finder	cmd+z
    app_redo	com.apple.finder	cmd+shift+z
    app_find	com.apple.finder	cmd+f
    app_save	com.apple.finder	cmd+s
    app_print	com.apple.finder	cmd+p
    document_open	com.apple.finder	cmd+o
    window_new	com.apple.finder	cmd+n
    window_close	com.apple.finder	cmd+w
    clipboard_copy	com.apple.finder	cmd+c
    clipboard_cut	com.apple.finder	cmd+x
    clipboard_paste	com.apple.finder	cmd+v
    tab_next	org.alacritty	cmd+shift+]
    tab_previous	org.alacritty	cmd+shift+[
    tab_first	org.alacritty	cmd+1
    tab_last	org.alacritty	none
    tab_new	org.alacritty	cmd+t
    tab_close	org.alacritty	cmd+w
    tab_reopen	org.alacritty	none
    tab_move_next	org.alacritty	none
    tab_move_previous	org.alacritty	none
    pane_next	org.alacritty	none
    pane_previous	org.alacritty	none
    pane_split_vertical	org.alacritty	none
    pane_split_horizontal	org.alacritty	none
    pane_close	org.alacritty	none
    app_reload	org.alacritty	none
    app_reload_force	org.alacritty	none
    resource_archive	org.alacritty	none
    resource_next	org.alacritty	scroll(down)
    resource_previous	org.alacritty	scroll(up)
    scroll_top	org.alacritty	edge(top)
    scroll_bottom	org.alacritty	edge(bottom)
    history_back	org.alacritty	none
    history_forward	org.alacritty	none
    tab_select:1	org.alacritty	cmd+1
    tab_select:2	org.alacritty	cmd+2
    tab_select:9	org.alacritty	cmd+9
    app_undo	org.alacritty	refused
    app_redo	org.alacritty	refused
    app_find	org.alacritty	cmd+f
    app_save	org.alacritty	refused
    app_print	org.alacritty	refused
    document_open	org.alacritty	refused
    window_new	org.alacritty	cmd+n
    window_close	org.alacritty	cmd+w
    clipboard_copy	org.alacritty	cmd+c
    clipboard_cut	org.alacritty	refused
    clipboard_paste	org.alacritty	cmd+v
    tab_next	com.mitchellh.ghostty	cmd+shift+]
    tab_previous	com.mitchellh.ghostty	cmd+shift+[
    tab_first	com.mitchellh.ghostty	cmd+1
    tab_last	com.mitchellh.ghostty	none
    tab_new	com.mitchellh.ghostty	cmd+t
    tab_close	com.mitchellh.ghostty	cmd+w
    tab_reopen	com.mitchellh.ghostty	none
    tab_move_next	com.mitchellh.ghostty	none
    tab_move_previous	com.mitchellh.ghostty	none
    pane_next	com.mitchellh.ghostty	cmd+]
    pane_previous	com.mitchellh.ghostty	cmd+[
    pane_split_vertical	com.mitchellh.ghostty	none
    pane_split_horizontal	com.mitchellh.ghostty	none
    pane_close	com.mitchellh.ghostty	none
    app_reload	com.mitchellh.ghostty	none
    app_reload_force	com.mitchellh.ghostty	none
    resource_archive	com.mitchellh.ghostty	none
    resource_next	com.mitchellh.ghostty	scroll(down)
    resource_previous	com.mitchellh.ghostty	scroll(up)
    scroll_top	com.mitchellh.ghostty	edge(top)
    scroll_bottom	com.mitchellh.ghostty	edge(bottom)
    history_back	com.mitchellh.ghostty	none
    history_forward	com.mitchellh.ghostty	none
    tab_select:1	com.mitchellh.ghostty	cmd+1
    tab_select:2	com.mitchellh.ghostty	cmd+2
    tab_select:9	com.mitchellh.ghostty	cmd+9
    app_undo	com.mitchellh.ghostty	refused
    app_redo	com.mitchellh.ghostty	refused
    app_find	com.mitchellh.ghostty	cmd+f
    app_save	com.mitchellh.ghostty	refused
    app_print	com.mitchellh.ghostty	refused
    document_open	com.mitchellh.ghostty	refused
    window_new	com.mitchellh.ghostty	cmd+n
    window_close	com.mitchellh.ghostty	cmd+w
    clipboard_copy	com.mitchellh.ghostty	cmd+c
    clipboard_cut	com.mitchellh.ghostty	refused
    clipboard_paste	com.mitchellh.ghostty	cmd+v
    tab_next	com.googlecode.iterm2	cmd+shift+]
    tab_previous	com.googlecode.iterm2	cmd+shift+[
    tab_first	com.googlecode.iterm2	cmd+1
    tab_last	com.googlecode.iterm2	none
    tab_new	com.googlecode.iterm2	cmd+t
    tab_close	com.googlecode.iterm2	cmd+w
    tab_reopen	com.googlecode.iterm2	none
    tab_move_next	com.googlecode.iterm2	none
    tab_move_previous	com.googlecode.iterm2	none
    pane_next	com.googlecode.iterm2	cmd+]
    pane_previous	com.googlecode.iterm2	cmd+[
    pane_split_vertical	com.googlecode.iterm2	none
    pane_split_horizontal	com.googlecode.iterm2	none
    pane_close	com.googlecode.iterm2	none
    app_reload	com.googlecode.iterm2	none
    app_reload_force	com.googlecode.iterm2	none
    resource_archive	com.googlecode.iterm2	none
    resource_next	com.googlecode.iterm2	scroll(down)
    resource_previous	com.googlecode.iterm2	scroll(up)
    scroll_top	com.googlecode.iterm2	edge(top)
    scroll_bottom	com.googlecode.iterm2	edge(bottom)
    history_back	com.googlecode.iterm2	none
    history_forward	com.googlecode.iterm2	none
    tab_select:1	com.googlecode.iterm2	cmd+1
    tab_select:2	com.googlecode.iterm2	cmd+2
    tab_select:9	com.googlecode.iterm2	cmd+9
    app_undo	com.googlecode.iterm2	refused
    app_redo	com.googlecode.iterm2	refused
    app_find	com.googlecode.iterm2	cmd+f
    app_save	com.googlecode.iterm2	refused
    app_print	com.googlecode.iterm2	refused
    document_open	com.googlecode.iterm2	refused
    window_new	com.googlecode.iterm2	cmd+n
    window_close	com.googlecode.iterm2	cmd+w
    clipboard_copy	com.googlecode.iterm2	cmd+c
    clipboard_cut	com.googlecode.iterm2	refused
    clipboard_paste	com.googlecode.iterm2	cmd+v
    tab_next	com.apple.Terminal	cmd+shift+]
    tab_previous	com.apple.Terminal	cmd+shift+[
    tab_first	com.apple.Terminal	cmd+1
    tab_last	com.apple.Terminal	none
    tab_new	com.apple.Terminal	cmd+t
    tab_close	com.apple.Terminal	cmd+w
    tab_reopen	com.apple.Terminal	none
    tab_move_next	com.apple.Terminal	none
    tab_move_previous	com.apple.Terminal	none
    pane_next	com.apple.Terminal	none
    pane_previous	com.apple.Terminal	none
    pane_split_vertical	com.apple.Terminal	none
    pane_split_horizontal	com.apple.Terminal	none
    pane_close	com.apple.Terminal	none
    app_reload	com.apple.Terminal	none
    app_reload_force	com.apple.Terminal	none
    resource_archive	com.apple.Terminal	none
    resource_next	com.apple.Terminal	scroll(down)
    resource_previous	com.apple.Terminal	scroll(up)
    scroll_top	com.apple.Terminal	edge(top)
    scroll_bottom	com.apple.Terminal	edge(bottom)
    history_back	com.apple.Terminal	none
    history_forward	com.apple.Terminal	none
    tab_select:1	com.apple.Terminal	cmd+1
    tab_select:2	com.apple.Terminal	cmd+2
    tab_select:9	com.apple.Terminal	cmd+9
    app_undo	com.apple.Terminal	refused
    app_redo	com.apple.Terminal	refused
    app_find	com.apple.Terminal	cmd+f
    app_save	com.apple.Terminal	refused
    app_print	com.apple.Terminal	refused
    document_open	com.apple.Terminal	refused
    window_new	com.apple.Terminal	cmd+n
    window_close	com.apple.Terminal	cmd+w
    clipboard_copy	com.apple.Terminal	cmd+c
    clipboard_cut	com.apple.Terminal	refused
    clipboard_paste	com.apple.Terminal	cmd+v
    tab_next	com.microsoft.VSCode	cmd+shift+]
    tab_previous	com.microsoft.VSCode	cmd+shift+[
    tab_first	com.microsoft.VSCode	cmd+1
    tab_last	com.microsoft.VSCode	none
    tab_new	com.microsoft.VSCode	cmd+n
    tab_close	com.microsoft.VSCode	cmd+w
    tab_reopen	com.microsoft.VSCode	cmd+shift+t
    tab_move_next	com.microsoft.VSCode	none
    tab_move_previous	com.microsoft.VSCode	none
    pane_next	com.microsoft.VSCode	none
    pane_previous	com.microsoft.VSCode	none
    pane_split_vertical	com.microsoft.VSCode	none
    pane_split_horizontal	com.microsoft.VSCode	none
    pane_close	com.microsoft.VSCode	none
    app_reload	com.microsoft.VSCode	none
    app_reload_force	com.microsoft.VSCode	none
    resource_archive	com.microsoft.VSCode	none
    resource_next	com.microsoft.VSCode	scroll(down)
    resource_previous	com.microsoft.VSCode	scroll(up)
    scroll_top	com.microsoft.VSCode	edge(top)
    scroll_bottom	com.microsoft.VSCode	edge(bottom)
    history_back	com.microsoft.VSCode	ctrl+-
    history_forward	com.microsoft.VSCode	ctrl+shift+-
    tab_select:1	com.microsoft.VSCode	cmd+1
    tab_select:2	com.microsoft.VSCode	cmd+2
    tab_select:9	com.microsoft.VSCode	cmd+9
    app_undo	com.microsoft.VSCode	cmd+z
    app_redo	com.microsoft.VSCode	cmd+shift+z
    app_find	com.microsoft.VSCode	cmd+f
    app_save	com.microsoft.VSCode	cmd+s
    app_print	com.microsoft.VSCode	cmd+p
    document_open	com.microsoft.VSCode	cmd+o
    window_new	com.microsoft.VSCode	cmd+n
    window_close	com.microsoft.VSCode	cmd+w
    clipboard_copy	com.microsoft.VSCode	cmd+c
    clipboard_cut	com.microsoft.VSCode	cmd+x
    clipboard_paste	com.microsoft.VSCode	cmd+v
    tab_next	com.todesktop.230313mzl4w4u92	cmd+shift+]
    tab_previous	com.todesktop.230313mzl4w4u92	cmd+shift+[
    tab_first	com.todesktop.230313mzl4w4u92	cmd+1
    tab_last	com.todesktop.230313mzl4w4u92	none
    tab_new	com.todesktop.230313mzl4w4u92	cmd+n
    tab_close	com.todesktop.230313mzl4w4u92	cmd+w
    tab_reopen	com.todesktop.230313mzl4w4u92	cmd+shift+t
    tab_move_next	com.todesktop.230313mzl4w4u92	none
    tab_move_previous	com.todesktop.230313mzl4w4u92	none
    pane_next	com.todesktop.230313mzl4w4u92	none
    pane_previous	com.todesktop.230313mzl4w4u92	none
    pane_split_vertical	com.todesktop.230313mzl4w4u92	none
    pane_split_horizontal	com.todesktop.230313mzl4w4u92	none
    pane_close	com.todesktop.230313mzl4w4u92	none
    app_reload	com.todesktop.230313mzl4w4u92	none
    app_reload_force	com.todesktop.230313mzl4w4u92	none
    resource_archive	com.todesktop.230313mzl4w4u92	none
    resource_next	com.todesktop.230313mzl4w4u92	scroll(down)
    resource_previous	com.todesktop.230313mzl4w4u92	scroll(up)
    scroll_top	com.todesktop.230313mzl4w4u92	edge(top)
    scroll_bottom	com.todesktop.230313mzl4w4u92	edge(bottom)
    history_back	com.todesktop.230313mzl4w4u92	ctrl+-
    history_forward	com.todesktop.230313mzl4w4u92	ctrl+shift+-
    tab_select:1	com.todesktop.230313mzl4w4u92	cmd+1
    tab_select:2	com.todesktop.230313mzl4w4u92	cmd+2
    tab_select:9	com.todesktop.230313mzl4w4u92	cmd+9
    app_undo	com.todesktop.230313mzl4w4u92	cmd+z
    app_redo	com.todesktop.230313mzl4w4u92	cmd+shift+z
    app_find	com.todesktop.230313mzl4w4u92	cmd+f
    app_save	com.todesktop.230313mzl4w4u92	cmd+s
    app_print	com.todesktop.230313mzl4w4u92	cmd+p
    document_open	com.todesktop.230313mzl4w4u92	cmd+o
    window_new	com.todesktop.230313mzl4w4u92	cmd+n
    window_close	com.todesktop.230313mzl4w4u92	cmd+w
    clipboard_copy	com.todesktop.230313mzl4w4u92	cmd+c
    clipboard_cut	com.todesktop.230313mzl4w4u92	cmd+x
    clipboard_paste	com.todesktop.230313mzl4w4u92	cmd+v
    tab_next	dev.zed.Zed	cmd+shift+]
    tab_previous	dev.zed.Zed	cmd+shift+[
    tab_first	dev.zed.Zed	cmd+1
    tab_last	dev.zed.Zed	none
    tab_new	dev.zed.Zed	cmd+n
    tab_close	dev.zed.Zed	cmd+w
    tab_reopen	dev.zed.Zed	cmd+shift+t
    tab_move_next	dev.zed.Zed	none
    tab_move_previous	dev.zed.Zed	none
    pane_next	dev.zed.Zed	none
    pane_previous	dev.zed.Zed	none
    pane_split_vertical	dev.zed.Zed	none
    pane_split_horizontal	dev.zed.Zed	none
    pane_close	dev.zed.Zed	none
    app_reload	dev.zed.Zed	none
    app_reload_force	dev.zed.Zed	none
    resource_archive	dev.zed.Zed	none
    resource_next	dev.zed.Zed	scroll(down)
    resource_previous	dev.zed.Zed	scroll(up)
    scroll_top	dev.zed.Zed	edge(top)
    scroll_bottom	dev.zed.Zed	edge(bottom)
    history_back	dev.zed.Zed	ctrl+-
    history_forward	dev.zed.Zed	ctrl+shift+-
    tab_select:1	dev.zed.Zed	cmd+1
    tab_select:2	dev.zed.Zed	cmd+2
    tab_select:9	dev.zed.Zed	cmd+9
    app_undo	dev.zed.Zed	cmd+z
    app_redo	dev.zed.Zed	cmd+shift+z
    app_find	dev.zed.Zed	cmd+f
    app_save	dev.zed.Zed	cmd+s
    app_print	dev.zed.Zed	cmd+p
    document_open	dev.zed.Zed	cmd+o
    window_new	dev.zed.Zed	cmd+n
    window_close	dev.zed.Zed	cmd+w
    clipboard_copy	dev.zed.Zed	cmd+c
    clipboard_cut	dev.zed.Zed	cmd+x
    clipboard_paste	dev.zed.Zed	cmd+v
    tab_next	com.apple.Notes	cmd+shift+]
    tab_previous	com.apple.Notes	cmd+shift+[
    tab_first	com.apple.Notes	cmd+1
    tab_last	com.apple.Notes	none
    tab_new	com.apple.Notes	none
    tab_close	com.apple.Notes	cmd+w
    tab_reopen	com.apple.Notes	none
    tab_move_next	com.apple.Notes	none
    tab_move_previous	com.apple.Notes	none
    pane_next	com.apple.Notes	none
    pane_previous	com.apple.Notes	none
    pane_split_vertical	com.apple.Notes	none
    pane_split_horizontal	com.apple.Notes	none
    pane_close	com.apple.Notes	none
    app_reload	com.apple.Notes	none
    app_reload_force	com.apple.Notes	none
    resource_archive	com.apple.Notes	none
    resource_next	com.apple.Notes	scroll(down)
    resource_previous	com.apple.Notes	scroll(up)
    scroll_top	com.apple.Notes	edge(top)
    scroll_bottom	com.apple.Notes	edge(bottom)
    history_back	com.apple.Notes	none
    history_forward	com.apple.Notes	none
    tab_select:1	com.apple.Notes	cmd+1
    tab_select:2	com.apple.Notes	cmd+2
    tab_select:9	com.apple.Notes	cmd+9
    app_undo	com.apple.Notes	cmd+z
    app_redo	com.apple.Notes	cmd+shift+z
    app_find	com.apple.Notes	cmd+f
    app_save	com.apple.Notes	cmd+s
    app_print	com.apple.Notes	cmd+p
    document_open	com.apple.Notes	cmd+o
    window_new	com.apple.Notes	cmd+n
    window_close	com.apple.Notes	cmd+w
    clipboard_copy	com.apple.Notes	cmd+c
    clipboard_cut	com.apple.Notes	cmd+x
    clipboard_paste	com.apple.Notes	cmd+v
    tab_next	com.apple.MobileSMS	ctrl+tab
    tab_previous	com.apple.MobileSMS	ctrl+shift+tab
    tab_first	com.apple.MobileSMS	cmd+1
    tab_last	com.apple.MobileSMS	none
    tab_new	com.apple.MobileSMS	cmd+t
    tab_close	com.apple.MobileSMS	cmd+w
    tab_reopen	com.apple.MobileSMS	none
    tab_move_next	com.apple.MobileSMS	none
    tab_move_previous	com.apple.MobileSMS	none
    pane_next	com.apple.MobileSMS	none
    pane_previous	com.apple.MobileSMS	none
    pane_split_vertical	com.apple.MobileSMS	none
    pane_split_horizontal	com.apple.MobileSMS	none
    pane_close	com.apple.MobileSMS	none
    app_reload	com.apple.MobileSMS	none
    app_reload_force	com.apple.MobileSMS	none
    resource_archive	com.apple.MobileSMS	none
    resource_next	com.apple.MobileSMS	scroll(down)
    resource_previous	com.apple.MobileSMS	scroll(up)
    scroll_top	com.apple.MobileSMS	edge(top)
    scroll_bottom	com.apple.MobileSMS	edge(bottom)
    history_back	com.apple.MobileSMS	cmd+[
    history_forward	com.apple.MobileSMS	cmd+]
    tab_select:1	com.apple.MobileSMS	cmd+1
    tab_select:2	com.apple.MobileSMS	cmd+2
    tab_select:9	com.apple.MobileSMS	cmd+9
    app_undo	com.apple.MobileSMS	cmd+z
    app_redo	com.apple.MobileSMS	cmd+shift+z
    app_find	com.apple.MobileSMS	cmd+f
    app_save	com.apple.MobileSMS	cmd+s
    app_print	com.apple.MobileSMS	cmd+p
    document_open	com.apple.MobileSMS	cmd+o
    window_new	com.apple.MobileSMS	cmd+n
    window_close	com.apple.MobileSMS	cmd+w
    clipboard_copy	com.apple.MobileSMS	cmd+c
    clipboard_cut	com.apple.MobileSMS	cmd+x
    clipboard_paste	com.apple.MobileSMS	cmd+v
    tab_next	com.apple.mail	cmd+shift+]
    tab_previous	com.apple.mail	cmd+shift+[
    tab_first	com.apple.mail	cmd+1
    tab_last	com.apple.mail	none
    tab_new	com.apple.mail	none
    tab_close	com.apple.mail	cmd+w
    tab_reopen	com.apple.mail	none
    tab_move_next	com.apple.mail	none
    tab_move_previous	com.apple.mail	none
    pane_next	com.apple.mail	none
    pane_previous	com.apple.mail	none
    pane_split_vertical	com.apple.mail	none
    pane_split_horizontal	com.apple.mail	none
    pane_close	com.apple.mail	none
    app_reload	com.apple.mail	none
    app_reload_force	com.apple.mail	none
    resource_archive	com.apple.mail	none
    resource_next	com.apple.mail	scroll(down)
    resource_previous	com.apple.mail	scroll(up)
    scroll_top	com.apple.mail	edge(top)
    scroll_bottom	com.apple.mail	edge(bottom)
    history_back	com.apple.mail	none
    history_forward	com.apple.mail	none
    tab_select:1	com.apple.mail	cmd+1
    tab_select:2	com.apple.mail	cmd+2
    tab_select:9	com.apple.mail	cmd+9
    app_undo	com.apple.mail	cmd+z
    app_redo	com.apple.mail	cmd+shift+z
    app_find	com.apple.mail	cmd+f
    app_save	com.apple.mail	cmd+s
    app_print	com.apple.mail	cmd+p
    document_open	com.apple.mail	cmd+o
    window_new	com.apple.mail	cmd+n
    window_close	com.apple.mail	cmd+w
    clipboard_copy	com.apple.mail	cmd+c
    clipboard_cut	com.apple.mail	cmd+x
    clipboard_paste	com.apple.mail	cmd+v
    tab_next	com.apple.dt.Xcode	cmd+shift+]
    tab_previous	com.apple.dt.Xcode	cmd+shift+[
    tab_first	com.apple.dt.Xcode	cmd+1
    tab_last	com.apple.dt.Xcode	none
    tab_new	com.apple.dt.Xcode	cmd+t
    tab_close	com.apple.dt.Xcode	cmd+w
    tab_reopen	com.apple.dt.Xcode	none
    tab_move_next	com.apple.dt.Xcode	none
    tab_move_previous	com.apple.dt.Xcode	none
    pane_next	com.apple.dt.Xcode	none
    pane_previous	com.apple.dt.Xcode	none
    pane_split_vertical	com.apple.dt.Xcode	none
    pane_split_horizontal	com.apple.dt.Xcode	none
    pane_close	com.apple.dt.Xcode	none
    app_reload	com.apple.dt.Xcode	none
    app_reload_force	com.apple.dt.Xcode	none
    resource_archive	com.apple.dt.Xcode	none
    resource_next	com.apple.dt.Xcode	scroll(down)
    resource_previous	com.apple.dt.Xcode	scroll(up)
    scroll_top	com.apple.dt.Xcode	edge(top)
    scroll_bottom	com.apple.dt.Xcode	edge(bottom)
    history_back	com.apple.dt.Xcode	ctrl+cmd+left
    history_forward	com.apple.dt.Xcode	ctrl+cmd+right
    tab_select:1	com.apple.dt.Xcode	cmd+1
    tab_select:2	com.apple.dt.Xcode	cmd+2
    tab_select:9	com.apple.dt.Xcode	cmd+9
    app_undo	com.apple.dt.Xcode	cmd+z
    app_redo	com.apple.dt.Xcode	cmd+shift+z
    app_find	com.apple.dt.Xcode	cmd+f
    app_save	com.apple.dt.Xcode	cmd+s
    app_print	com.apple.dt.Xcode	cmd+p
    document_open	com.apple.dt.Xcode	cmd+o
    window_new	com.apple.dt.Xcode	cmd+n
    window_close	com.apple.dt.Xcode	cmd+w
    clipboard_copy	com.apple.dt.Xcode	cmd+c
    clipboard_cut	com.apple.dt.Xcode	cmd+x
    clipboard_paste	com.apple.dt.Xcode	cmd+v
    tab_next	com.apple.TextEdit	cmd+shift+]
    tab_previous	com.apple.TextEdit	cmd+shift+[
    tab_first	com.apple.TextEdit	cmd+1
    tab_last	com.apple.TextEdit	none
    tab_new	com.apple.TextEdit	none
    tab_close	com.apple.TextEdit	cmd+w
    tab_reopen	com.apple.TextEdit	none
    tab_move_next	com.apple.TextEdit	none
    tab_move_previous	com.apple.TextEdit	none
    pane_next	com.apple.TextEdit	none
    pane_previous	com.apple.TextEdit	none
    pane_split_vertical	com.apple.TextEdit	none
    pane_split_horizontal	com.apple.TextEdit	none
    pane_close	com.apple.TextEdit	none
    app_reload	com.apple.TextEdit	none
    app_reload_force	com.apple.TextEdit	none
    resource_archive	com.apple.TextEdit	none
    resource_next	com.apple.TextEdit	scroll(down)
    resource_previous	com.apple.TextEdit	scroll(up)
    scroll_top	com.apple.TextEdit	edge(top)
    scroll_bottom	com.apple.TextEdit	edge(bottom)
    history_back	com.apple.TextEdit	none
    history_forward	com.apple.TextEdit	none
    tab_select:1	com.apple.TextEdit	cmd+1
    tab_select:2	com.apple.TextEdit	cmd+2
    tab_select:9	com.apple.TextEdit	cmd+9
    app_undo	com.apple.TextEdit	cmd+z
    app_redo	com.apple.TextEdit	cmd+shift+z
    app_find	com.apple.TextEdit	cmd+f
    app_save	com.apple.TextEdit	cmd+s
    app_print	com.apple.TextEdit	cmd+p
    document_open	com.apple.TextEdit	cmd+o
    window_new	com.apple.TextEdit	cmd+n
    window_close	com.apple.TextEdit	cmd+w
    clipboard_copy	com.apple.TextEdit	cmd+c
    clipboard_cut	com.apple.TextEdit	cmd+x
    clipboard_paste	com.apple.TextEdit	cmd+v
    tab_next	com.example.unknown	cmd+shift+]
    tab_previous	com.example.unknown	cmd+shift+[
    tab_first	com.example.unknown	cmd+1
    tab_last	com.example.unknown	none
    tab_new	com.example.unknown	cmd+t
    tab_close	com.example.unknown	cmd+w
    tab_reopen	com.example.unknown	none
    tab_move_next	com.example.unknown	none
    tab_move_previous	com.example.unknown	none
    pane_next	com.example.unknown	none
    pane_previous	com.example.unknown	none
    pane_split_vertical	com.example.unknown	none
    pane_split_horizontal	com.example.unknown	none
    pane_close	com.example.unknown	none
    app_reload	com.example.unknown	none
    app_reload_force	com.example.unknown	none
    resource_archive	com.example.unknown	none
    resource_next	com.example.unknown	scroll(down)
    resource_previous	com.example.unknown	scroll(up)
    scroll_top	com.example.unknown	edge(top)
    scroll_bottom	com.example.unknown	edge(bottom)
    history_back	com.example.unknown	cmd+[
    history_forward	com.example.unknown	cmd+]
    tab_select:1	com.example.unknown	cmd+1
    tab_select:2	com.example.unknown	cmd+2
    tab_select:9	com.example.unknown	cmd+9
    app_undo	com.example.unknown	cmd+z
    app_redo	com.example.unknown	cmd+shift+z
    app_find	com.example.unknown	cmd+f
    app_save	com.example.unknown	cmd+s
    app_print	com.example.unknown	cmd+p
    document_open	com.example.unknown	cmd+o
    window_new	com.example.unknown	cmd+n
    window_close	com.example.unknown	cmd+w
    clipboard_copy	com.example.unknown	cmd+c
    clipboard_cut	com.example.unknown	cmd+x
    clipboard_paste	com.example.unknown	cmd+v
    """
}
