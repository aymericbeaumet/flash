import FlashCore
import Foundation

struct PluginReference: Equatable {
  enum Kind: Equatable {
    /// GitHub-hosted plugin pinned to a full 40-character commit SHA. The pin
    /// is mandatory: third-party plugin code runs as the user with full
    /// host privileges, so a moving `main` would let a compromised plugin
    /// author (or anyone briefly controlling the repo) silently land new
    /// install/start scripts on every config reload.
    case github(owner: String, repository: String, commit: String)
    case file(path: String)
  }

  var raw: String
  var kind: Kind

  static func parse(_ raw: String, sourceURL: URL? = nil) -> PluginReference? {
    let trimmed = raw.trimmed
    if trimmed.hasPrefix("github:") {
      return parseGithub(trimmed)
    }
    if trimmed.hasPrefix("file:") {
      let rawPath = String(trimmed.dropFirst("file:".count))
        .trimmed
      guard !rawPath.isEmpty else { return nil }
      let expanded = (rawPath as NSString).expandingTildeInPath
      let resolved: String
      if expanded.hasPrefix("/") {
        resolved = expanded
      } else if let sourceURL {
        resolved =
          sourceURL.deletingLastPathComponent()
          .appendingPathComponent(expanded)
          .standardizedFileURL
          .path
      } else {
        resolved = expanded
      }
      return PluginReference(raw: trimmed, kind: .file(path: resolved))
    }
    return nil
  }

  /// Parses `github:owner/repo@<40-char-sha>`. Anything else is rejected with
  /// nil so the loader surfaces a clear diagnostic instead of silently pulling
  /// a moving branch.
  private static func parseGithub(_ trimmed: String) -> PluginReference? {
    let slug = String(trimmed.dropFirst("github:".count))
    let atSplit = slug.split(separator: "@", maxSplits: 1).map(String.init)
    guard atSplit.count == 2 else { return nil }
    let path = atSplit[0]
    let commit = atSplit[1].lowercased()
    let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
      isFullCommitSHA(commit)
    else { return nil }
    return PluginReference(
      raw: trimmed,
      kind: .github(owner: parts[0], repository: parts[1], commit: commit))
  }

  /// Full 40-character lowercase hex commit SHA. Short SHAs are rejected: they
  /// have weaker collision resistance and don't pin against a future crafted
  /// commit landing in the upstream repository's object database.
  private static func isFullCommitSHA(_ value: String) -> Bool {
    guard value.count == 40 else { return false }
    return value.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
  }
}

struct ConfigLocation: Equatable {
  let line: Int
  let column: Int
}

struct ConfigDiagnostic: Equatable {
  let message: String
  let location: ConfigLocation?

  var logMessage: String {
    guard let location else { return message }
    return "line \(location.line), col \(location.column): \(message)"
  }

  var alertLine: String { logMessage }
}

/// A single value inside a `[plugin.<id>]` settings table. Carries enough
/// type information to round-trip into JSON for the plugin's
/// `FLASH_PLUGIN_CONFIG`. Equatable so a config reload can detect when a
/// plugin's settings actually changed and restart only then.
enum PluginConfigValue: Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case stringArray([String])

  var jsonValue: Any {
    switch self {
    case .string(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .bool(let value): return value
    case .stringArray(let value): return value
    }
  }
}

struct Config {
  struct Hints {
    var keys: String = Alphabet.defaultKeys
    var minLength: Int = 1
    var magicModifiers: [String] = ["cmd", "ctrl", "alt", "shift"]
    /// Number of selection steps for the `mouse_grid` verb. Larger values
    /// give finer precision but require more keystrokes per click.
    var mouseGridSteps: Int = 3
    /// Opacity (0.0..1.0) applied to every mouse-grid chip so the user
    /// can still see what's underneath the precision overlay. 1.0 is
    /// fully opaque, 0.0 invisible. Default 0.5 — the underlying window
    /// stays clearly visible through the precision grid.
    var mouseGridOpacity: Double = 0.5
  }
  struct Overlay {
    var fontSize: Double = 12
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Set this equal to
    /// `hintBGBottom` for a flat fill.
    var hintBGTop: String = "#FFF785"
    /// Bottom stop of the chip's vertical gradient.
    var hintBGBottom: String = "#FFC542"
    /// 1px border around the chip.
    var hintBorder: String = "#E3BE23"
    /// Foreground / gradient / border for hints whose target carries
    /// the `important` flag (tmux panes, browser tabs, …). Defaults
    /// to a red-ish Nord-aurora-red gradient so important chips
    /// read as a structural accent against the regular yellow `f`
    /// chips. Set any field equal to its `hint*` counterpart to opt
    /// out of the distinction for that surface.
    var importantHintFG: String = "#ECEFF4"
    var importantHintBGTop: String = "#BF616A"
    var importantHintBGBottom: String = "#5C3940"
    var importantHintBorder: String = "#BF616A"
  }
  /// Tunables for the `:flashlight` command-line surface.
  struct Flashlight {
    /// Number of command-bar suggestions shown for `:flashlight`,
    /// `:emojis`, source filters, bangs, and command completions.
    var suggestionCount: Int = 10
    /// Word-substitution aliases. The key is the exact whitespace-
    /// delimited token the user types (any leading sigil — `!`, `@`,
    /// or none — is part of the key, not implicit). The value is
    /// the literal expansion. When the user types `<key>` followed
    /// by whitespace the buffer is rewritten in place so downstream
    /// parsing (bang detection, source filters, fuzzy scoring) sees
    /// the canonical form. Empty by default — every pair is opt-in
    /// via `[flashlight.aliases]` in flash.toml.
    ///
    /// Example:
    /// ```toml
    /// [flashlight.aliases]
    /// "!g"  = "!google"
    /// "!gh" = "!github"
    /// "@ft" = "@firefox.tabs"
    /// ```
    var aliases: [String: String] = [:]
    /// Source precedence override weights applied as the tiebreaker once
    /// match score ties. Keys are source labels (or parent prefixes —
    /// `"firefox"` covers `firefox.tabs`, `firefox.bookmarks`, …). Higher
    /// weight wins. Entries not listed use the source descriptor kind declared
    /// by the native source or plugin manifest: tmux tabs > browser tabs >
    /// apps > default.
    ///
    /// Example:
    /// ```toml
    /// [flashlight.precedence]
    /// tmux           = 200
    /// "firefox.tabs" = 120
    /// ```
    var precedence: [String: Int] = [:]
    /// Bonus added to any candidate whose `pid != nil` so running
    /// processes outrank installed-but-not-running rows under the
    /// same source. With the `apps` source kind this gives active apps an
    /// effective rank of 50 vs. inactive 40.
    var precedenceAliveBonus: Int = 10
  }
  struct Debug {
    /// When true, every detected target is outlined alongside its hint chip.
    /// Useful for diagnosing missing or misplaced hints — you can see exactly
    /// which AX rect Flash decided to use.
    var showHintsBounds: Bool = false
    /// Fill for the debug outline rectangle. Default transparent.
    var hintsBoundsBG: String = "#00000000"
    /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
    /// it's the foreground colour of the bounds shape.
    var hintsBoundsFG: String = "#FF3B9A"
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `trace` while investigating a
    /// stuck-mode/input issue, `debug` for broader diagnostics, or
    /// `warn` / `error` / `fatal` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
    /// When true, Flash binds a loopback-only HTTP server that exposes
    /// live logs + state inspection. Off by default — turn on with
    /// `debug.http_inspector_enabled = true`.
    var httpInspectorEnabled: Bool = false
    /// Loopback hostname the inspector binds on. Restricted to
    /// `localhost` / `127.0.0.1` / `::1` (validated at start).
    var httpInspectorHost: String = "localhost"
    /// TCP port the inspector listens on.
    var httpInspectorPort: Int = 4242
  }
  struct Open {
    var ignoredApps: [String] = []
  }
  struct Plugins {
    /// Third-party plugins explicitly requested by the user. Official
    /// bundled plugins are always enabled in v1 and are discovered from
    /// the app bundle, not this list.
    var thirdParty: [PluginReference] = []
    /// When true (the default), each plugin's directory tree is watched
    /// and any file change triggers a plugin reload. Set to false to
    /// disable hot-reload — useful if a plugin keeps a noisy log
    /// somewhere in its tree that would otherwise restart-loop it.
    var watchingEnabled: Bool = true
    /// Per-plugin user settings from `[plugin.<id>]` tables. Delivered to
    /// each plugin as a JSON object via `FLASH_PLUGIN_CONFIG`. Keyed by
    /// plugin id, then by setting name.
    var settings: [String: [String: PluginConfigValue]] = [:]
  }
  struct StatusBar {
    /// Whether the persistent top status bar is shown. This is the *sole*
    /// condition for the bar's visibility — it is deliberately independent
    /// of advanced mode (the `enter_normal_mode` binding). Off by default;
    /// set `[statusbar] enabled = true` to opt in.
    var enabled: Bool = false
    /// Single-string status-bar template using tmux-style format markers:
    ///   #[align=left|centre|right]  — switches which alignment region
    ///                                 subsequent text/variables accumulate
    ///                                 into (default: `left`).
    ///   #[fg=…,bold=true]          — inline text styling (passed through
    ///                                 to the renderer).
    ///   #{token}                    — template variable (mode, date,
    ///                                 tmux-compatible vars,
    ///                                 plugin:<count>,
    ///                                 plugin:<plugin>.<segment>,
    ///                                 script:<path>, command:<shell>).
    static let defaultTemplateString = "#[align=left]#{mode}#[align=right]#{date}"
    var template: FlashStatusBarTemplate = Self.defaultTemplate
    static let defaultTemplate = FlashStatusBarTemplate(
      template: Self.defaultTemplateString,
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode",
          token: "mode",
          source: .sdk(.modeLabel)),
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.date",
          token: "date",
          source: .sdk(.date)),
      ])
  }
  struct Mode {
    struct Labels: Equatable {
      var normal: String = "NORMAL"
      var insert: String = "INSERT"
      var command: String = "COMMAND"

      var longestCount: Int {
        max(normal.count, insert.count, command.count)
      }
    }

    var all: [ModeMapping] = []
    var normal: [ModeMapping] = Self.defaultNormalMappings
    var insert: [ModeMapping] = []
    var normalLeader: String? = Self.defaultNormalLeader
    var labels = Labels()
    /// How long the interpreter waits for the next key in a pending
    /// sequence before resolving the longest matching prefix.
    /// Vim's `timeoutlen`. Lower → faster commits, more two-key
    /// collisions; higher → slower commits, fewer surprises.
    var sequenceTimeoutMs: Int = Self.defaultSequenceTimeoutMs
    /// Matches Neovim's `timeoutlen` default so multi-key sequences feel the
    /// same as in the editor users already have muscle memory for.
    static let defaultSequenceTimeoutMs = 1000

    /// Single-atom key form, parsed via `NormalModeInterpreter.parseKeySequence`.
    /// Use `\` bare or `<backslash>` — both resolve to the same key.
    static let defaultNormalLeader = "\\"

    static let defaultNormalMappings: [ModeMapping] = makeDefaultNormalMappings()

    private static func makeDefaultNormalMappings() -> [ModeMapping] {
      // Bare punctuation is allowed by the parser; defaults stay
      // concise. Use `<name>` only for keys that can't be typed bare
      // (`<leader>`, `<space>`) or for emphasis on a non-obvious key.
      var raw: [(String, MappingCommand)] = [
        ("h", .flashCommand(.scroll(.left))),
        ("j", .flashCommand(.resourceNext)),
        ("k", .flashCommand(.resourcePrevious)),
        ("l", .flashCommand(.scroll(.right))),
        ("ctrl+e", .flashCommand(.scroll(.down))),
        ("ctrl+y", .flashCommand(.scroll(.up))),
        ("ctrl+d", .flashCommand(.scroll(.halfPageDown))),
        ("ctrl+u", .flashCommand(.scroll(.halfPageUp))),
        ("gg", .flashCommand(.scroll(.top))),
        ("G", .flashCommand(.scroll(.bottom))),
        // Bracket-pair navigation borrows tpope/vim-unimpaired's `[X` =
        // previous, `]X` = next convention so muscle memory transfers
        // straight from Vim. Multi-letter aliases live alongside the
        // primary binding so users coming from `vim-unimpaired` find
        // their letters AND desktop users find an intuitive abbreviation.
        ("[h", .flashCommand(.historyBack)),
        ("]h", .flashCommand(.historyForward)),
        ("[t", .flashCommand(.tabPrev)),
        ("]t", .flashCommand(.tabNext)),
        // `[b`/`]b` — Vim "buffer" prev/next. In a desktop context the
        // closest analogue is a browser/terminal tab, so this aliases
        // `[t`/`]t` directly.
        ("[b", .flashCommand(.tabPrev)),
        ("]b", .flashCommand(.tabNext)),
        // `[B`/`]B` — Vim first/last buffer. Aliases `g^`/`g$` (tab
        // first/last).
        ("[B", .flashCommand(.tabFirst)),
        ("]B", .flashCommand(.tabLast)),
        // Move (reorder) the current tab. `m` for "move" stays as the
        // primary form because it's the desktop-intuitive abbreviation;
        // `[e`/`]e` (Vim "exchange") is the unimpaired-style alias.
        ("[m", .flashCommand(.tabMovePrev)),
        ("]m", .flashCommand(.tabMoveNext)),
        ("[e", .flashCommand(.tabMovePrev)),
        ("]e", .flashCommand(.tabMoveNext)),
        ("[a", .flashCommand(.appPrev)),
        ("]a", .flashCommand(.appNext)),
        // `[w`/`]w` — Vim's `:wprev`/`:wnext` window-navigation analogue
        // mapped onto Flash's app MRU (a single app commonly fronts
        // multiple windows, but those are accessed with the OS native
        // `Cmd+\`` chord which Flash leaves alone — bouncing across
        // apps is the actually-useful desktop motion).
        ("[w", .flashCommand(.appPrev)),
        ("]w", .flashCommand(.appNext)),
        // Reopen the most recently closed tab. ⌘⇧T is the cross-browser
        // standard (Safari/Chrome/Firefox); the host keystroke
        // fallback delivers it for any non-terminal app, and terminals
        // (no close-tab history) return `.unhandled`.
        ("T", .flashCommand(.tabReopen)),
        // Shadow the system app switcher so the user stays inside
        // Flash's normal-mode loop. Carbon registration is scope-bound:
        // entering insert mode unregisters the binding and the Dock
        // switcher works as usual.
        ("cmd+tab", .flashCommand(.appNext)),
        ("cmd+shift+tab", .flashCommand(.appPrev)),
        // Native macOS / browser navigation chords, shadowed in normal
        // mode so the keys muscle-memory already knows keep working
        // without leaving the normal-mode loop. Like `cmd+tab` above
        // these are scope-bound Carbon registrations: insert mode releases
        // them so the focused app sees the native chord again. Each maps
        // to the same Flash command as its vim-style sibling, so the
        // behaviour is identical whichever binding the user reaches for.
        // ⌘1–⌘9 → select tab N (mirror of `g1`–`g9`).
        ("cmd+1", .flashCommand(.tabSelect(index: 1))),
        ("cmd+2", .flashCommand(.tabSelect(index: 2))),
        ("cmd+3", .flashCommand(.tabSelect(index: 3))),
        ("cmd+4", .flashCommand(.tabSelect(index: 4))),
        ("cmd+5", .flashCommand(.tabSelect(index: 5))),
        ("cmd+6", .flashCommand(.tabSelect(index: 6))),
        ("cmd+7", .flashCommand(.tabSelect(index: 7))),
        ("cmd+8", .flashCommand(.tabSelect(index: 8))),
        ("cmd+9", .flashCommand(.tabSelect(index: 9))),
        // ⌘R / ⌘⇧R → reload / hard reload (mirror of `r` / `R`).
        ("cmd+r", .flashCommand(.reload(force: false))),
        ("cmd+shift+r", .flashCommand(.reload(force: true))),
        // ⌘[ / ⌘] → history back / forward (mirror of `[h` / `]h`).
        ("cmd+<lbracket>", .flashCommand(.historyBack)),
        ("cmd+<rbracket>", .flashCommand(.historyForward)),
        // ⌘⇧[ / ⌘⇧] → previous / next tab (mirror of `[t` / `]t`, `gT` / `gt`).
        ("cmd+shift+<lbracket>", .flashCommand(.tabPrev)),
        ("cmd+shift+<rbracket>", .flashCommand(.tabNext)),
        // ⌘T / ⌘⇧T → new tab / reopen closed tab (mirror of `t` / `T`).
        ("cmd+t", .flashCommand(.tabNew)),
        ("cmd+shift+t", .flashCommand(.tabReopen)),
        // ⌘W → close tab, ⌘N → new window (mirror of `x` / `n`).
        ("cmd+w", .flashCommand(.tabClose)),
        ("cmd+n", .flashCommand(.pluginVerb(name: "window_new", args: [:]))),
        // ⌘F → find (mirror of `/`).
        ("cmd+f", .flashCommand(.find)),
        // ⌃Tab / ⌃⇧Tab → next / previous tab — the browser-native
        // alternative to ⌘⇧] / ⌘⇧[.
        ("ctrl+tab", .flashCommand(.tabNext)),
        ("ctrl+shift+tab", .flashCommand(.tabPrev)),
        // First / last tab. Vim-style `g^` / `g$` borrowed from
        // line-extreme motions: `^` is the first non-blank, `$` is the
        // end of line. Browsers translate to ⌘1 / ⌘9 (the cross-vendor
        // convention for first / last tab); plugin sources receive the
        // `tab_first` / `tab_last` source action.
        ("g^", .flashCommand(.tabFirst)),
        ("g$", .flashCommand(.tabLast)),
        ("g1", .flashCommand(.tabSelect(index: 1))),
        ("g2", .flashCommand(.tabSelect(index: 2))),
        ("g3", .flashCommand(.tabSelect(index: 3))),
        ("g4", .flashCommand(.tabSelect(index: 4))),
        ("g5", .flashCommand(.tabSelect(index: 5))),
        ("g6", .flashCommand(.tabSelect(index: 6))),
        ("g7", .flashCommand(.tabSelect(index: 7))),
        ("g8", .flashCommand(.tabSelect(index: 8))),
        ("g9", .flashCommand(.tabSelect(index: 9))),
        ("ctrl+o", .flashCommand(.appPrev)),
        ("ctrl+i", .flashCommand(.appNext)),
        ("gt", .flashCommand(.tabNext)),
        ("gT", .flashCommand(.tabPrev)),
        ("i", .flashCommand(.insertMode)),
        ("I", .flashCommand(.lockedInsertMode)),
        ("f", .flashCommand(.mouseTarget(.click(.leftClick)))),
        // `s` for "secondary click" (right-click). `r` was the old
        // prefix but it collided with the `r`→`R` reload pair: typing
        // `r` waited the full sequence-timeout before resolving as
        // reload, because right-click hint sequences also began with `r`.
        // `s` has no such pair so the keystroke fires instantly.
        ("sf", .flashCommand(.mouseTarget(.click(.rightClick)))),
        ("df", .flashCommand(.mouseTarget(.click(.doubleClick)))),
        ("mf", .flashCommand(.mouseTarget(.move))),
        ("F", .flashCommand(.mouseGrid(.click(.leftClick)))),
        ("sF", .flashCommand(.mouseGrid(.click(.rightClick)))),
        ("dF", .flashCommand(.mouseGrid(.click(.doubleClick)))),
        ("mF", .flashCommand(.mouseGrid(.move))),
        ("u", .flashCommand(.undo)),
        ("ctrl+r", .flashCommand(.redo)),
        ("e", .flashCommand(.archive)),
        ("x", .flashCommand(.close)),
        ("n", .flashCommand(.pluginVerb(name: "window_new", args: [:]))),
        ("t", .flashCommand(.tabNew)),
        ("/", .flashCommand(.find)),
        ("<leader><space>", .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false))),
        ("r", .flashCommand(.reload(force: false))),
        ("R", .flashCommand(.reload(force: true))),
        ("?", .flashCommand(.showUsage(topic: nil))),
        (":", .flashCommand(.commandMode)),
      ]
      // Vim-style marks: `m<letter>` sets, `` `<letter> `` jumps.
      // Generated rather than hand-listed so the 52 mappings (26+26)
      // stay in sync if more letter ranges are added later.
      for letter in "abcdefghijklmnopqrstuvwxyz" {
        let l = String(letter)
        raw.append(
          (
            "m\(l)",
            .flashCommand(.pluginVerb(name: "set_mark", args: ["letter": l]))
          ))
        raw.append(
          (
            "`\(l)",
            .flashCommand(.pluginVerb(name: "jump_to_mark", args: ["letter": l]))
          ))
      }
      return raw.map { (key, action) in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("default mapping key \"\(key)\" failed canonicalization")
        }
        return ModeMapping(key: canonical, action: action)
      }
    }

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return all + normal
      case .insert:
        return all + insert
      }
    }

    /// O(1)-lookup view used on every keystroke. Refreshed by
    /// `prepareDerivedValues()` after every config load / reload.
    private(set) var compiledNormal = CompiledMappings()
    private(set) var compiledInsert = CompiledMappings()

    func compiledMappings(for mode: FlashMode) -> CompiledMappings {
      switch mode {
      case .normal: return compiledNormal
      case .insert: return compiledInsert
      }
    }

    mutating func recompileMappings() {
      compiledNormal = CompiledMappings(mappings(for: .normal))
      compiledInsert = CompiledMappings(mappings(for: .insert))
    }

    mutating func refreshLeaderDerivedDefaults() {
      let leaderRaw = normalLeader ?? Self.defaultNormalLeader
      guard let leaderInternal = NormalModeInterpreter.translateLeader(leaderRaw) else { return }
      for index in normal.indices where normal[index].key.contains("<leader>") {
        let mapping = normal[index]
        let resolved = mapping.key.replacingOccurrences(of: "<leader>", with: leaderInternal)
        normal[index] = ModeMapping(key: resolved, action: mapping.action)
      }
    }

    var containsNormalModeMapping: Bool {
      (all + normal + insert).contains { mapping in
        mapping.action.command == .normalMode
      }
    }

    var containsAdvancedModeMapping: Bool {
      all.contains { mapping in
        mapping.action.command == .normalMode
      }
    }
  }

  var hints = Hints()
  var overlay = Overlay()
  var open = Open()
  var plugins = Plugins()
  var statusBar = StatusBar()
  var mode = Mode()
  var debug = Debug()
  var flashlight = Flashlight()
  var diagnostics: [ConfigDiagnostic] = []
  /// Plain-string view over `diagnostics`. Existed as a parallel
  /// mutable field; collapsed to a computed projection so the two
  /// can't drift.
  var warnings: [String] { diagnostics.map(\.message) }
  var valueLocations: [String: ConfigLocation] = [:]
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env/CLI
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)

  static let `default`: Config = {
    var config = Config()
    config.prepareDerivedValues()
    return config
  }()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func recordLocation(path: String, location: ConfigLocation?) {
    valueLocations[path] = location
  }

  mutating func clearLocation(path: String) {
    valueLocations.removeValue(forKey: path)
  }

  mutating func addDiagnostic(_ message: String, location: ConfigLocation? = nil) {
    diagnostics.append(ConfigDiagnostic(message: message, location: location))
  }

  mutating func removeDiagnostics(where predicate: (String) -> Bool) {
    diagnostics.removeAll { predicate($0.message) }
  }

  mutating func prepareDerivedValues() {
    mode.refreshLeaderDerivedDefaults()
    resolvedAlphabet = Alphabet.resolve(hints.keys)
    removeAmbiguousShiftMagicModifier()
    mode.recompileMappings()
  }

  private mutating func removeAmbiguousShiftMagicModifier() {
    guard resolvedAlphabet.chars.contains(where: { !$0.isLetter }) else {
      removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
      return
    }
    let original = hints.magicModifiers
    hints.magicModifiers.removeAll { $0.lowercased() == "shift" }
    guard original.count != hints.magicModifiers.count else { return }
    removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
    addDiagnostic(
      "hints.magic_modifiers includes \"shift\", but resolved hints.keys "
        + "contains non-letter characters (\(String(resolvedAlphabet.chars))); "
        + "removed \"shift\" because shifted-character input is ambiguous",
      location: valueLocations["hints.keys"] ?? valueLocations["hints.magic_modifiers"]
    )
  }

  /// JSON object string of the `[plugin.<id>]` settings for `pluginID`,
  /// suitable for `FLASH_PLUGIN_CONFIG`. Returns `{}` when the plugin has
  /// no settings.
  func pluginConfigJSON(for pluginID: String) -> String {
    let table = plugins.settings[pluginID]?.mapValues(\.jsonValue) ?? [:]
    guard
      let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  var resolvedConfigJSON: String {
    let modeJSON: [String: Any] = [
      "all": mode.all.map(Self.mappingJSONValue),
      "insert": mode.insert.map(Self.mappingJSONValue),
      "labels": [
        "command": mode.labels.command,
        "insert": mode.labels.insert,
        "normal": mode.labels.normal,
      ],
      "normal": mode.normal.map(Self.mappingJSONValue),
      "normal_leader": mode.normalLeader ?? NSNull(),
    ]
    return compactJSON([
      "debug": [
        "hints_bounds_bg": debug.hintsBoundsBG,
        "hints_bounds_fg": debug.hintsBoundsFG,
        "http_inspector_enabled": debug.httpInspectorEnabled,
        "http_inspector_host": debug.httpInspectorHost,
        "http_inspector_port": debug.httpInspectorPort,
        "log_level": debug.logLevel.name,
        "show_hints_bounds": debug.showHintsBounds,
      ],
      "hints": [
        "keys": hints.keys,
        "magic_modifiers": hints.magicModifiers,
        "min_length": hints.minLength,
        "mouse_grid_opacity": hints.mouseGridOpacity,
        "mouse_grid_steps": hints.mouseGridSteps,
      ],
      "flashlight": [
        "aliases": flashlight.aliases,
        "precedence": flashlight.precedence,
        "precedence_alive_bonus": flashlight.precedenceAliveBonus,
        "suggestion_count": flashlight.suggestionCount,
      ],
      "mode": modeJSON,
      "open": [
        "ignored_apps": open.ignoredApps
      ],
      "overlay": [
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
      ],
      "plugins": [
        "third_party": plugins.thirdParty.map(\.raw),
        "watching_enabled": plugins.watchingEnabled,
        "settings": plugins.settings.mapValues { table in
          table.mapValues(\.jsonValue)
        },
      ],
      "statusbar": [
        "enabled": statusBar.enabled,
        "template": statusBar.template.template,
      ],
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "action": mapping.action.configValue,
      "key": mapping.key,
    ]
  }

  var resolvedHintsKeysJSON: String {
    let scores = Dictionary(
      uniqueKeysWithValues: resolvedAlphabet.keyScores.map { (String($0.key), $0.value) }
    )
    return compactJSON([
      "chars": String(resolvedAlphabet.chars),
      "chars_array": resolvedAlphabet.chars.map(String.init),
      "default": Alphabet.defaultKeys,
      "key_scores": scores,
      "layout": resolvedAlphabet.layoutName ?? NSNull(),
      "left_hand": String(resolvedAlphabet.leftHand.sorted()),
      "raw": hints.keys,
      "warning": resolvedAlphabet.warning ?? NSNull(),
    ])
  }

  var loadingDiagnostics: [ConfigDiagnostic] {
    var diagnostics = self.diagnostics
    if let warning = resolvedAlphabet.warning {
      diagnostics.append(
        ConfigDiagnostic(
          message: warning,
          location: valueLocations["hints.keys"]))
    }
    return diagnostics
  }

  var loadingErrorAlertMessage: String? {
    let diagnostics = loadingDiagnostics
    guard !diagnostics.isEmpty else { return nil }
    let visibleDiagnostics = diagnostics.prefix(3).map { "- \($0.alertLine)" }
    var lines = ["[Flash]", diagnostics.count == 1 ? "Config error" : "Config errors"]
    lines.append(contentsOf: visibleDiagnostics)
    let remaining = diagnostics.count - visibleDiagnostics.count
    if remaining > 0 {
      lines.append("- \(remaining) more config issue\(remaining == 1 ? "" : "s")")
    }
    return lines.joined(separator: "\n")
  }

  private func compactJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }
}

extension URLCommand {
  /// Human-readable form of an in-process verb: `flash <verb> [--k=v ...]`.
  /// Matches the syntax users type into the `flash` CLI and write into
  /// mapping arrays in `flash.toml`. Used for help text, log lines, and
  /// the inspector — never re-parsed.
  var diagnosticDescription: String {
    func verb(_ name: String, _ args: [String] = []) -> String {
      args.isEmpty ? "flash \(name)" : "flash \(name) " + args.joined(separator: " ")
    }
    /// Bool-flag arg: `--name` (when on). Off bool flags don't render.
    func flag(_ name: String) -> String { "--\(name)" }
    /// Value arg: `--name=value`. The internal key is snake_case; surface
    /// the hyphenated form so the rendered string can be pasted back into
    /// a shell or config without translation.
    func kv(_ name: String, _ value: Any) -> String {
      let key = name.replacingOccurrences(of: "_", with: "-")
      return "--\(key)=\(value)"
    }
    switch self {
    case .mouseTarget(let command):
      return verb("mouse_target", command.argTokens)
    case .mouseGrid(let command):
      return verb("mouse_grid", command.argTokens)
    case .normalMode: return verb("enter_normal_mode")
    case .insertMode: return verb("enter_insert_mode")
    case .lockedInsertMode: return verb("enter_locked_insert_mode")
    case .commandMode: return verb("enter_command_mode")
    case .scroll(let kind):
      switch kind {
      case .left: return verb("scroll_left")
      case .right: return verb("scroll_right")
      case .up: return verb("scroll_up")
      case .down: return verb("scroll_down")
      case .halfPageUp: return verb("scroll_half_page_up")
      case .halfPageDown: return verb("scroll_half_page_down")
      case .top: return verb("scroll_top")
      case .bottom: return verb("scroll_bottom")
      }
    case .reload(let force):
      return force ? verb("app_reload", [flag("force")]) : verb("app_reload")
    case .undo: return verb("app_undo")
    case .redo: return verb("app_redo")
    case .archive: return verb("resource_archive")
    case .resourceNext: return verb("resource_next")
    case .resourcePrevious: return verb("resource_previous")
    case .close: return verb("window_close")
    case .tabClose: return verb("tab_close")
    case .find: return verb("app_find")
    case .candidateFinder(let all):
      return all ? verb("app_open_finder", [flag("all")]) : verb("app_open_finder")
    case .enterCommand(let input, let restoreMode):
      var args = [kv("input", input)]
      if restoreMode { args.append(flag("restore-mode")) }
      return verb("enter_command_mode", args)
    case .copyURL: return verb("url_copy")
    case .tabNext: return verb("tab_next")
    case .tabPrev: return verb("tab_previous")
    case .tabFirst: return verb("tab_first")
    case .tabLast: return verb("tab_last")
    case .tabSelect(let index):
      if let index { return verb("tab_select", [kv("index", index)]) }
      return verb("tab_select")
    case .tabMovePrev: return verb("tab_move_previous")
    case .tabMoveNext: return verb("tab_move_next")
    case .tabReopen: return verb("tab_reopen")
    case .historyBack: return verb("history_back")
    case .historyForward: return verb("history_forward")
    case .movementBack: return verb("movement_back")
    case .movementForward: return verb("movement_forward")
    case .appPrev: return verb("app_previous")
    case .appNext: return verb("app_next")
    case .quitApp(let force):
      return force ? verb("app_quit", [flag("force")]) : verb("app_quit")
    case .saveAndQuit(let force):
      return force ? verb("app_save_and_quit", [flag("force")]) : verb("app_save_and_quit")
    case .tabNew: return verb("tab_new")
    case .showAlert(let alert): return verb("alert_show", alert.argTokens)
    case .dismissAlert: return verb("alert_dismiss")
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return verb("help_show", [kv("topic", topic)]) }
      return verb("help_show")
    case .showPlugins: return verb("plugins")
    case .dismissHints: return verb("hints_dismiss")
    case .quit: return verb("quit")
    case .openApp(let name): return verb("app_open", [kv("name", name)])
    case .pluginCommand(let command, let subcommand, let args):
      var tokens = [kv("command", command), kv("subcommand", subcommand)]
      if !args.isEmpty {
        tokens.append(kv("args", args.joined(separator: " ")))
      }
      return verb("plugin_command", tokens)
    case .moveWindow(let params):
      var parts: [String] = []
      if let position = params.position {
        parts.append(kv("position", position.rawValue))
      }
      parts.append(kv("screen", params.screen))
      return verb("window_move", parts)
    case .sendKey(let keys, _, _):
      return verb("send_key", [kv("keys", keys)])
    case .pluginVerb(let name, let args):
      let tokens = args.keys.sorted().map { key in kv(key, args[key] ?? "") }
      return verb(name, tokens)
    }
  }
}

extension MouseCommand {
  /// Arg tokens for `mouse_target` / `mouse_grid` in diagnostic form.
  /// Empty for a plain left-click, `["--secondary"]` for right-click,
  /// `["--double"]` for double-click, `["--move"]` for cursor-only move.
  var argTokens: [String] {
    switch self {
    case .move:
      return ["--move"]
    case .click(let action):
      switch action {
      case .leftClick: return []
      case .rightClick: return ["--secondary"]
      case .doubleClick: return ["--double"]
      }
    }
  }
}

extension Config {
  static let helpTopic = HelpTopic(
    name: "config",
    title: "Configuration",
    summary: "flash.toml sections, defaults, and live reload.",
    body: """
      # Configuration

      Flash reads `$XDG_CONFIG_HOME/flash/flash.toml`, then
      `~/.config/flash/flash.toml` when XDG is unset. The active file is
      watched and reloaded live.

      User-facing sections are:

      - `[hints]`
      - `[open]`
      - `[plugins]`
      - `[mode]`
      - `[mode.all.mappings]`
      - `[mode.normal]`
      - `[mode.normal.mappings]`
      - `[mode.insert.mappings]`
      - `[debug]`

      Mapping values are argv arrays. `["flash", "<verb>", "k=v", …]`,
      or the same form with a Flash executable path as the head, dispatches
      the verb in-process; any other head is executed as argv with `~`/env
      expansion. Relative argv paths containing `/` resolve from the config
      file location.

      `config.default.toml` is the canonical reference for all accepted keys.
      """)
}
