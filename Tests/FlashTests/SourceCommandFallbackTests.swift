import AppKit
import FlashCore
import XCTest

@testable import flash

/// NORMAL maps keys to commands only. Once no source performs a command in
/// the focused app, the bundled plugins' `bindings` decide what that app
/// gets; the host knows no chord.
final class SourceCommandFallbackTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  /// Parity with the host conventions, plugin chords and hard-coded verb
  /// chords this table replaced: for each bundled-plugin app, each command
  /// resolves to the chord it got before, refused where a terminal would
  /// type it. Deliberate change: `app save`, `app print` and
  /// `document open` went through a plugin verb that skipped the terminal
  /// rule and typed `s` / `p` / `o` into the shell; they are now refused.
  /// Another: `tab close` is unbound in Messages, Notes, TextEdit and Mail,
  /// which have no tab, so `:q` (`app close`) closes their window or quits
  /// them with their last one instead of posting Cmd-W.
  func testEveryCommandResolvesAsBeforeForTheBundledApps() throws {
    let index = CommandBindingIndex(manifests: try Self.officialManifests())
    var checked = 0
    for line in Self.parity.split(separator: "\n") {
      let fields = line.split(separator: "\t").map(String.init)
      XCTAssertEqual(fields.count, 3, String(line))
      let (spelled, bundle, expected) = (fields[0], fields[1], fields[2])
      let parts = spelled.split(separator: ":")
      let key = try XCTUnwrap(CommandBindingKey(String(parts[0])), spelled)
      let tab = parts.count > 1 ? Int(parts[1]) : nil
      let effect = Self.effect(key, index: tab, in: bundle, bindings: index)
      XCTAssertEqual(effect, Self.canonical(expected), "\(spelled) in \(bundle)")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 600)
  }

  /// Every command the host asks of the focused app resolves to something in
  /// a generic app from the `defaults` plugin alone, except those apps
  /// disagree on.
  func testDefaultsBindTheSharedConventionsForEveryApp() throws {
    let defaults = try XCTUnwrap(try Self.officialManifests().first { $0.id == "defaults" })
    let index = CommandBindingIndex(manifests: [defaults])
    let unknown = "com.example.unknown"
    let unbound = Set(
      [
        "tab last", "tab reopen", "tab move_next", "tab move_previous", "pane next",
        "pane previous", "pane split_vertical", "pane split_horizontal", "pane close",
        "app reload", "app reload --force", "resource archive", "resource next",
        "resource previous", "scroll top", "scroll bottom", "app view_source",
        // A list's first and last items have no shared chord (Finder's Cmd-Up
        // opens the enclosing folder): Flash's scroller reaches the edge.
        "move top", "move bottom",
        // Vim's motions macOS has no chord for: without the app's text,
        // nothing is guessed.
        "cursor next_word", "cursor next_big_word", "cursor previous_word_end",
        "cursor previous_big_word_end", "cursor first_nonblank", "cursor last_nonblank",
        "cursor column", "cursor matching_bracket", "cursor next_paragraph",
        "cursor previous_paragraph", "cursor next_sentence", "cursor previous_sentence",
        "cursor next_line", "cursor previous_line", "cursor line_nonblank",
        "cursor screen_top", "cursor screen_middle", "cursor screen_bottom",
        // Only document apps duplicate, and only browsers have these; tabs
        // pin, mute and detach where an app binds it.
        "document duplicate", "url bookmark", "url edit", "history show",
        "window new --private", "app stop", "app downloads", "app developer_tools",
        "tab duplicate", "tab pin", "tab mute", "tab detach",
      ].map { CommandBindingKey($0)! })
    XCTAssertTrue(unbound.isSubset(of: Set(URLEventHandler.sourceCommandBindingKeys)))
    for key in URLEventHandler.sourceCommandBindingKeys {
      let resolution = index.resolve(key, in: PluginSelectorContext(bundleID: unknown))
      XCTAssertEqual(resolution == nil, unbound.contains(key), key.description)
      if let resolution { XCTAssertEqual(resolution.pluginID, "defaults") }
    }
  }

  /// With `plugins.disabled = ["defaults"]` no plugin binds an app's
  /// generic commands, so they do nothing; scrolling stays Flash's own.
  func testWithoutTheDefaultsPluginGenericCommandsDoNothing() throws {
    let index = CommandBindingIndex(
      manifests: try Self.officialManifests().filter { $0.id != "defaults" })
    let finder = PluginSelectorContext(bundleID: "com.apple.finder")
    for key in URLEventHandler.sourceCommandBindingKeys {
      let fallback = SourceCommandFallback.resolve(
        key.name, binding: index.binding(key, index: 1, in: finder))
      XCTAssertEqual(
        fallback, SourceCommandFallback.flashOwned[key.name] ?? SourceCommandFallback.none,
        key.description)
    }
  }

  /// Whatever a default command resolves to in a terminal emulator is a
  /// chord the emulator binds, or refused — never one it would type as text.
  func testNoDefaultCommandTypesTextInATerminal() throws {
    let index = CommandBindingIndex(manifests: try Self.officialManifests())
    XCTAssertFalse(TerminalEmulatorFixture.official.isEmpty)
    for emulator in TerminalEmulatorFixture.official {
      let context = PluginSelectorContext(bundleID: emulator)
      for key in URLEventHandler.sourceCommandBindingKeys {
        guard
          case .binding(let binding) = SourceCommandFallback.resolve(
            key.name, binding: index.binding(key, index: 1, in: context))
        else { continue }
        let plan = CommandBindingDispatch.plan(binding) { key, flags in
          Self.typesText(key: key, flags: flags, in: emulator, bindings: index)
        }
        guard case .sendChords(let chords) = plan else { continue }
        for chord in chords {
          XCTAssertFalse(
            Self.typesText(key: chord.key, flags: chord.flags, in: emulator, bindings: index),
            "\(key) in \(emulator)")
        }
      }
    }
  }

  /// Keys map to commands; `key send` stays an explicit user escape hatch
  /// that no default or bundled plugin mapping uses.
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

  /// What the command does in `bundle`, as the parity table writes it.
  private static func effect(
    _ key: CommandBindingKey, index: Int?, in bundle: String, bindings: CommandBindingIndex
  ) -> String {
    let context = PluginSelectorContext(bundleID: bundle)
    switch SourceCommandFallback.resolve(
      key.name, binding: bindings.binding(key, index: index, in: context))
    {
    case .binding(let binding):
      let plan = CommandBindingDispatch.plan(binding) { key, flags in
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
    key: CGKeyCode, flags: CGEventFlags, in bundle: String, bindings: CommandBindingIndex
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

  /// Binding key (`tab select:<n>` for a tab), bundle id, effect before the
  /// migration: a chord, `refused`, `none`, `scroll(<dir>)`, `edge(<edge>)`.
  private static let parity = """
    tab next	org.mozilla.firefox	cmd+shift+]
    tab previous	org.mozilla.firefox	cmd+shift+[
    tab first	org.mozilla.firefox	cmd+1
    tab last	org.mozilla.firefox	cmd+9
    tab new	org.mozilla.firefox	cmd+t
    tab close	org.mozilla.firefox	cmd+w
    tab reopen	org.mozilla.firefox	cmd+shift+t
    tab move_next	org.mozilla.firefox	ctrl+shift+pagedown
    tab move_previous	org.mozilla.firefox	ctrl+shift+pageup
    pane next	org.mozilla.firefox	none
    pane previous	org.mozilla.firefox	none
    pane split_vertical	org.mozilla.firefox	none
    pane split_horizontal	org.mozilla.firefox	none
    pane close	org.mozilla.firefox	none
    app reload	org.mozilla.firefox	cmd+r
    app reload --force	org.mozilla.firefox	cmd+shift+r
    resource archive	org.mozilla.firefox	none
    resource next	org.mozilla.firefox	scroll(down)
    resource previous	org.mozilla.firefox	scroll(up)
    scroll top	org.mozilla.firefox	cmd+up
    scroll bottom	org.mozilla.firefox	cmd+down
    history back	org.mozilla.firefox	cmd+[
    history forward	org.mozilla.firefox	cmd+]
    tab select:1	org.mozilla.firefox	cmd+1
    tab select:2	org.mozilla.firefox	cmd+2
    tab select:9	org.mozilla.firefox	cmd+9
    app undo	org.mozilla.firefox	cmd+z
    app redo	org.mozilla.firefox	cmd+shift+z
    app find	org.mozilla.firefox	cmd+f
    app save	org.mozilla.firefox	cmd+s
    app print	org.mozilla.firefox	cmd+p
    document open	org.mozilla.firefox	cmd+o
    window new	org.mozilla.firefox	cmd+n
    window close	org.mozilla.firefox	cmd+w
    clipboard copy	org.mozilla.firefox	cmd+c
    clipboard paste	org.mozilla.firefox	cmd+v
    tab next	com.apple.Safari	cmd+shift+]
    tab previous	com.apple.Safari	cmd+shift+[
    tab first	com.apple.Safari	cmd+1
    tab last	com.apple.Safari	cmd+9
    tab new	com.apple.Safari	cmd+t
    tab close	com.apple.Safari	cmd+w
    tab reopen	com.apple.Safari	cmd+shift+t
    tab move_next	com.apple.Safari	ctrl+shift+pagedown
    tab move_previous	com.apple.Safari	ctrl+shift+pageup
    pane next	com.apple.Safari	none
    pane previous	com.apple.Safari	none
    pane split_vertical	com.apple.Safari	none
    pane split_horizontal	com.apple.Safari	none
    pane close	com.apple.Safari	none
    app reload	com.apple.Safari	cmd+r
    app reload --force	com.apple.Safari	cmd+option+r
    resource archive	com.apple.Safari	none
    resource next	com.apple.Safari	scroll(down)
    resource previous	com.apple.Safari	scroll(up)
    scroll top	com.apple.Safari	cmd+up
    scroll bottom	com.apple.Safari	cmd+down
    history back	com.apple.Safari	cmd+[
    history forward	com.apple.Safari	cmd+]
    tab select:1	com.apple.Safari	cmd+1
    tab select:2	com.apple.Safari	cmd+2
    tab select:9	com.apple.Safari	cmd+9
    app undo	com.apple.Safari	cmd+z
    app redo	com.apple.Safari	cmd+shift+z
    app find	com.apple.Safari	cmd+f
    app save	com.apple.Safari	cmd+s
    app print	com.apple.Safari	cmd+p
    document open	com.apple.Safari	cmd+o
    window new	com.apple.Safari	cmd+n
    window close	com.apple.Safari	cmd+w
    clipboard copy	com.apple.Safari	cmd+c
    clipboard paste	com.apple.Safari	cmd+v
    tab next	com.google.Chrome	cmd+shift+]
    tab previous	com.google.Chrome	cmd+shift+[
    tab first	com.google.Chrome	cmd+1
    tab last	com.google.Chrome	cmd+9
    tab new	com.google.Chrome	cmd+t
    tab close	com.google.Chrome	cmd+w
    tab reopen	com.google.Chrome	cmd+shift+t
    tab move_next	com.google.Chrome	ctrl+shift+pagedown
    tab move_previous	com.google.Chrome	ctrl+shift+pageup
    pane next	com.google.Chrome	none
    pane previous	com.google.Chrome	none
    pane split_vertical	com.google.Chrome	none
    pane split_horizontal	com.google.Chrome	none
    pane close	com.google.Chrome	none
    app reload	com.google.Chrome	cmd+r
    app reload --force	com.google.Chrome	cmd+shift+r
    resource archive	com.google.Chrome	none
    resource next	com.google.Chrome	scroll(down)
    resource previous	com.google.Chrome	scroll(up)
    scroll top	com.google.Chrome	cmd+up
    scroll bottom	com.google.Chrome	cmd+down
    history back	com.google.Chrome	cmd+[
    history forward	com.google.Chrome	cmd+]
    tab select:1	com.google.Chrome	cmd+1
    tab select:2	com.google.Chrome	cmd+2
    tab select:9	com.google.Chrome	cmd+9
    app undo	com.google.Chrome	cmd+z
    app redo	com.google.Chrome	cmd+shift+z
    app find	com.google.Chrome	cmd+f
    app save	com.google.Chrome	cmd+s
    app print	com.google.Chrome	cmd+p
    document open	com.google.Chrome	cmd+o
    window new	com.google.Chrome	cmd+n
    window close	com.google.Chrome	cmd+w
    clipboard copy	com.google.Chrome	cmd+c
    clipboard paste	com.google.Chrome	cmd+v
    tab next	com.apple.finder	cmd+shift+]
    tab previous	com.apple.finder	cmd+shift+[
    tab first	com.apple.finder	cmd+1
    tab last	com.apple.finder	none
    tab new	com.apple.finder	cmd+t
    tab close	com.apple.finder	cmd+w
    tab reopen	com.apple.finder	none
    tab move_next	com.apple.finder	none
    tab move_previous	com.apple.finder	none
    pane next	com.apple.finder	none
    pane previous	com.apple.finder	none
    pane split_vertical	com.apple.finder	none
    pane split_horizontal	com.apple.finder	none
    pane close	com.apple.finder	none
    app reload	com.apple.finder	none
    app reload --force	com.apple.finder	none
    resource archive	com.apple.finder	none
    resource next	com.apple.finder	scroll(down)
    resource previous	com.apple.finder	scroll(up)
    scroll top	com.apple.finder	edge(top)
    scroll bottom	com.apple.finder	edge(bottom)
    history back	com.apple.finder	cmd+[
    history forward	com.apple.finder	cmd+]
    tab select:1	com.apple.finder	cmd+1
    tab select:2	com.apple.finder	cmd+2
    tab select:9	com.apple.finder	cmd+9
    app undo	com.apple.finder	cmd+z
    app redo	com.apple.finder	cmd+shift+z
    app find	com.apple.finder	cmd+f
    app save	com.apple.finder	cmd+s
    app print	com.apple.finder	cmd+p
    document open	com.apple.finder	cmd+o
    window new	com.apple.finder	cmd+n
    window close	com.apple.finder	cmd+w
    clipboard copy	com.apple.finder	cmd+c
    clipboard paste	com.apple.finder	cmd+v
    tab next	org.alacritty	cmd+shift+]
    tab previous	org.alacritty	cmd+shift+[
    tab first	org.alacritty	cmd+1
    tab last	org.alacritty	none
    tab new	org.alacritty	cmd+t
    tab close	org.alacritty	cmd+w
    tab reopen	org.alacritty	none
    tab move_next	org.alacritty	none
    tab move_previous	org.alacritty	none
    pane next	org.alacritty	none
    pane previous	org.alacritty	none
    pane split_vertical	org.alacritty	none
    pane split_horizontal	org.alacritty	none
    pane close	org.alacritty	none
    app reload	org.alacritty	none
    app reload --force	org.alacritty	none
    resource archive	org.alacritty	none
    resource next	org.alacritty	scroll(down)
    resource previous	org.alacritty	scroll(up)
    scroll top	org.alacritty	edge(top)
    scroll bottom	org.alacritty	edge(bottom)
    history back	org.alacritty	none
    history forward	org.alacritty	none
    tab select:1	org.alacritty	cmd+1
    tab select:2	org.alacritty	cmd+2
    tab select:9	org.alacritty	cmd+9
    app undo	org.alacritty	refused
    app redo	org.alacritty	refused
    app find	org.alacritty	cmd+f
    app save	org.alacritty	refused
    app print	org.alacritty	refused
    document open	org.alacritty	refused
    window new	org.alacritty	cmd+n
    window close	org.alacritty	cmd+w
    clipboard copy	org.alacritty	cmd+c
    clipboard paste	org.alacritty	cmd+v
    tab next	com.mitchellh.ghostty	cmd+shift+]
    tab previous	com.mitchellh.ghostty	cmd+shift+[
    tab first	com.mitchellh.ghostty	cmd+1
    tab last	com.mitchellh.ghostty	none
    tab new	com.mitchellh.ghostty	cmd+t
    tab close	com.mitchellh.ghostty	cmd+w
    tab reopen	com.mitchellh.ghostty	none
    tab move_next	com.mitchellh.ghostty	none
    tab move_previous	com.mitchellh.ghostty	none
    pane next	com.mitchellh.ghostty	cmd+]
    pane previous	com.mitchellh.ghostty	cmd+[
    pane split_vertical	com.mitchellh.ghostty	none
    pane split_horizontal	com.mitchellh.ghostty	none
    pane close	com.mitchellh.ghostty	none
    app reload	com.mitchellh.ghostty	none
    app reload --force	com.mitchellh.ghostty	none
    resource archive	com.mitchellh.ghostty	none
    resource next	com.mitchellh.ghostty	scroll(down)
    resource previous	com.mitchellh.ghostty	scroll(up)
    scroll top	com.mitchellh.ghostty	edge(top)
    scroll bottom	com.mitchellh.ghostty	edge(bottom)
    history back	com.mitchellh.ghostty	none
    history forward	com.mitchellh.ghostty	none
    tab select:1	com.mitchellh.ghostty	cmd+1
    tab select:2	com.mitchellh.ghostty	cmd+2
    tab select:9	com.mitchellh.ghostty	cmd+9
    app undo	com.mitchellh.ghostty	refused
    app redo	com.mitchellh.ghostty	refused
    app find	com.mitchellh.ghostty	cmd+f
    app save	com.mitchellh.ghostty	refused
    app print	com.mitchellh.ghostty	refused
    document open	com.mitchellh.ghostty	refused
    window new	com.mitchellh.ghostty	cmd+n
    window close	com.mitchellh.ghostty	cmd+w
    clipboard copy	com.mitchellh.ghostty	cmd+c
    clipboard paste	com.mitchellh.ghostty	cmd+v
    tab next	com.googlecode.iterm2	cmd+shift+]
    tab previous	com.googlecode.iterm2	cmd+shift+[
    tab first	com.googlecode.iterm2	cmd+1
    tab last	com.googlecode.iterm2	none
    tab new	com.googlecode.iterm2	cmd+t
    tab close	com.googlecode.iterm2	cmd+w
    tab reopen	com.googlecode.iterm2	none
    tab move_next	com.googlecode.iterm2	none
    tab move_previous	com.googlecode.iterm2	none
    pane next	com.googlecode.iterm2	cmd+]
    pane previous	com.googlecode.iterm2	cmd+[
    pane split_vertical	com.googlecode.iterm2	none
    pane split_horizontal	com.googlecode.iterm2	none
    pane close	com.googlecode.iterm2	none
    app reload	com.googlecode.iterm2	none
    app reload --force	com.googlecode.iterm2	none
    resource archive	com.googlecode.iterm2	none
    resource next	com.googlecode.iterm2	scroll(down)
    resource previous	com.googlecode.iterm2	scroll(up)
    scroll top	com.googlecode.iterm2	edge(top)
    scroll bottom	com.googlecode.iterm2	edge(bottom)
    history back	com.googlecode.iterm2	none
    history forward	com.googlecode.iterm2	none
    tab select:1	com.googlecode.iterm2	cmd+1
    tab select:2	com.googlecode.iterm2	cmd+2
    tab select:9	com.googlecode.iterm2	cmd+9
    app undo	com.googlecode.iterm2	refused
    app redo	com.googlecode.iterm2	refused
    app find	com.googlecode.iterm2	cmd+f
    app save	com.googlecode.iterm2	refused
    app print	com.googlecode.iterm2	refused
    document open	com.googlecode.iterm2	refused
    window new	com.googlecode.iterm2	cmd+n
    window close	com.googlecode.iterm2	cmd+w
    clipboard copy	com.googlecode.iterm2	cmd+c
    clipboard paste	com.googlecode.iterm2	cmd+v
    tab next	com.apple.Terminal	cmd+shift+]
    tab previous	com.apple.Terminal	cmd+shift+[
    tab first	com.apple.Terminal	cmd+1
    tab last	com.apple.Terminal	none
    tab new	com.apple.Terminal	cmd+t
    tab close	com.apple.Terminal	cmd+w
    tab reopen	com.apple.Terminal	none
    tab move_next	com.apple.Terminal	none
    tab move_previous	com.apple.Terminal	none
    pane next	com.apple.Terminal	none
    pane previous	com.apple.Terminal	none
    pane split_vertical	com.apple.Terminal	none
    pane split_horizontal	com.apple.Terminal	none
    pane close	com.apple.Terminal	none
    app reload	com.apple.Terminal	none
    app reload --force	com.apple.Terminal	none
    resource archive	com.apple.Terminal	none
    resource next	com.apple.Terminal	scroll(down)
    resource previous	com.apple.Terminal	scroll(up)
    scroll top	com.apple.Terminal	edge(top)
    scroll bottom	com.apple.Terminal	edge(bottom)
    history back	com.apple.Terminal	none
    history forward	com.apple.Terminal	none
    tab select:1	com.apple.Terminal	cmd+1
    tab select:2	com.apple.Terminal	cmd+2
    tab select:9	com.apple.Terminal	cmd+9
    app undo	com.apple.Terminal	refused
    app redo	com.apple.Terminal	refused
    app find	com.apple.Terminal	cmd+f
    app save	com.apple.Terminal	refused
    app print	com.apple.Terminal	refused
    document open	com.apple.Terminal	refused
    window new	com.apple.Terminal	cmd+n
    window close	com.apple.Terminal	cmd+w
    clipboard copy	com.apple.Terminal	cmd+c
    clipboard paste	com.apple.Terminal	cmd+v
    tab next	com.microsoft.VSCode	cmd+shift+]
    tab previous	com.microsoft.VSCode	cmd+shift+[
    tab first	com.microsoft.VSCode	cmd+1
    tab last	com.microsoft.VSCode	none
    tab new	com.microsoft.VSCode	cmd+n
    tab close	com.microsoft.VSCode	cmd+w
    tab reopen	com.microsoft.VSCode	cmd+shift+t
    tab move_next	com.microsoft.VSCode	none
    tab move_previous	com.microsoft.VSCode	none
    pane next	com.microsoft.VSCode	none
    pane previous	com.microsoft.VSCode	none
    pane split_vertical	com.microsoft.VSCode	none
    pane split_horizontal	com.microsoft.VSCode	none
    pane close	com.microsoft.VSCode	none
    app reload	com.microsoft.VSCode	none
    app reload --force	com.microsoft.VSCode	none
    resource archive	com.microsoft.VSCode	none
    resource next	com.microsoft.VSCode	scroll(down)
    resource previous	com.microsoft.VSCode	scroll(up)
    scroll top	com.microsoft.VSCode	edge(top)
    scroll bottom	com.microsoft.VSCode	edge(bottom)
    history back	com.microsoft.VSCode	ctrl+-
    history forward	com.microsoft.VSCode	ctrl+shift+-
    tab select:1	com.microsoft.VSCode	cmd+1
    tab select:2	com.microsoft.VSCode	cmd+2
    tab select:9	com.microsoft.VSCode	cmd+9
    app undo	com.microsoft.VSCode	cmd+z
    app redo	com.microsoft.VSCode	cmd+shift+z
    app find	com.microsoft.VSCode	cmd+f
    app save	com.microsoft.VSCode	cmd+s
    app print	com.microsoft.VSCode	cmd+p
    document open	com.microsoft.VSCode	cmd+o
    window new	com.microsoft.VSCode	cmd+n
    window close	com.microsoft.VSCode	cmd+w
    clipboard copy	com.microsoft.VSCode	cmd+c
    clipboard paste	com.microsoft.VSCode	cmd+v
    tab next	com.todesktop.230313mzl4w4u92	cmd+shift+]
    tab previous	com.todesktop.230313mzl4w4u92	cmd+shift+[
    tab first	com.todesktop.230313mzl4w4u92	cmd+1
    tab last	com.todesktop.230313mzl4w4u92	none
    tab new	com.todesktop.230313mzl4w4u92	cmd+n
    tab close	com.todesktop.230313mzl4w4u92	cmd+w
    tab reopen	com.todesktop.230313mzl4w4u92	cmd+shift+t
    tab move_next	com.todesktop.230313mzl4w4u92	none
    tab move_previous	com.todesktop.230313mzl4w4u92	none
    pane next	com.todesktop.230313mzl4w4u92	none
    pane previous	com.todesktop.230313mzl4w4u92	none
    pane split_vertical	com.todesktop.230313mzl4w4u92	none
    pane split_horizontal	com.todesktop.230313mzl4w4u92	none
    pane close	com.todesktop.230313mzl4w4u92	none
    app reload	com.todesktop.230313mzl4w4u92	none
    app reload --force	com.todesktop.230313mzl4w4u92	none
    resource archive	com.todesktop.230313mzl4w4u92	none
    resource next	com.todesktop.230313mzl4w4u92	scroll(down)
    resource previous	com.todesktop.230313mzl4w4u92	scroll(up)
    scroll top	com.todesktop.230313mzl4w4u92	edge(top)
    scroll bottom	com.todesktop.230313mzl4w4u92	edge(bottom)
    history back	com.todesktop.230313mzl4w4u92	ctrl+-
    history forward	com.todesktop.230313mzl4w4u92	ctrl+shift+-
    tab select:1	com.todesktop.230313mzl4w4u92	cmd+1
    tab select:2	com.todesktop.230313mzl4w4u92	cmd+2
    tab select:9	com.todesktop.230313mzl4w4u92	cmd+9
    app undo	com.todesktop.230313mzl4w4u92	cmd+z
    app redo	com.todesktop.230313mzl4w4u92	cmd+shift+z
    app find	com.todesktop.230313mzl4w4u92	cmd+f
    app save	com.todesktop.230313mzl4w4u92	cmd+s
    app print	com.todesktop.230313mzl4w4u92	cmd+p
    document open	com.todesktop.230313mzl4w4u92	cmd+o
    window new	com.todesktop.230313mzl4w4u92	cmd+n
    window close	com.todesktop.230313mzl4w4u92	cmd+w
    clipboard copy	com.todesktop.230313mzl4w4u92	cmd+c
    clipboard paste	com.todesktop.230313mzl4w4u92	cmd+v
    tab next	dev.zed.Zed	cmd+shift+]
    tab previous	dev.zed.Zed	cmd+shift+[
    tab first	dev.zed.Zed	cmd+1
    tab last	dev.zed.Zed	none
    tab new	dev.zed.Zed	cmd+n
    tab close	dev.zed.Zed	cmd+w
    tab reopen	dev.zed.Zed	cmd+shift+t
    tab move_next	dev.zed.Zed	none
    tab move_previous	dev.zed.Zed	none
    pane next	dev.zed.Zed	none
    pane previous	dev.zed.Zed	none
    pane split_vertical	dev.zed.Zed	none
    pane split_horizontal	dev.zed.Zed	none
    pane close	dev.zed.Zed	none
    app reload	dev.zed.Zed	none
    app reload --force	dev.zed.Zed	none
    resource archive	dev.zed.Zed	none
    resource next	dev.zed.Zed	scroll(down)
    resource previous	dev.zed.Zed	scroll(up)
    scroll top	dev.zed.Zed	edge(top)
    scroll bottom	dev.zed.Zed	edge(bottom)
    history back	dev.zed.Zed	ctrl+-
    history forward	dev.zed.Zed	ctrl+shift+-
    tab select:1	dev.zed.Zed	cmd+1
    tab select:2	dev.zed.Zed	cmd+2
    tab select:9	dev.zed.Zed	cmd+9
    app undo	dev.zed.Zed	cmd+z
    app redo	dev.zed.Zed	cmd+shift+z
    app find	dev.zed.Zed	cmd+f
    app save	dev.zed.Zed	cmd+s
    app print	dev.zed.Zed	cmd+p
    document open	dev.zed.Zed	cmd+o
    window new	dev.zed.Zed	cmd+n
    window close	dev.zed.Zed	cmd+w
    clipboard copy	dev.zed.Zed	cmd+c
    clipboard paste	dev.zed.Zed	cmd+v
    tab next	com.apple.Notes	cmd+shift+]
    tab previous	com.apple.Notes	cmd+shift+[
    tab first	com.apple.Notes	cmd+1
    tab last	com.apple.Notes	none
    tab new	com.apple.Notes	none
    tab close	com.apple.Notes	none
    tab reopen	com.apple.Notes	none
    tab move_next	com.apple.Notes	none
    tab move_previous	com.apple.Notes	none
    pane next	com.apple.Notes	none
    pane previous	com.apple.Notes	none
    pane split_vertical	com.apple.Notes	none
    pane split_horizontal	com.apple.Notes	none
    pane close	com.apple.Notes	none
    app reload	com.apple.Notes	none
    app reload --force	com.apple.Notes	none
    resource archive	com.apple.Notes	none
    resource next	com.apple.Notes	scroll(down)
    resource previous	com.apple.Notes	scroll(up)
    scroll top	com.apple.Notes	edge(top)
    scroll bottom	com.apple.Notes	edge(bottom)
    history back	com.apple.Notes	none
    history forward	com.apple.Notes	none
    tab select:1	com.apple.Notes	cmd+1
    tab select:2	com.apple.Notes	cmd+2
    tab select:9	com.apple.Notes	cmd+9
    app undo	com.apple.Notes	cmd+z
    app redo	com.apple.Notes	cmd+shift+z
    app find	com.apple.Notes	cmd+f
    app save	com.apple.Notes	cmd+s
    app print	com.apple.Notes	cmd+p
    document open	com.apple.Notes	cmd+o
    window new	com.apple.Notes	cmd+n
    window close	com.apple.Notes	cmd+w
    clipboard copy	com.apple.Notes	cmd+c
    clipboard paste	com.apple.Notes	cmd+v
    tab next	com.apple.MobileSMS	ctrl+tab
    tab previous	com.apple.MobileSMS	ctrl+shift+tab
    tab first	com.apple.MobileSMS	cmd+1
    tab last	com.apple.MobileSMS	none
    tab new	com.apple.MobileSMS	cmd+t
    tab close	com.apple.MobileSMS	none
    tab reopen	com.apple.MobileSMS	none
    tab move_next	com.apple.MobileSMS	none
    tab move_previous	com.apple.MobileSMS	none
    pane next	com.apple.MobileSMS	none
    pane previous	com.apple.MobileSMS	none
    pane split_vertical	com.apple.MobileSMS	none
    pane split_horizontal	com.apple.MobileSMS	none
    pane close	com.apple.MobileSMS	none
    app reload	com.apple.MobileSMS	none
    app reload --force	com.apple.MobileSMS	none
    resource archive	com.apple.MobileSMS	none
    resource next	com.apple.MobileSMS	scroll(down)
    resource previous	com.apple.MobileSMS	scroll(up)
    scroll top	com.apple.MobileSMS	edge(top)
    scroll bottom	com.apple.MobileSMS	edge(bottom)
    history back	com.apple.MobileSMS	cmd+[
    history forward	com.apple.MobileSMS	cmd+]
    tab select:1	com.apple.MobileSMS	cmd+1
    tab select:2	com.apple.MobileSMS	cmd+2
    tab select:9	com.apple.MobileSMS	cmd+9
    app undo	com.apple.MobileSMS	cmd+z
    app redo	com.apple.MobileSMS	cmd+shift+z
    app find	com.apple.MobileSMS	cmd+f
    app save	com.apple.MobileSMS	cmd+s
    app print	com.apple.MobileSMS	cmd+p
    document open	com.apple.MobileSMS	cmd+o
    window new	com.apple.MobileSMS	cmd+n
    window close	com.apple.MobileSMS	cmd+w
    clipboard copy	com.apple.MobileSMS	cmd+c
    clipboard paste	com.apple.MobileSMS	cmd+v
    tab next	com.apple.mail	cmd+shift+]
    tab previous	com.apple.mail	cmd+shift+[
    tab first	com.apple.mail	cmd+1
    tab last	com.apple.mail	none
    tab new	com.apple.mail	none
    tab close	com.apple.mail	none
    tab reopen	com.apple.mail	none
    tab move_next	com.apple.mail	none
    tab move_previous	com.apple.mail	none
    pane next	com.apple.mail	none
    pane previous	com.apple.mail	none
    pane split_vertical	com.apple.mail	none
    pane split_horizontal	com.apple.mail	none
    pane close	com.apple.mail	none
    app reload	com.apple.mail	none
    app reload --force	com.apple.mail	none
    resource archive	com.apple.mail	none
    resource next	com.apple.mail	scroll(down)
    resource previous	com.apple.mail	scroll(up)
    scroll top	com.apple.mail	edge(top)
    scroll bottom	com.apple.mail	edge(bottom)
    history back	com.apple.mail	none
    history forward	com.apple.mail	none
    tab select:1	com.apple.mail	cmd+1
    tab select:2	com.apple.mail	cmd+2
    tab select:9	com.apple.mail	cmd+9
    app undo	com.apple.mail	cmd+z
    app redo	com.apple.mail	cmd+shift+z
    app find	com.apple.mail	cmd+f
    app save	com.apple.mail	cmd+s
    app print	com.apple.mail	cmd+p
    document open	com.apple.mail	cmd+o
    window new	com.apple.mail	cmd+n
    window close	com.apple.mail	cmd+w
    clipboard copy	com.apple.mail	cmd+c
    clipboard paste	com.apple.mail	cmd+v
    tab next	com.apple.dt.Xcode	cmd+shift+]
    tab previous	com.apple.dt.Xcode	cmd+shift+[
    tab first	com.apple.dt.Xcode	cmd+1
    tab last	com.apple.dt.Xcode	none
    tab new	com.apple.dt.Xcode	cmd+t
    tab close	com.apple.dt.Xcode	cmd+w
    tab reopen	com.apple.dt.Xcode	none
    tab move_next	com.apple.dt.Xcode	none
    tab move_previous	com.apple.dt.Xcode	none
    pane next	com.apple.dt.Xcode	none
    pane previous	com.apple.dt.Xcode	none
    pane split_vertical	com.apple.dt.Xcode	none
    pane split_horizontal	com.apple.dt.Xcode	none
    pane close	com.apple.dt.Xcode	none
    app reload	com.apple.dt.Xcode	none
    app reload --force	com.apple.dt.Xcode	none
    resource archive	com.apple.dt.Xcode	none
    resource next	com.apple.dt.Xcode	scroll(down)
    resource previous	com.apple.dt.Xcode	scroll(up)
    scroll top	com.apple.dt.Xcode	edge(top)
    scroll bottom	com.apple.dt.Xcode	edge(bottom)
    history back	com.apple.dt.Xcode	ctrl+cmd+left
    history forward	com.apple.dt.Xcode	ctrl+cmd+right
    tab select:1	com.apple.dt.Xcode	cmd+1
    tab select:2	com.apple.dt.Xcode	cmd+2
    tab select:9	com.apple.dt.Xcode	cmd+9
    app undo	com.apple.dt.Xcode	cmd+z
    app redo	com.apple.dt.Xcode	cmd+shift+z
    app find	com.apple.dt.Xcode	cmd+f
    app save	com.apple.dt.Xcode	cmd+s
    app print	com.apple.dt.Xcode	cmd+p
    document open	com.apple.dt.Xcode	cmd+o
    window new	com.apple.dt.Xcode	cmd+n
    window close	com.apple.dt.Xcode	cmd+w
    clipboard copy	com.apple.dt.Xcode	cmd+c
    clipboard paste	com.apple.dt.Xcode	cmd+v
    tab next	com.apple.TextEdit	cmd+shift+]
    tab previous	com.apple.TextEdit	cmd+shift+[
    tab first	com.apple.TextEdit	cmd+1
    tab last	com.apple.TextEdit	none
    tab new	com.apple.TextEdit	none
    tab close	com.apple.TextEdit	none
    tab reopen	com.apple.TextEdit	none
    tab move_next	com.apple.TextEdit	none
    tab move_previous	com.apple.TextEdit	none
    pane next	com.apple.TextEdit	none
    pane previous	com.apple.TextEdit	none
    pane split_vertical	com.apple.TextEdit	none
    pane split_horizontal	com.apple.TextEdit	none
    pane close	com.apple.TextEdit	none
    app reload	com.apple.TextEdit	none
    app reload --force	com.apple.TextEdit	none
    resource archive	com.apple.TextEdit	none
    resource next	com.apple.TextEdit	scroll(down)
    resource previous	com.apple.TextEdit	scroll(up)
    scroll top	com.apple.TextEdit	edge(top)
    scroll bottom	com.apple.TextEdit	edge(bottom)
    history back	com.apple.TextEdit	none
    history forward	com.apple.TextEdit	none
    tab select:1	com.apple.TextEdit	cmd+1
    tab select:2	com.apple.TextEdit	cmd+2
    tab select:9	com.apple.TextEdit	cmd+9
    app undo	com.apple.TextEdit	cmd+z
    app redo	com.apple.TextEdit	cmd+shift+z
    app find	com.apple.TextEdit	cmd+f
    app save	com.apple.TextEdit	cmd+s
    app print	com.apple.TextEdit	cmd+p
    document open	com.apple.TextEdit	cmd+o
    window new	com.apple.TextEdit	cmd+n
    window close	com.apple.TextEdit	cmd+w
    clipboard copy	com.apple.TextEdit	cmd+c
    clipboard paste	com.apple.TextEdit	cmd+v
    tab next	com.example.unknown	cmd+shift+]
    tab previous	com.example.unknown	cmd+shift+[
    tab first	com.example.unknown	cmd+1
    tab last	com.example.unknown	none
    tab new	com.example.unknown	cmd+t
    tab close	com.example.unknown	cmd+w
    tab reopen	com.example.unknown	none
    tab move_next	com.example.unknown	none
    tab move_previous	com.example.unknown	none
    pane next	com.example.unknown	none
    pane previous	com.example.unknown	none
    pane split_vertical	com.example.unknown	none
    pane split_horizontal	com.example.unknown	none
    pane close	com.example.unknown	none
    app reload	com.example.unknown	none
    app reload --force	com.example.unknown	none
    resource archive	com.example.unknown	none
    resource next	com.example.unknown	scroll(down)
    resource previous	com.example.unknown	scroll(up)
    scroll top	com.example.unknown	edge(top)
    scroll bottom	com.example.unknown	edge(bottom)
    history back	com.example.unknown	cmd+[
    history forward	com.example.unknown	cmd+]
    tab select:1	com.example.unknown	cmd+1
    tab select:2	com.example.unknown	cmd+2
    tab select:9	com.example.unknown	cmd+9
    app undo	com.example.unknown	cmd+z
    app redo	com.example.unknown	cmd+shift+z
    app find	com.example.unknown	cmd+f
    app save	com.example.unknown	cmd+s
    app print	com.example.unknown	cmd+p
    document open	com.example.unknown	cmd+o
    window new	com.example.unknown	cmd+n
    window close	com.example.unknown	cmd+w
    clipboard copy	com.example.unknown	cmd+c
    clipboard paste	com.example.unknown	cmd+v
    """
}
