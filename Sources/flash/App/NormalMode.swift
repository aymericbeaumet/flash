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
      repeatCount: max(1, repeatCount),
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

enum NormalModeInterpreter {
  private static let maxRepeatCount = 999
  static let sequenceTimeoutMs = 1000

  private struct PendingState {
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
      count: Int? = nil,
      prefix: String,
      register: String? = nil,
      awaitingRegister: Bool = false
    ) {
      self.count = count
      self.prefix = prefix
      self.register = register
      self.awaitingRegister = awaitingRegister
    }

    var repeatCount: Int { count ?? 1 }

    /// Serialize back into the opaque `pending` string. The register part
    /// leads (`"` alone while awaiting, `"a` once named) so a register name
    /// that is itself a digit can't be mistaken for a repeat count. The count
    /// follows, then the encoded key-atom prefix.
    var encoded: String {
      let registerPart: String
      if awaitingRegister {
        registerPart = "\""
      } else if let register {
        registerPart = "\"" + register
      } else {
        registerPart = ""
      }
      return "\(registerPart)\(count.map(String.init) ?? "")\(prefix)"
    }

    func appendingPrefix(_ next: String) -> String {
      PendingState(count: count, prefix: next, register: register).encoded
    }
  }

  static func interpret(
    pending: String,
    repeatAnchor: String? = nil,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: CompiledMappings
  ) -> NormalModeTransition {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    if keyCode == 53 { return .consume }

    let hasControl = independent.contains(.control)
    let ignoredChar = firstCharacter(charactersIgnoringModifiers)?.lowercased().first
    let actualChar = firstCharacter(characters)
    let state = pendingState(pending)
    let keys = mappingKeys(
      keyCode: keyCode,
      modifierFlags: independent,
      hasControl: hasControl,
      hasShift: independent.contains(.shift),
      ignoredChar: ignoredChar,
      actualChar: actualChar)

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

    // A bare `"` parked us waiting for a register name. Consume this key as
    // that name. An invalid name (escape is handled above; arrows, chords,
    // …) abandons the register prefix and re-interprets the key from scratch
    // so it isn't silently swallowed.
    if state.awaitingRegister {
      if let name = actualChar, isRegisterNameChar(name) {
        return .pending(PendingState(prefix: "", register: String(name)).encoded)
      }
      return interpret(
        pending: "",
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: mappings)
    }

    if state.prefix.isEmpty, let digit = digitValue(ignoredChar) {
      if state.count == nil, digit == 0 {
        return .consume
      }
      let next = min(((state.count ?? 0) * 10) + digit, maxRepeatCount)
      return .pending(
        PendingState(count: next, prefix: "", register: state.register).encoded)
    }

    // `"` starts a register prefix (Vim's `"<reg>`), but only when it's at the
    // head of a fresh command and the user hasn't bound `"` to something else.
    // Count-before-register (`3"a…`) is intentionally unsupported so the
    // encoding stays unambiguous; register-then-count (`"a3…`) works.
    if state.prefix.isEmpty, state.register == nil, state.count == nil,
      actualChar == "\"",
      mappings.mapping(for: "\"") == nil, !mappings.hasStrictPrefix("\"")
    {
      return .pending(PendingState(prefix: "", awaitingRegister: true).encoded)
    }

    guard !keys.isEmpty else {
      return .consume
    }
    for key in keys {
      let sequence = appendKeyAtom(state.prefix, key)
      let exact = mappings.mapping(for: sequence)
      let hasLonger = mappings.hasStrictPrefix(sequence)
      if let mapping = exact, !hasLonger {
        return .action(
          applyingRegister(state.register, to: mapping.action),
          repeatCount: state.repeatCount,
          repeatAnchor: mapping.repeatsOnFinalKey ? mapping.key : nil)
      }
      if exact != nil || hasLonger {
        return .pending(state.appendingPrefix(sequence))
      }
    }
    // The new key can't extend the pending sequence to anything
    // mapped. If we have a pending prefix, drop it and re-interpret
    // the key from scratch — matches Vim's fallback when a multi-key
    // sequence is broken by an unmappable continuation. Without this,
    // pressing `g` and then `i` would silently swallow the `i`
    // instead of entering insert mode (no `gi` mapping, no `gi…`
    // extension, so the for-loop falls through and the new key is
    // lost). The recursion bottoms out immediately: the recursive
    // call passes an empty `pending`, so it can't re-enter this
    // branch.
    if !state.prefix.isEmpty {
      return interpret(
        pending: "",
        repeatAnchor: nil,
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: mappings)
    }
    // The interpreter's fallback is always consume. The keyboard tap decides
    // before this point whether an unmapped modified chord should instead pass
    // through and move Flash to INSERT; when that config is disabled, this
    // keeps NORMAL hermetic.
    return .consume
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
    return PendingNormalModeCommand(
      action: applyingRegister(state.register, to: mapping.action),
      repeatCount: state.repeatCount,
      repeatAnchor: mapping.repeatsOnFinalKey ? mapping.key : nil)
  }

  /// Fast raw-event recognition for the keyboard tap's passthrough decision.
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
    let keys = mappings.physicalKeyAtoms(virtualKey: virtualKey, cgFlags: modifierFlags)
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

  /// Bake a captured register into a yank/paste action. The register only
  /// modifies clipboard operators; for every other command (and when no
  /// register was typed) the action passes through unchanged — Vim likewise
  /// ignores a register prefix on commands that don't read one.
  static func applyingRegister(_ register: String?, to action: MappingCommand) -> MappingCommand {
    guard let register, case .flashCommand(let command) = action else { return action }
    switch command {
    case .yankSelection:
      return .flashCommand(.yankSelection(register: register))
    case .paste:
      return .flashCommand(.paste(register: register))
    default:
      return action
    }
  }

  /// Characters accepted as a `"<name>` register: letters (uppercase appends),
  /// digits, and the system-clipboard synonyms `+` / `*` / `"`.
  static func isRegisterNameChar(_ ch: Character) -> Bool {
    if ch == "+" || ch == "*" || ch == "\"" { return true }
    guard ch.isASCII else { return false }
    return ch.isLetter || ch.isNumber
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
    // Decode the leading register part (`"` alone, or `"` + one name char),
    // mirroring `PendingState.encoded`.
    var rest = Substring(pending)
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
    let prefix = String(rest.dropFirst(digitPrefix.count))
    let count = digitPrefix.isEmpty ? nil : Int(digitPrefix).map { min($0, maxRepeatCount) }
    return PendingState(
      count: count, prefix: prefix, register: register, awaitingRegister: awaitingRegister)
  }

  private static func digitValue(_ char: Character?) -> Int? {
    guard let char, let value = char.wholeNumberValue, value >= 0, value <= 9 else {
      return nil
    }
    return value
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
      if let letter = keyCodeLetter(keyCode) {
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
    switch Int(keyCode) {
    case kVK_Space:
      if !keys.contains("space") { keys.append("space") }
    case kVK_Tab:
      if !keys.contains("tab") { keys.append("tab") }
    case kVK_ForwardDelete:
      for alias in ["delete_forward", "forward_delete"] where !keys.contains(alias) {
        keys.append(alias)
      }
    default:
      break
    }
    if let modified, !keys.contains(modified) {
      keys.append(modified)
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
      if let letter = keyCodeLetter(keyCode) {
        return NormalModeInterpreter.canonicalModifiedKeyAtom(
          modifiers: modifiers,
          key: String(letter))
      }
    }
    guard let key = HotkeySyntax.canonicalKeyName(virtualKey: UInt32(keyCode)) else {
      return nil
    }
    return NormalModeInterpreter.canonicalModifiedKeyAtom(modifiers: modifiers, key: key)
  }

  /// Map a hardware keyCode to the lowercase ASCII letter/digit it
  /// represents on a US-ANSI keyboard layout. Used to recover the key
  /// identity when `charactersIgnoringModifiers` is unusable (e.g.,
  /// Ctrl+I returning the HT control character).
  private static func keyCodeLetter(_ keyCode: UInt16) -> Character? {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "a"
    case kVK_ANSI_B: return "b"
    case kVK_ANSI_C: return "c"
    case kVK_ANSI_D: return "d"
    case kVK_ANSI_E: return "e"
    case kVK_ANSI_F: return "f"
    case kVK_ANSI_G: return "g"
    case kVK_ANSI_H: return "h"
    case kVK_ANSI_I: return "i"
    case kVK_ANSI_J: return "j"
    case kVK_ANSI_K: return "k"
    case kVK_ANSI_L: return "l"
    case kVK_ANSI_M: return "m"
    case kVK_ANSI_N: return "n"
    case kVK_ANSI_O: return "o"
    case kVK_ANSI_P: return "p"
    case kVK_ANSI_Q: return "q"
    case kVK_ANSI_R: return "r"
    case kVK_ANSI_S: return "s"
    case kVK_ANSI_T: return "t"
    case kVK_ANSI_U: return "u"
    case kVK_ANSI_V: return "v"
    case kVK_ANSI_W: return "w"
    case kVK_ANSI_X: return "x"
    case kVK_ANSI_Y: return "y"
    case kVK_ANSI_Z: return "z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    default: return nil
    }
  }

}

enum NormalModeDispatcher {
  static let scrollStepPixels: Int32 = 60

  enum ScrollKind: Hashable {
    case left
    case right
    case up
    case down
    case halfPageUp
    case halfPageDown
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
    return CGRect(
      x: origin.x,
      y: screenH - origin.y - size.height,
      width: size.width,
      height: size.height)
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
