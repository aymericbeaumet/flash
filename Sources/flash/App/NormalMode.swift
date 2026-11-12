import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

enum FlashMode: Equatable {
  case insert
  case normal
}

struct NormalModeTransition: Equatable {
  var pending: String
  var action: MappingCommand?
  var repeatCount: Int
  var repeatAnchor: String?

  var command: URLCommand? { action?.command }

  static func action(
    _ action: MappingCommand,
    repeatCount: Int = 1,
    repeatAnchor: String? = nil
  ) -> NormalModeTransition {
    NormalModeTransition(
      pending: "",
      action: action,
      repeatCount: RepeatCount.clamp(repeatCount),
      repeatAnchor: repeatAnchor)
  }

  static func pending(_ pending: String) -> NormalModeTransition {
    NormalModeTransition(pending: pending, action: nil, repeatCount: 1, repeatAnchor: nil)
  }

  static let consume = NormalModeTransition(
    pending: "", action: nil, repeatCount: 1, repeatAnchor: nil)
}

struct PendingNormalModeCommand: Equatable {
  var action: MappingCommand
  var repeatCount: Int
  var repeatAnchor: String?
}

/// A NORMAL count prefix (`3]t`): at least one, at most `max`, everywhere a
/// count is typed, carried or applied.
enum RepeatCount {
  static let max = 999

  static func clamp(_ count: Int) -> Int {
    Swift.min(Swift.max(count, 1), max)
  }
}

enum NormalModeInterpreter {
  private static let maxRepeatCount = RepeatCount.max
  static let sequenceTimeoutMs = 1000

  private struct PendingState {
    /// A count typed before a `"` register prefix (`3"ap`): it multiplies
    /// the count typed after the register, as Vim's does (`2"a3p` is six).
    var leadingCount: Int?
    var count: Int?
    var prefix: String
    /// The register captured from a `"<name>` prefix, if any. `nil` means no
    /// register prefix was typed (the operator falls back to the system
    /// clipboard). Distinct from `awaitingRegister`.
    var register: String?
    /// True after a bare `"` was typed but before its name key arrived — the
    /// interpreter is parked waiting for the register name.
    var awaitingRegister: Bool

    init(
      leadingCount: Int? = nil,
      count: Int? = nil,
      prefix: String,
      register: String? = nil,
      awaitingRegister: Bool = false
    ) {
      self.leadingCount = leadingCount
      self.count = count
      self.prefix = prefix
      self.register = register
      self.awaitingRegister = awaitingRegister
    }

    /// The count the command runs with: the counts before and after a
    /// register multiplied, nil when none was typed.
    var typedCount: Int? {
      guard leadingCount != nil || count != nil else { return nil }
      return RepeatCount.clamp((leadingCount ?? 1) * (count ?? 1))
    }

    var repeatCount: Int { typedCount ?? 1 }

    /// Serialize back into the opaque `pending` string. A count typed before
    /// a register leads, behind its own mark; then the register part (`"`
    /// alone while awaiting, `"a` once named), so a register name that is
    /// itself a digit can't be mistaken for a repeat count. The count
    /// follows, then the encoded key-atom prefix.
    var encoded: String {
      let leadingPart = leadingCount.map { String(leadingCountMark) + String($0) } ?? ""
      let registerPart: String
      if awaitingRegister {
        registerPart = "\""
      } else if let register {
        registerPart = "\"" + register
      } else {
        registerPart = ""
      }
      let prefixPart =
        prefix.first == "\"" || prefix.first?.isNumber == true
        ? String(mappingPrefixMark) + prefix : prefix
      return "\(leadingPart)\(registerPart)\(count.map(String.init) ?? "")\(prefixPart)"
    }

    func appendingPrefix(_ next: String) -> String {
      PendingState(leadingCount: leadingCount, count: count, prefix: next, register: register)
        .encoded
    }
  }

  /// Distinguishes a mapped digit or quote prefix from a count or register.
  private static let mappingPrefixMark: Character = "\u{15}"
  /// Leads a count typed before a `"` register prefix; never typed.
  static let leadingCountMark: Character = "\u{14}"
  /// Leads a pending `q` or `@` waiting for its register name; never typed.
  static let macroPendingMark: Character = "\u{11}"
  /// Leads a pending `m`, `'` or `` ` `` waiting for its mark; never typed.
  static let markPendingMark: Character = "\u{12}"
  /// Leads a character search (`t`, `T`, a `cursor next_char` mapping)
  /// waiting for its character; never typed. Then the search's letter (`f`
  /// `F` `t` `T`) and the count.
  static let characterPendingMark: Character = "\u{13}"

  /// The pending state a mapping that waits for a character leaves, or nil
  /// for any other action.
  static func characterPending(for action: MappingCommand, count: Int) -> String? {
    guard case .flashCommand(.cursor(let command)) = action,
      let kind = command.awaitsCharacter
    else { return nil }
    return String(characterPendingMark) + kind.pendingCode + String(count)
  }

  /// Whether `character` can be searched for: a printing character or a tab,
  /// never Escape, Return or another control key, which cancel the search.
  static func isSearchableCharacter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1
    else { return true }
    return scalar == "\t" || !(scalar.value < 0x20 || scalar.value == 0x7F)
  }

  /// vim's mark keys while no mapping takes them: `m{x}` saves the focused
  /// app as mark `x`, `'{x}` and `` `{x} `` bring it back. A mapping always
  /// wins: `mf`, `mF` and `ms` stay the mouse moves, and a `'a` the config
  /// binds runs instead of jumping to mark `a`.
  static func markCommand(operation: String, name: Character?) -> MarkCommand? {
    guard let name, let slot = MarkSlot(parsing: String(name)) else { return nil }
    switch operation {
    case "m": return .set(slot)
    case "'", "`": return .jump(slot)
    default: return nil
    }
  }

  /// What a mark key followed by `name` runs: a mark (`markCommand`), or,
  /// for vim's `''` and ``` `` ```, the way back to before the last jump
  /// (`movement back`, `ctrl+o`). Nil for a name that is no mark.
  static func markAction(operation: String, name: Character?) -> MappingCommand? {
    if operation == "'" || operation == "`", name == "'" || name == "`" {
      return .flashCommand(.movementBack)
    }
    return markCommand(operation: operation, name: name).map { .flashCommand(.marks($0)) }
  }

  /// What typing `keys` in NORMAL runs, read by `interpret` one character at
  /// a time as the keyboard delivers them, so counts, registers, marks,
  /// macros and `{N}gt` mean what they mean typed (`:normal`). Nil for keys
  /// that are not all plain characters (a chord or a named key reads as a
  /// mapping key instead), that run nothing, or that go on after a command
  /// ran. A sequence still pending at the end runs what its timeout would.
  static func typedKeysAction(
    _ keys: String, mappings: CompiledMappings, recordingMacro: Bool
  ) -> (action: MappingCommand, count: Int)? {
    guard let canonical = canonicalizeMappingKey(keys) else { return nil }
    let atoms = keyAtoms(from: canonical)
    guard !atoms.isEmpty, atoms.allSatisfy({ $0.count == 1 }) else { return nil }
    var pending = ""
    for (index, atom) in atoms.enumerated() {
      let transition = interpret(
        pending: pending, keyCode: syntheticKeyCode,
        modifierFlags: atom.first?.isUppercase == true ? [.shift] : [], characters: atom,
        charactersIgnoringModifiers: atom.lowercased(), mappings: mappings,
        recordingMacro: recordingMacro)
      if let action = transition.action {
        return index == atoms.count - 1 ? (action, transition.repeatCount) : nil
      }
      pending = transition.pending
    }
    guard let command = pendingCommand(pending: pending, mappings: mappings) else { return nil }
    return (command.action, command.repeatCount)
  }

  /// No physical key: a typed character in `typedKeysAction` is read by its
  /// character alone, never as a named key.
  private static let syntheticKeyCode: UInt16 = 0xFFFF

  /// vim's `{count}gt` goes to tab `count` (`countPicking`).
  private static let gtSequence = canonicalizeMappingKey("gt")!

  /// A count that names what a command picks rather than how often it runs:
  /// `{count}gt` is tab `count` (on `gt` itself; `K` repeats), a count
  /// before a `mouse screens` that labels is display `count`, and one before
  /// `.` is the count the repeat runs with (`1.` too).
  static func countPicking(_ action: MappingCommand, count: Int, sequence: String)
    -> MappingCommand?
  {
    if sequence == gtSequence, case .flashCommand(.tabNext) = action {
      return .flashCommand(.tabSelect(index: count))
    }
    // vim's `{count}G` and `{count}gg` go to line `count`, `{count}%` to the
    // line `count` percent of the way through.
    if case .flashCommand(.cursor(.motion(let motion))) = action {
      switch motion {
      case .firstLine, .lastLine: return .flashCommand(.cursor(.line(index: count)))
      case .matchingBracket: return .flashCommand(.cursor(.percent(min(count, 100))))
      default: break
      }
    }
    if case .flashCommand(.mouseScreens(var request)) = action, request.pick == .labels {
      request.pick = .index(count)
      return .flashCommand(.mouseScreens(request))
    }
    if case .flashCommand(.macro(.repeatLast(count: nil))) = action {
      return .flashCommand(.macro(.repeatLast(count: count)))
    }
    return nil
  }

  static func interpret(
    pending: String,
    repeatAnchor: String? = nil,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: CompiledMappings,
    recordingMacro: Bool = false
  ) -> NormalModeTransition {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)

    let hasControl = independent.contains(.control)
    let ignoredChar = firstCharacter(charactersIgnoringModifiers)?.lowercased().first
    let actualChar = firstCharacter(characters)
    let state = pendingState(pending)
    let escape = isEscape(
      keyCode: keyCode, modifierFlags: independent, characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers)
    var keys = mappingKeys(
      keyCode: keyCode,
      modifierFlags: independent,
      hasControl: hasControl,
      hasShift: independent.contains(.shift),
      ignoredChar: ignoredChar,
      actualChar: actualChar)
    // Vim's Control-[ is Escape: after its own atom, a mapping on `ctrl+[`
    // winning, it reads as `<esc>`.
    if escape, !keys.contains(escapeKeyAtom) { keys.append(escapeKeyAtom) }
    // A plain character names a register, a mark or a macro; a chord, a
    // named key or Escape never does.
    let plainName: Character? =
      independent.subtracting(.shift).isEmpty && !escape ? actualChar : nil

    // A repeatable mapping keeps only its completed key sequence as an anchor.
    // Pressing the same final atom dispatches it again; any other key drops the
    // anchor and is interpreted normally from scratch. The overlay expires the
    // anchor with `sequence_timeout_ms`, so a later standalone `a` remains the
    // regular insert-mode mapping after `[a`.
    if pending.isEmpty,
      let repeatAnchor,
      let mapping = mappings.mapping(for: repeatAnchor),
      mapping.repeatsOnFinalKey,
      let finalAtom = keyAtoms(from: repeatAnchor).last,
      keys.contains(finalAtom)
    {
      return .action(mapping.action, repeatAnchor: repeatAnchor)
    }

    // A `q` or `@` parked us waiting for a macro register: this key names it
    // (`qa`, `qA` appending, `@a`, `@@` for the last one played, `@:` for the
    // last command line). Any other key, Escape included, abandons the
    // prefix and runs nothing, as in Vim.
    if pending.first == macroPendingMark {
      let operation = pending.dropFirst().first
      let count = Int(pending.dropFirst(2)) ?? 1
      guard let name = plainName else { return .consume }
      if operation == "q" {
        guard let register = MacroCommand.recordingRegister(String(name)) else {
          return .consume
        }
        return .action(.flashCommand(.macro(.record(register: register))))
      }
      if name == "@" {
        return .action(.flashCommand(.macro(.play(register: nil))), repeatCount: count)
      }
      guard let register = MacroCommand.playRegister(String(name)) else { return .consume }
      return .action(.flashCommand(.macro(.play(register: register))), repeatCount: count)
    }

    // A character search parked us waiting for its character: this key is
    // it, whatever it would otherwise run. Escape, Return or a chord cancels.
    if pending.first == characterPendingMark {
      let rest = pending.dropFirst()
      guard let code = rest.first, let kind = CharacterSearchKind(pendingCode: code) else {
        return .consume
      }
      let count = Int(rest.dropFirst()) ?? 1
      guard let character = actualChar, independent.subtracting(.shift).isEmpty,
        isSearchableCharacter(character)
      else { return .consume }
      return .action(
        .flashCommand(.cursor(.findCharacter(kind, character))), repeatCount: count)
    }

    // A bare `m`, `'` or `` ` `` parked us waiting for a mark: this key names
    // it. Anything else, Escape included, abandons the prefix and runs
    // nothing, as in Vim.
    if pending.first == markPendingMark {
      let operation = String(pending.dropFirst().prefix(1))
      return markAction(operation: operation, name: plainName).map { .action($0) } ?? .consume
    }

    // A bare `"` parked us waiting for a register name. Consume this key as
    // that name. Anything else, Escape included, abandons the register
    // prefix and runs nothing, as in Vim: `".` never repeats, `":` never
    // opens the command line.
    if state.awaitingRegister {
      guard let name = plainName, isRegisterNameChar(name) else { return .consume }
      return .pending(
        PendingState(leadingCount: state.leadingCount, prefix: "", register: String(name))
          .encoded)
    }

    // `m`, `'` and `` ` `` are vim's mark keys while no mapping takes them or
    // starts with them; a key that only starts mappings (the default `m`) is
    // read as a mark below, once the next key extends no mapping. A count
    // before them is accepted and, as in Vim, means nothing.
    if mappings.readsVimKeys, state.prefix.isEmpty, state.register == nil,
      let key = plainName, key == "m" || key == "'" || key == "`",
      mappings.mapping(for: String(key)) == nil, !mappings.hasStrictPrefix(String(key))
    {
      return .pending(String(markPendingMark) + String(key))
    }

    // `q` and `@` are vim's macro keys while no mapping takes them: `q` names
    // the register to record (or stops the recording, in VISUAL too), `@`
    // the one to play, after an optional count (`3@a`). A count before `q`
    // is accepted and means nothing.
    if state.prefix.isEmpty, state.register == nil, let key = plainName,
      key == "q" || key == "@",
      mappings.mapping(for: String(key)) == nil, !mappings.hasStrictPrefix(String(key))
    {
      if key == "q", recordingMacro, mappings.stopsRecording {
        return .action(.flashCommand(.macro(.stop)))
      }
      if mappings.readsVimKeys {
        let count = key == "@" ? state.typedCount.map(String.init) ?? "" : ""
        return .pending(String(macroPendingMark) + String(key) + count)
      }
    }

    if state.prefix.isEmpty, independent.subtracting([.shift, .capsLock]).isEmpty,
      let digit = digitValue(actualChar)
    {
      // A digit bound to a command is that command. Otherwise it is a repeat
      // count, and a bare `0` is swallowed.
      // vim's `0` is a motion only at the start of a count: `10j` is ten.
      let digitIsCommand =
        !(digit == 0 && state.count != nil)
        && keys.contains { key in
          mappings.mapping(for: key) != nil || mappings.hasStrictPrefix(key)
        }
      if !digitIsCommand {
        if state.count == nil, digit == 0 {
          return .consume
        }
        let next = min(((state.count ?? 0) * 10) + digit, maxRepeatCount)
        return .pending(
          PendingState(
            leadingCount: state.leadingCount, count: next, prefix: "", register: state.register
          ).encoded)
      }
    }

    // `"` starts a register prefix (Vim's `"<reg>`), but only when it's at the
    // head of a fresh command and the user hasn't bound `"` to something else.
    // A count typed before it is kept (`3"ap` pastes three times) and
    // multiplies one typed after the name (`2"a3p` is six).
    if state.prefix.isEmpty, state.register == nil, actualChar == "\"",
      mappings.mapping(for: "\"") == nil, !mappings.hasStrictPrefix("\"")
    {
      return .pending(
        PendingState(leadingCount: state.count, prefix: "", awaitingRegister: true).encoded)
    }

    guard !keys.isEmpty else {
      return .consume
    }
    // Escape abandons a half-typed sequence, a count or a register, as in
    // Vim, and runs nothing: `g` then Escape never leaves the mode or the
    // engaged field. A sequence that maps Escape itself still reads it.
    let halfTyped = !state.prefix.isEmpty || state.typedCount != nil || state.register != nil
    if halfTyped, escape {
      let sequence = appendKeyAtom(state.prefix, escapeKeyAtom)
      let continues =
        !state.prefix.isEmpty
        && (mappings.mapping(for: sequence) != nil || mappings.hasStrictPrefix(sequence))
      if !continues { return .consume }
    }
    for key in keys {
      let sequence = appendKeyAtom(state.prefix, key)
      let exact = mappings.mapping(for: sequence)
      let hasLonger = mappings.hasStrictPrefix(sequence)
      if let mapping = exact, !hasLonger {
        if let count = state.typedCount,
          let picked = countPicking(mapping.action, count: count, sequence: sequence)
        {
          return .action(picked)
        }
        if let waiting = characterPending(for: mapping.action, count: state.repeatCount) {
          return .pending(waiting)
        }
        return .action(
          applyingRegister(state.register, to: mapping.action),
          repeatCount: state.repeatCount,
          repeatAnchor: mapping.repeatsOnFinalKey ? mapping.key : nil)
      }
      if exact != nil || hasLonger {
        return .pending(state.appendingPrefix(sequence))
      }
    }
    // A prefix that is a mark key and no mapping's start with this key: vim's
    // `ma` while `m` only begins `mf`, `mF` and `ms`, or `'d` beside a
    // config's `'a`.
    if mappings.readsVimKeys, keyAtoms(from: state.prefix).count == 1,
      let action = markAction(operation: state.prefix, name: plainName)
    {
      return .action(action)
    }
    // The key extends the pending sequence to nothing mapped: as in Vim, the
    // sequence is abandoned and the key with it, so `gx` never closes the
    // tab and `z.` never repeats. Without a pending sequence an unmapped key
    // is swallowed too. The keyboard tap decides before this point whether
    // an unmapped modified chord should instead pass through; when that
    // config is disabled, this keeps NORMAL hermetic.
    return .consume
  }

  /// Escape, or Vim's Control-[ (the ASCII escape it types): a cancel to the
  /// interpreter, and `<esc>` to the mappings.
  static func isEscape(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)
    if namedKeyAtom(keyCode: keyCode) == escapeKeyAtom { return independent.isEmpty }
    guard independent == .control else { return false }
    return characters == "\u{1B}" || charactersIgnoringModifiers == "["
  }

  static func firstCharacter(_ value: String?) -> Character? {
    guard let value, let first = value.first else { return nil }
    return first
  }

  static func pendingCommand(
    pending: String,
    mappings: CompiledMappings
  ) -> PendingNormalModeCommand? {
    let state = pendingState(pending)
    guard !state.prefix.isEmpty,
      let mapping = mappings.mapping(for: state.prefix)
    else { return nil }
    if let count = state.typedCount,
      let picked = countPicking(mapping.action, count: count, sequence: state.prefix)
    {
      return PendingNormalModeCommand(action: picked, repeatCount: 1, repeatAnchor: nil)
    }
    return PendingNormalModeCommand(
      action: applyingRegister(state.register, to: mapping.action),
      repeatCount: state.repeatCount,
      repeatAnchor: mapping.repeatsOnFinalKey ? mapping.key : nil)
  }

  /// Fast raw-event recognition for the keyboard tap's mapping decision.
  /// `CompiledMappings` pre-indexes canonical atoms by physical hotkey, so this
  /// remains layout-free and allocation-light for repeated system chords such
  /// as Command-Tab while still preserving shifted mappings and modified
  /// sequence prefixes.
  static func recognizesPhysicalKey(
    pending: String,
    repeatAnchor: String?,
    virtualKey: UInt32,
    modifierFlags: CGEventFlags,
    mappings: CompiledMappings
  ) -> Bool {
    // Keypad Enter is Return to every mapping (`namedKeyAtom`).
    let keys = mappings.physicalKeyAtoms(
      virtualKey: HotkeySyntax.unifiedVirtualKey(virtualKey), cgFlags: modifierFlags)
    guard !keys.isEmpty else { return false }
    let state = pendingState(pending)
    if state.awaitingRegister {
      return keys.contains { key in
        key.count == 1 && key.first.map(isRegisterNameChar) == true
      }
    }
    if pending.isEmpty,
      let repeatAnchor,
      let mapping = mappings.mapping(for: repeatAnchor),
      mapping.repeatsOnFinalKey,
      let finalAtom = keyAtoms(from: repeatAnchor).last,
      keys.contains(finalAtom)
    {
      return true
    }
    for key in keys {
      let sequence = appendKeyAtom(state.prefix, key)
      if mappings.mapping(for: sequence) != nil || mappings.hasStrictPrefix(sequence) {
        return true
      }
      if !state.prefix.isEmpty,
        mappings.mapping(for: key) != nil || mappings.hasStrictPrefix(key)
      {
        return true
      }
    }
    return false
  }

  /// Whether a native surface that owns the screen (a context menu, Mission
  /// Control, App Exposé) gets this key as typed although NORMAL maps it: the
  /// key NORMAL maps to `app cancel` (Escape by default) is the surface's own
  /// cancel, so it closes the surface as it does without Flash.
  static func passesToNativeSurface(
    virtualKey: UInt32, modifierFlags: CGEventFlags, mappings: CompiledMappings
  ) -> Bool {
    mappings.physicalKeyAtoms(
      virtualKey: HotkeySyntax.unifiedVirtualKey(virtualKey), cgFlags: modifierFlags
    ).contains { mappings.mapping(for: $0)?.action == .flashCommand(.appCancel) }
  }

  /// Bake a captured register into a yank/paste action. The register only
  /// modifies clipboard operators; for every other command (and when no
  /// register was typed) the action passes through unchanged — Vim likewise
  /// ignores a register prefix on commands that don't read one.
  static func applyingRegister(_ register: String?, to action: MappingCommand) -> MappingCommand {
    guard let register, case .flashCommand(let command) = action else { return action }
    switch command {
    case .yankSelection:
      return .flashCommand(.yankSelection(register: register))
    case .paste(_, let after):
      return .flashCommand(.paste(register: register, after: after))
    case .selection(let selection, _):
      return selection.takesRegister
        ? .flashCommand(.selection(selection, register: register)) : action
    default:
      return action
    }
  }

  /// Characters accepted as a `"<name>` register: letters (uppercase appends),
  /// digits, clipboard aliases `+` / `*` / `"`, and black hole `_`.
  static func isRegisterNameChar(_ ch: Character) -> Bool {
    if ch == "+" || ch == "*" || ch == "\"" || ch == "_" { return true }
    guard ch.isASCII else { return false }
    return ch.isLetter || ch.isNumber
  }

  /// The mapping keys a pending sequence has typed, without its count or
  /// register: what the which-key palette lists the continuations of.
  static func pendingPrefix(_ pending: String) -> String {
    pendingState(pending).prefix
  }

  /// Nil while the next key is intercepted as a selector or search character.
  static func continuationMappingPrefix(_ pending: String) -> String? {
    if pending.first == macroPendingMark || pending.first == markPendingMark
      || pending.first == characterPendingMark || pendingState(pending).awaitingRegister
    {
      return nil
    }
    return pendingPrefix(pending)
  }

  static func mappingAtomIsIntercepted(_ atom: String, after pending: String) -> Bool {
    let state = pendingState(pending)
    guard state.prefix.isEmpty else { return false }
    if state.count != nil, atom == "0" { return true }
    return (state.typedCount != nil || state.register != nil)
      && (atom == escapeKeyAtom || atom == "ctrl+[")
  }

  struct BuiltInContinuation {
    let key: String
    /// Nil selects a register for the next command rather than running one.
    let action: MappingCommand?
  }

  /// Finite selector inputs, resolved through the same transition as a real key.
  /// This describes accepted slot names; it never reads saved slot contents.
  static func builtInContinuations(after pending: String, in mappings: CompiledMappings)
    -> [BuiltInContinuation]
  {
    let state = pendingState(pending)
    let selector = pending.first == macroPendingMark || pending.first == markPendingMark
    let markFallback = mappings.readsVimKeys && ["m", "'", "`"].contains(state.prefix)
    guard selector || state.awaitingRegister || markFallback else { return [] }
    return (32...126).compactMap { code in
      let key = String(UnicodeScalar(code)!)
      if !selector, !state.awaitingRegister,
        markAction(operation: state.prefix, name: key.first) == nil
      {
        return nil
      }
      let transition = interpret(
        pending: pending, keyCode: syntheticKeyCode,
        modifierFlags: key.first?.isUppercase == true ? [.shift] : [],
        characters: key, charactersIgnoringModifiers: key.lowercased(), mappings: mappings)
      guard transition.action != nil || (state.awaitingRegister && !transition.pending.isEmpty)
      else { return nil }
      return BuiltInContinuation(key: key, action: transition.action)
    }
  }

  static func continuationAction(
    _ action: MappingCommand, after pending: String, sequence: String
  ) -> MappingCommand {
    let state = pendingState(pending)
    if let count = state.typedCount,
      let picked = countPicking(action, count: count, sequence: sequence)
    {
      return picked
    }
    return applyingRegister(state.register, to: action)
  }

  static func pendingDisplay(_ pending: String) -> String {
    if pending.first == markPendingMark { return String(pending.dropFirst()) }
    if pending.first == macroPendingMark {
      return String(pending.dropFirst(2)) + String(pending.dropFirst().prefix(1))
    }
    if pending.first == characterPendingMark { return "" }
    let state = pendingState(pending)
    guard !state.prefix.isEmpty || state.awaitingRegister else { return "" }
    return pendingLead(pending) + NormalModeDispatcher.displayMappingKey(state.prefix)
  }

  static func pendingSequenceTimedOut(
    pending: String,
    lastInputAt: Date?,
    now: Date = Date(),
    timeoutMs: Int = sequenceTimeoutMs
  ) -> Bool {
    guard !pending.isEmpty, let lastInputAt else { return false }
    return now.timeIntervalSince(lastInputAt) * 1_000 >= Double(timeoutMs)
  }

  private static func pendingState(_ pending: String) -> PendingState {
    // Decode a leading count (its mark, then digits), then the register part
    // (`"` alone, or `"` + one name char), mirroring `PendingState.encoded`.
    var rest = Substring(pending)
    var leadingCount: Int? = nil
    if rest.first == leadingCountMark {
      let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
      leadingCount = Int(digits).map { min($0, maxRepeatCount) }
      rest = rest.dropFirst(1 + digits.count)
    }
    var register: String? = nil
    var awaitingRegister = false
    if rest.first == "\"" {
      let afterQuote = rest.dropFirst()
      if let name = afterQuote.first {
        register = String(name)
        rest = afterQuote.dropFirst()
      } else {
        awaitingRegister = true
        rest = ""
      }
    }
    let digitPrefix = rest.prefix { ch in
      guard let value = ch.wholeNumberValue else { return false }
      return value >= 0 && value <= 9
    }
    let encodedPrefix = rest.dropFirst(digitPrefix.count)
    let prefix = String(
      encodedPrefix.first == mappingPrefixMark ? encodedPrefix.dropFirst() : encodedPrefix)
    let count = digitPrefix.isEmpty ? nil : Int(digitPrefix).map { min($0, maxRepeatCount) }
    return PendingState(
      leadingCount: leadingCount, count: count, prefix: prefix, register: register,
      awaitingRegister: awaitingRegister)
  }

  /// What a pending state shows as typed before its prefix: the counts and
  /// the register as the user typed them (`3"a2`), never the marks that
  /// encode them.
  static func pendingLead(_ pending: String) -> String {
    let state = pendingState(pending)
    var lead = state.leadingCount.map(String.init) ?? ""
    if state.awaitingRegister { lead += "\"" }
    if let register = state.register { lead += "\"" + register }
    return lead + (state.count.map(String.init) ?? "")
  }

  /// Whether `pending` is something the next key alone completes or
  /// breaks — a half-typed sequence, a mark, macro or register name, a
  /// character search — rather than a count or a register the next command
  /// takes. A chord mapping reaches the interpreter then, never its native
  /// dispatch, so it continues the sequence or abandons it, as any key does.
  static func pendingReadsNextKey(_ pending: String) -> Bool {
    guard let first = pending.first else { return false }
    if first == macroPendingMark || first == markPendingMark || first == characterPendingMark {
      return true
    }
    let state = pendingState(pending)
    return state.awaitingRegister || !state.prefix.isEmpty
  }

  /// What a single-chord mapping fired natively (a Carbon hotkey, the tap's
  /// or the key window's chord match, `ctrl+d`, `cmd+c`) runs against the
  /// pending state: with the count and register typed before it, as any
  /// mapping takes them (`3 ctrl+d`). After anything else half-typed the
  /// chord breaks it and runs nothing, as in Vim.
  static func nativeChord(pending: String, action: MappingCommand) -> NormalModeTransition {
    guard !pendingReadsNextKey(pending) else { return .consume }
    let state = pendingState(pending)
    if let count = state.typedCount, let picked = countPicking(action, count: count, sequence: "") {
      return .action(picked)
    }
    return .action(applyingRegister(state.register, to: action), repeatCount: state.repeatCount)
  }

  /// `pending` once `sequence_timeout_ms` passed without a key: a mapping
  /// prefix is dropped (its timer already ran an exact mapping it named),
  /// a lone mark key that only begins mappings (`m`) waits for its mark, and
  /// what Vim itself waits on — a count, a register, a mark, a macro name, a
  /// character search — stays until a key arrives.
  static func expiredPending(_ pending: String, mappings: CompiledMappings) -> String {
    guard let first = pending.first else { return pending }
    if first == macroPendingMark || first == markPendingMark || first == characterPendingMark {
      return pending
    }
    let state = pendingState(pending)
    guard !state.prefix.isEmpty else { return pending }
    if mappings.readsVimKeys, state.register == nil, mappings.mapping(for: state.prefix) == nil,
      ["m", "'", "`"].contains(state.prefix)
    {
      return String(markPendingMark) + state.prefix
    }
    return ""
  }

  private static func digitValue(_ char: Character?) -> Int? {
    guard let char, let value = char.wholeNumberValue, value >= 0, value <= 9 else {
      return nil
    }
    return value
  }

  /// The atoms a key event can match, in the interpreter's try-order.
  static func eventKeyAtoms(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?
  ) -> [String] {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    return mappingKeys(
      keyCode: keyCode,
      modifierFlags: independent,
      hasControl: independent.contains(.control),
      hasShift: independent.contains(.shift),
      ignoredChar: firstCharacter(charactersIgnoringModifiers)?.lowercased().first,
      actualChar: firstCharacter(characters))
  }

  /// True when this physical key is the hyper hold key. A chord atom matches
  /// with its modifiers. An unmodified named key still matches on key-up,
  /// when the event may carry no characters. Shift-Space is still Space.
  ///
  /// Every NORMAL key and every swallowed release asks this. The matcher's
  /// prepared chord and characters settle the common miss without building
  /// the event's atoms; only a key that can match runs the full test.
  static func isHyperKey(
    matcher: HyperKeyMatcher,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    let physicalMatch = matcher.chord.map { $0.key == CGKeyCode(keyCode) } ?? false
    if !physicalMatch, matcher.chord != nil {
      guard !matcher.characters.isEmpty else { return false }
      let typed = firstCharacter(charactersIgnoringModifiers) ?? firstCharacter(characters)
      guard let typed, matcher.characters.contains(typed) else { return false }
    }
    return isHyperKey(
      atom: matcher.atom,
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers)
  }

  /// The full, layout-aware test behind `isHyperKey(matcher:)`.
  static func isHyperKey(
    atom: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    if eventKeyAtoms(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    ).contains(atom) {
      return true
    }
    return isLeaderKey(
      atom: atom,
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers)
  }

  /// True when this physical key is the configured leader and is not part of
  /// a Command/Control/Option chord. Shift is allowed: Shift-Space is still
  /// Space. Key-up events sometimes carry no characters; named keys still
  /// match by virtual key code.
  static func isLeaderKey(
    atom: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    if independent.contains(.command) || independent.contains(.control)
      || independent.contains(.option)
    {
      return false
    }
    if eventKeyAtoms(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    ).contains(atom) {
      return true
    }
    return namedKeyAtom(keyCode: keyCode) == atom
  }

  /// The atom a named (non-typeable) key is mapped by: Return (and keypad
  /// Enter), Tab, Space, Delete, Forward Delete, Escape, the arrows, Home,
  /// End, Page Up / Down and the function keys, spelled as
  /// `HotkeySyntax.canonicalKeyName` spells them and as `<name>` in a
  /// mapping canonicalizes (`KeySyntax.translateNamedKey`). Nil for every
  /// typeable key: those match by the character the layout produces, never
  /// by a US-ANSI position.
  /// Escape's atom, as a mapping spells it (`<esc>`).
  static let escapeKeyAtom = canonicalizeMappingKey("<escape>") ?? "escape"

  static func namedKeyAtom(keyCode: UInt16) -> String? {
    HotkeySyntax.namedKeyAtom(virtualKey: UInt32(keyCode))
  }

  private static func mappingKeys(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    hasControl: Bool,
    hasShift: Bool,
    ignoredChar: Character?,
    actualChar: Character?
  ) -> [String] {
    let modified = modifiedKeyAtom(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      ignoredChar: ignoredChar)
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    if let modified,
      independent.contains(.command) || independent.contains(.option)
        || independent.contains(.control)
    {
      return [modified]
    }
    if hasControl {
      // Prefer `charactersIgnoringModifiers` when it gives a real
      // letter/digit, since it's keyboard-layout-aware. Fall back to
      // the keyCode for control combos that surface as ASCII control
      // characters (Ctrl+I → HT/\t, Ctrl+O → SI, Ctrl+M → CR) so
      // bindings like `ctrl-i`/`ctrl-o` still match.
      if let ignoredChar, ignoredChar.isASCII,
        ignoredChar.isLetter || ignoredChar.isNumber
      {
        return ["ctrl-\(ignoredChar)"]
      }
      if let letter = KeyboardLayout.usANSILetterOrDigit(keyCode) {
        return ["ctrl-\(letter)"]
      }
      return []
    }
    var keys: [String] = []
    if let actualChar {
      keys.append(String(actualChar))
    }
    if hasShift, ignoredChar == "/", !keys.contains("?") {
      keys.append("?")
    }
    if keys.isEmpty, let ignoredChar {
      keys.append(String(ignoredChar))
    }
    // A shifted named key is its own binding first (`shift+<f1>` beside
    // `<f1>`); without one it still matches as the key itself, as
    // Shift-Space is Space.
    if let modified, !keys.contains(modified) {
      keys.append(modified)
    }
    // A named key matches by its one atom, so `<return>` drops a drag and
    // `<esc>` cancels it whatever character the event carries.
    if let named = namedKeyAtom(keyCode: keyCode), !keys.contains(named) {
      keys.append(named)
    }
    return keys
  }

  private static func modifiedKeyAtom(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    ignoredChar: Character?
  ) -> String? {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: [String] = []
    if independent.contains(.command) { modifiers.append("cmd") }
    if independent.contains(.control) { modifiers.append("ctrl") }
    if independent.contains(.option) { modifiers.append("alt") }
    if independent.contains(.shift) { modifiers.append("shift") }
    guard !modifiers.isEmpty else { return nil }

    // Keep the historical layout-aware spelling for plain Ctrl+letter/digit
    // (`ctrl-i`, not `ctrl+i`). Other modified chords are Carbon-style
    // physical-key chords and use HotkeySyntax's ANSI key names.
    if modifiers == ["ctrl"] {
      if let ignoredChar, ignoredChar.isASCII,
        ignoredChar.isLetter || ignoredChar.isNumber
      {
        return NormalModeInterpreter.canonicalModifiedKeyAtom(
          modifiers: modifiers,
          key: String(ignoredChar))
      }
      if let letter = KeyboardLayout.usANSILetterOrDigit(keyCode) {
        return NormalModeInterpreter.canonicalModifiedKeyAtom(
          modifiers: modifiers,
          key: String(letter))
      }
    }
    // A shifted letter is the letter that key types. Layout arrows name the
    // physical QWERTY position by that letter, and both an input source and
    // a key-code remapper report it. The key code's ANSI name is a different
    // key once the layout has moved the letter.
    if modifiers == ["shift"], let ignoredChar, ignoredChar.isLetter {
      return NormalModeInterpreter.canonicalModifiedKeyAtom(
        modifiers: modifiers,
        key: String(ignoredChar))
    }
    guard let key = HotkeySyntax.canonicalKeyName(virtualKey: UInt32(keyCode)) else {
      return nil
    }
    return NormalModeInterpreter.canonicalModifiedKeyAtom(modifiers: modifiers, key: key)
  }

}

enum NormalModeDispatcher {
  static var scrollStepPixels: Int32 { FlashTunables.scrollStepPixels }

  enum ScrollKind: Hashable {
    case left
    case right
    case up
    case down
    /// One wheel line, whatever `scroll_step_lines` says: Vim's `ctrl+e` /
    /// `ctrl+y`.
    case lineUp
    case lineDown
    case halfPageUp
    case halfPageDown
    /// A full page: twice the half page, on the same wheel path.
    case pageUp
    case pageDown
    case top
    case bottom
  }

  static func role(of element: AXUIElement) -> String? {
    AXAttribute.role(element)
  }

  static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    AXAttribute.string(element, name)
  }

  static func numberAttribute(_ element: AXUIElement, _ name: String) -> Double? {
    AXAttribute.number(element, name)
  }

  static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    AXAttribute.bool(element, name)
  }

  /// Like `AXAttribute.url` but rejects empty/whitespace-only strings,
  /// which is the AX behaviour callers in this file rely on. Provider
  /// callers tolerate empty strings, so they use `AXAttribute.url`
  /// directly.
  static func urlAttribute(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = AXAttribute.url(element, name) else { return nil }
    return value.trimmed.isEmpty ? nil : value
  }

  static func frame(
    of element: AXUIElement,
    primaryScreenHeight screenH: CGFloat
  ) -> CGRect? {
    guard
      let origin = pointAttribute(element, kAXPositionAttribute as String),
      let size = sizeAttribute(element, kAXSizeAttribute as String),
      size.width > 0,
      size.height > 0
    else { return nil }
    return ScreenRect<AXSpace>(CGRect(origin: origin, size: size)).toNS(primaryHeight: screenH)
      .cgRect
  }

  static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    AXAttribute.point(element, name)
  }

  static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    AXAttribute.size(element, name)
  }

  static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    AXAttribute.element(element, name)
  }

  static func children(of element: AXUIElement) -> [AXUIElement] {
    AXAttribute.children(element)
  }

}

extension String {
  mutating func removeLeadingWhitespace() {
    while let firstChar = first, firstChar.isWhitespace {
      removeFirst()
    }
  }
}
