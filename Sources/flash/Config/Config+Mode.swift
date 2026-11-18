import FlashCore
import Foundation

extension Config {
  struct Mode: Equatable {
    struct AppMappings: Equatable {
      var all: [ModeMapping] = []
      var normal: [ModeMapping] = []
      var insert: [ModeMapping] = []
      var terminal: [ModeMapping] = []
      var command: [ModeMapping] = []
      var hyper: [ModeMapping] = []
      var hold: [ModeMapping] = []
      var text: [ModeMapping] = []
      var visual: [ModeMapping] = []
      var unmapped: [ModeScope: Set<String>] = [:]
      /// `[mode.apps."<bundle>".text] enabled`: whether NORMAL may engage a field in
      /// this app, over the plugins' `own_text_editing` declarations; nil
      /// leaves it to them (`TextScope.Policy`).
      var engagesText: Bool?

      func mappings(for scope: ModeScope) -> [ModeMapping] {
        switch scope {
        case .all: return all
        case .normal: return normal
        case .insert: return insert
        case .terminal: return terminal
        case .command: return command
        case .hyper: return hyper
        case .hold: return hold
        case .text: return text
        case .visual: return visual
        }
      }

      mutating func set(_ mapping: ModeMapping, in scope: ModeScope) {
        let sameKey: (ModeMapping) -> Bool = {
          $0.key == mapping.key
            || (mapping.nativeHotkey != nil && $0.nativeHotkey == mapping.nativeHotkey)
        }
        if let removed = unmapped[scope] {
          let remaining = removed.filter {
            $0 != mapping.key
              && (mapping.nativeHotkey == nil
                || ModeMapping.parseNativeHotkey($0) != mapping.nativeHotkey)
          }
          unmapped[scope] = remaining.isEmpty ? nil : remaining
        }
        switch scope {
        case .all:
          all.removeAll(where: sameKey)
          all.insert(mapping, at: 0)
        case .normal:
          normal.removeAll(where: sameKey)
          normal.insert(mapping, at: 0)
        case .insert:
          insert.removeAll(where: sameKey)
          insert.insert(mapping, at: 0)
        case .terminal:
          terminal.removeAll(where: sameKey)
          terminal.insert(mapping, at: 0)
        case .command:
          command.removeAll(where: sameKey)
          command.insert(mapping, at: 0)
        case .hyper:
          hyper.removeAll(where: sameKey)
          hyper.insert(mapping, at: 0)
        case .hold:
          hold.removeAll(where: sameKey)
          hold.insert(mapping, at: 0)
        case .text:
          text.removeAll(where: sameKey)
          text.insert(mapping, at: 0)
        case .visual:
          visual.removeAll(where: sameKey)
          visual.insert(mapping, at: 0)
        }
      }

      mutating func remove(_ key: String, in scope: ModeScope) {
        let chord = ModeMapping.parseNativeHotkey(key)
        let matches: (ModeMapping) -> Bool = {
          $0.key == key || (chord != nil && $0.nativeHotkey == chord)
        }
        unmapped[scope, default: []].insert(key)
        switch scope {
        case .all: all.removeAll(where: matches)
        case .normal: normal.removeAll(where: matches)
        case .insert: insert.removeAll(where: matches)
        case .terminal: terminal.removeAll(where: matches)
        case .command: command.removeAll(where: matches)
        case .hyper: hyper.removeAll(where: matches)
        case .hold: hold.removeAll(where: matches)
        case .text: text.removeAll(where: matches)
        case .visual: visual.removeAll(where: matches)
        }
      }
    }

    struct Labels: Equatable {
      var normal: String = "NORMAL"
      var insert: String = "INSERT"
      var command: String = "COMMAND"
      var terminal: String = "TERMINAL"
      var hyper: String = "HYPER"
      var hold: String = "HOLD"
      var visual: String = "VISUAL"
      var visualLine: String = "V-LINE"

      var longestCount: Int {
        max(
          normal.count, insert.count, command.count, terminal.count, hyper.count, hold.count,
          visual.count, visualLine.count)
      }
    }

    var all: [ModeMapping] = [
      ModeMapping(key: "cmd+ctrl+h", action: .flashCommand(.holdMode(.primary)))
    ]
    var normal: [ModeMapping] = Self.defaultNormalMappings
    var insert: [ModeMapping] = []
    var terminal: [ModeMapping] = Self.defaultTerminalMappings
    var command: [ModeMapping] = []
    /// Keys read while the NORMAL leader is held. Not merged with `[mode.all]`:
    /// a hyper binding replaces NORMAL for that key for the duration of the hold.
    var hyper: [ModeMapping] = Self.defaultHyperMappings
    /// Keys read before NORMAL in HOLD (a held button dragging). A key with
    /// no entry here is NORMAL's.
    var hold: [ModeMapping] = Self.defaultHoldMappings
    /// Keys read before NORMAL's while a field is engaged (`TextScope`):
    /// Vim's motions. A key with no entry here is NORMAL's.
    var text: [ModeMapping] = Self.defaultTextMappings
    /// VISUAL's own keys: its operators, read before the text table's
    /// motions. VISUAL reads nothing else but `[mode.all]`.
    var visual: [ModeMapping] = Self.defaultVisualMappings
    /// Exact focused-app bundle identifier to per-scope additions/removals.
    var appMappings: [String: AppMappings] = [:]

    /// `[mode.layers.<name>]`: a user-defined key table, entered by
    /// `mode layer --name=<name>` and left by Escape or `mode leave`.
    struct Layer: Equatable {
      /// The pill text; nil shows the name in capitals.
      var label: String?
      /// Stay after a mapping runs (the default); false leaves after one.
      var sticky = true
      /// The layer's own mappings, in file order.
      var mappings: [ModeMapping] = []
      /// Keys a `false` entry took out of what the layer inherits: an
      /// `[mode.all]` key, or `<escape>`'s implicit `mode leave`.
      var unmapped: Set<String> = []

      func removes(_ mapping: ModeMapping) -> Bool {
        if unmapped.contains(mapping.key) { return true }
        guard let chord = mapping.nativeHotkey else { return false }
        return unmapped.contains { ModeMapping.parseNativeHotkey($0) == chord }
      }

      mutating func set(_ mapping: ModeMapping) {
        unmapped = unmapped.filter {
          $0 != mapping.key
            && (mapping.nativeHotkey == nil
              || ModeMapping.parseNativeHotkey($0) != mapping.nativeHotkey)
        }
        mappings.removeAll { $0.key == mapping.key }
        mappings.append(mapping)
      }

      mutating func remove(_ key: String) {
        let chord = ModeMapping.parseNativeHotkey(key)
        unmapped.insert(key)
        mappings.removeAll { $0.key == key || (chord != nil && $0.nativeHotkey == chord) }
      }
    }

    /// The declared layers by name. Plugins and `[mode.apps]` add nothing
    /// here: a layer is the user's own table.
    var layers: [String: Layer] = [:]

    /// A layer name: lowercase letters, digits, `_` and `-`, at most 32.
    static func isValidLayerName(_ name: String) -> Bool {
      (1...32).contains(name.count)
        && name.unicodeScalars.allSatisfy {
          ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// Names a layer cannot take: Flash's own modes and mapping scopes.
    /// `flash resident status` reports a layer by name in the same `mode`
    /// field, so the two never read alike.
    static let reservedLayerNames: Set<String> = [
      "all", "command", "disabled", "hold", "hyper", "insert", "normal", "terminal", "text",
      "visual",
    ]

    /// Escape leaves every layer unless its table maps or removes
    /// `<escape>`.
    static let layerEscapeMapping = ModeMapping(
      key: NormalModeInterpreter.canonicalizeMappingKey("<escape>") ?? "escape",
      action: .flashCommand(.leaveMode))

    /// What a layer reads: its own entries, then Escape's `mode leave` and
    /// the all-mode ones it leaves alone. An unknown name (a layer a reload
    /// removed) still reads Escape, so it can always be left.
    func layerMappings(_ name: String) -> [ModeMapping] {
      let layer = layers[name] ?? Layer()
      let inherited = ([Self.layerEscapeMapping] + all).filter { !layer.removes($0) }
      return Self.resolveMappings(layer.mappings + inherited)
    }

    /// The pill text for a layer.
    func layerLabel(_ name: String) -> String {
      layers[name]?.label ?? name.uppercased()
    }

    /// Every layer's own mappings, by layer name.
    var layerMappingEntries: [ModeMapping] {
      layers.sorted { $0.key < $1.key }.flatMap(\.value.mappings)
    }

    /// Keys a `"<key>" = false` entry removed, per table, after every layer.
    /// A later layer mapping the key again takes it back out. Plugin
    /// mappings on these keys are dropped too (`EffectiveMappings.merge`).
    /// The text table starts without the NORMAL keys that would lose what was
    /// typed (`defaultTextUnmapped`).
    var unmapped: [ModeScope: Set<String>] = [
      .text: Mode.defaultTextUnmapped, .hold: Mode.defaultHoldUnmapped,
    ]

    /// NORMAL keys that do nothing in text: `r` / `R` reload the page, which
    /// loses what was typed in the field. `x` is not among them: the tab
    /// closes in a field too, as asked.
    static let defaultTextUnmapped: Set<String> = Set(
      ["r", "R"].compactMap(NormalModeInterpreter.canonicalizeMappingKey))

    /// NORMAL keys that do nothing while a button is held: `x` would close
    /// the tab under the drag.
    static let defaultHoldUnmapped: Set<String> = Set(
      ["x"].compactMap(NormalModeInterpreter.canonicalizeMappingKey))

    /// Whether a `false` entry in `scope` removed `mapping`'s key, compared
    /// by physical chord so `cmd+shift+]` also removes `cmd+shift+}`.
    func removes(_ mapping: ModeMapping, in scope: ModeScope) -> Bool {
      guard let keys = unmapped[scope], !keys.isEmpty else { return false }
      if keys.contains(mapping.key) { return true }
      guard let chord = mapping.nativeHotkey else { return false }
      return keys.contains { ModeMapping.parseNativeHotkey($0) == chord }
    }

    /// The proportional layouts `window move` mappings apply, in any scope.
    var declaredWindowLayouts: [WindowLayout] {
      var layouts: [WindowLayout] = []
      let appEntries = appMappings.sorted { $0.key < $1.key }.flatMap { entry in
        let app = entry.value
        return app.all + app.normal + app.insert + app.terminal + app.command + app.hyper
      }
      for mapping in all + normal + insert + terminal + command + hyper + appEntries
        + layerMappingEntries
      {
        guard case .flashCommand(.moveWindow(let params)) = mapping.action,
          case .proportional? = params.layout, let layout = params.layout,
          !layouts.contains(layout)
        else { continue }
        layouts.append(layout)
      }
      return layouts
    }
    var normalLeader: String? = Self.defaultNormalLeader
    var labels = Labels()
    /// How long the interpreter waits for the next key in a pending
    /// sequence before resolving the longest matching prefix.
    /// Vim's `timeoutlen`. Lower → faster commits, more two-key
    /// collisions; higher → slower commits, fewer surprises.
    var sequenceTimeoutMs: Int = Self.defaultSequenceTimeoutMs
    /// How long a NORMAL prefix (`g`, `]`, `<leader>`) waits before the
    /// which-key palette lists what can follow it; 0 never shows it.
    var whichKeyMs: Int = 500
    /// Pixels per horizontal h/l scroll step.
    var scrollStep: Int = 60
    /// Mouse-wheel lines per `scroll up` / `scroll down`: `j` / `k` where
    /// they scroll. `ctrl+e` / `ctrl+y` scroll one line (`scroll line_down`).
    var scrollStepLines: Int = 3
    /// Mouse-wheel lines per ctrl+d/ctrl+u scroll step.
    var scrollPageLines: Int = 20
    /// `[mode.text] enabled`: whether NORMAL engages a field at all. False
    /// leaves every field to the app (kindaVim, SketchyVim): `v` / `V` do
    /// nothing and the text table is never read (`TextScope.Policy`).
    var textEnabled = true
    /// Arrows per ctrl+d/ctrl+u half page where they move a caret or a
    /// selection (`move half_page_down`); ctrl+f/ctrl+b send twice as many.
    var movePageLines: Int = Self.defaultMovePageLines
    /// About half of a typical text or list view's visible rows (30): Vim's
    /// ctrl+d moves half a window, and a list overshot by too many arrows is
    /// harder to follow than one that needs a second press.
    static let defaultMovePageLines = 15
    /// Spread each vertical line scroll over this many milliseconds as
    /// several smaller line events (`SmoothScroll`); 0 posts it at once.
    var scrollSmoothMs: Int = 0
    /// Mouse-down→up hold on synthesized clicks; some apps need a
    /// non-zero press to register.
    var clickHoldMs: Int = 18
    /// Delay between chords of a multi-key `key sequence` — terminals and
    /// remote-desktop apps drop chords sent back-to-back.
    var sendKeyIntervalMs: Int = 35
    /// Matches Neovim's `timeoutlen` default so multi-key sequences feel the
    /// same as in the editor users already have muscle memory for.
    static let defaultSequenceTimeoutMs = 1000

    /// Single-atom key form, parsed via `NormalModeInterpreter.parseKeySequence`.
    /// Use `\` bare or `<backslash>` — both resolve to the same key.
    static let defaultNormalLeader = "\\"
    /// `mode.normal.hyper`, in mapping-key syntax. `"<leader>"` follows
    /// `normalLeader` and resolves to nothing when the leader is unset.
    static let defaultHyperKey = "<leader>"
    var hyperKey: String = Self.defaultHyperKey
    /// The physical key that enters HYPER, after `<leader>` substitution.
    /// Nil when `hyperKey` is `"<leader>"` and no leader is set.
    private(set) var resolvedHyperKey: String?
    /// `resolvedHyperKey` prepared for the per-key test: its chord and the
    /// characters that may spell it, parsed once here rather than per key.
    private(set) var resolvedHyperMatcher: HyperKeyMatcher?
    /// `normalLeader` in mapping-atom form, translated once per load.
    private(set) var resolvedLeaderAtom: String?

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return Self.resolveMappings(normal + all)
      case .insert:
        return Self.resolveMappings(insert + all)
      }
    }

    /// Scope-specific entries precede all-mode fallbacks. Chord aliases share
    /// one winner across the interpreter and native hotkey dispatcher.
    static func resolveMappings(_ mappings: [ModeMapping]) -> [ModeMapping] {
      var keys: Set<String> = []
      var chords: Set<ParsedHotkey> = []
      return mappings.filter { mapping in
        guard keys.insert(mapping.key).inserted else { return false }
        guard let chord = mapping.nativeHotkey else { return true }
        return chords.insert(chord).inserted
      }
    }

    /// O(1)-lookup view used on every keystroke. Refreshed by
    /// `prepareDerivedValues()` after every config load / reload.
    private(set) var compiledNormal = CompiledMappings()
    private(set) var compiledInsert = CompiledMappings()
    private(set) var compiledTerminal = CompiledMappings()
    private(set) var compiledHyper = CompiledMappings()
    /// The table the interpreter reads in HOLD (`heldMappings`).
    private(set) var compiledHold = CompiledMappings()
    /// The table the interpreter reads in NORMAL while it acts on the
    /// focused text (`textMappings`).
    private(set) var compiledText = CompiledMappings()
    /// The table the interpreter reads in VISUAL (`visualMappings`).
    private(set) var compiledVisual = CompiledMappings()
    /// The table the interpreter reads in each layer (`layerMappings`).
    private(set) var compiledLayers: [String: CompiledMappings] = [:]

    /// The interpreter's table for a layer; an undeclared one reads Escape
    /// and `[mode.all]` alone.
    func compiledLayer(_ name: String) -> CompiledMappings {
      compiledLayers[name] ?? CompiledMappings(layerMappings(name), readsVimKeys: false)
    }

    /// What a held-button mode reads: its own entries, then the NORMAL and
    /// all-mode ones it leaves alone. An own key hides every NORMAL key it
    /// starts, so it never waits on a longer NORMAL sequence, and `false` in
    /// its table removes a NORMAL key there.
    func heldMappings(_ purpose: ButtonHold) -> [ModeMapping] {
      assert(purpose == .hold)
      let scope: ModeScope = .hold
      let own = hold
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let inherited = mappings(for: .normal).filter { base in
        !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      return Self.resolveMappings(own + inherited)
    }

    /// What NORMAL reads while a field is engaged: the text table's
    /// own entries, then the NORMAL and all-mode ones it leaves alone. An own
    /// key hides every NORMAL key it starts, and `false` in its table removes
    /// a NORMAL key there.
    func textMappings() -> [ModeMapping] {
      let scope: ModeScope = .text
      let own = text
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let inherited = mappings(for: .normal).filter { base in
        !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      return Self.resolveMappings(own + inherited)
    }

    /// What VISUAL reads: its own keys (the operators, `v`, `V`, `o`,
    /// Escape), then the motions of the text table and NORMAL it leaves
    /// alone (`move`, `cursor`, `scroll`), then `[mode.all]`. Any other key
    /// is swallowed: tabs, hints and app commands are not VISUAL's.
    func visualMappings() -> [ModeMapping] {
      let scope: ModeScope = .visual
      let own = visual
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let motions = textMappings().filter { base in
        Self.isMotion(base.action) && !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      let allMode = all.filter { !removes($0, in: scope) }
      return Self.resolveMappings(own + motions + allMode)
    }

    /// A command that moves the cursor or the view, which VISUAL inherits.
    static func isMotion(_ action: MappingCommand) -> Bool {
      guard case .flashCommand(let command) = action else { return false }
      switch command {
      case .move, .cursor, .scroll, .scrollCursor: return true
      default: return false
      }
    }

    var effectiveTerminalMappings: [ModeMapping] {
      var claimed = Set<String>()
      let explicit = terminal.filter {
        claimed.insert(CompiledMappings.physicalIdentity(for: $0.key)).inserted
      }
      var insertClaimed = Set<String>()
      let inherited = mappings(for: .insert).filter {
        let identity = CompiledMappings.physicalIdentity(for: $0.key)
        return insertClaimed.insert(identity).inserted
          && ($0.action.command == .normalMode || $0.action.command == .leaveMode)
          && !removes($0, in: .terminal)
          && claimed.insert(identity).inserted
      }
      return explicit + inherited
    }

    mutating func recompileMappings() {
      compiledNormal = CompiledMappings(mappings(for: .normal))
      compiledInsert = CompiledMappings(mappings(for: .insert))
      compiledTerminal = CompiledMappings(effectiveTerminalMappings)
      compiledHyper = CompiledMappings(Self.resolveMappings(hyper))
      compiledHold = CompiledMappings(heldMappings(.hold))
      compiledText = CompiledMappings(textMappings())
      compiledVisual = CompiledMappings(
        visualMappings(), readsVimKeys: false, stopsRecording: true)
      compiledLayers = Dictionary(
        uniqueKeysWithValues: layers.keys.map {
          ($0, CompiledMappings(layerMappings($0), readsVimKeys: false))
        })
    }

    /// One mapping-key atom, or nil. `"<leader>"` becomes the leader atom, and
    /// stays nil when the leader itself is unset. Any other single key is
    /// used as written (`"a"`, `"<space>"`, `"cmd+space"`).
    static func resolveHyperKey(_ raw: String, leader: String?) -> String? {
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(raw) else { return nil }
      let atoms = NormalModeInterpreter.keyAtoms(from: canonical)
      guard atoms.count == 1, let atom = atoms.first else { return nil }
      if atom == "<leader>" {
        guard let leader else { return nil }
        return NormalModeInterpreter.translateLeader(leader)
      }
      return atom
    }

    mutating func refreshLeaderDerivedDefaults() {
      resolvedHyperKey = Self.resolveHyperKey(hyperKey, leader: normalLeader)
      resolvedHyperMatcher = resolvedHyperKey.map(HyperKeyMatcher.init(atom:))
      resolvedLeaderAtom = normalLeader.flatMap(NormalModeInterpreter.translateLeader)
      guard let leaderRaw = normalLeader,
        let leaderInternal = NormalModeInterpreter.translateLeader(leaderRaw)
      else { return }
      func resolvingLeader(_ mapping: ModeMapping) -> ModeMapping {
        guard mapping.key.contains("<leader>") else { return mapping }
        return ModeMapping(
          key: mapping.key.replacingOccurrences(of: "<leader>", with: leaderInternal),
          action: mapping.action,
          repeatsOnFinalKey: mapping.repeatsOnFinalKey,
          origin: mapping.origin)
      }
      normal = normal.map(resolvingLeader)
      hold = hold.map(resolvingLeader)
    }

    var containsNormalModeMapping: Bool {
      let appEntries = appMappings.values.flatMap {
        $0.all + $0.normal + $0.insert + $0.terminal + $0.command
      }
      return (all + normal + insert + command + terminal + appEntries).contains { mapping in
        mapping.action.command == .normalMode || mapping.action.command == .leaveMode
      }
    }

    var containsAdvancedModeMapping: Bool {
      (all + appMappings.values.flatMap(\.all)).contains { mapping in
        mapping.action.command == .normalMode || mapping.action.command == .leaveMode
      }
    }
  }
}
