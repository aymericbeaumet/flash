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

  var command: URLCommand? { action?.command }

  static func command(_ command: URLCommand, repeatCount: Int = 1) -> NormalModeTransition {
    action(.flashCommand(command), repeatCount: repeatCount)
  }

  static func action(_ action: MappingCommand, repeatCount: Int = 1) -> NormalModeTransition {
    NormalModeTransition(
      pending: "", action: action, repeatCount: max(1, repeatCount))
  }

  static func pending(_ pending: String) -> NormalModeTransition {
    NormalModeTransition(pending: pending, action: nil, repeatCount: 1)
  }

  static let consume = NormalModeTransition(
    pending: "", action: nil, repeatCount: 1)
}

struct PendingNormalModeCommand: Equatable {
  var action: MappingCommand
  var repeatCount: Int

  var command: URLCommand? { action.command }
}

enum NormalModeInterpreter {
  private static let maxRepeatCount = 999
  static let sequenceTimeoutMs = 1000

  private struct PendingState {
    var count: Int?
    var prefix: String

    var repeatCount: Int { count ?? 1 }

    var encoded: String {
      "\(count.map(String.init) ?? "")\(prefix)"
    }

    func appendingPrefix(_ next: String) -> String {
      PendingState(count: count, prefix: next).encoded
    }
  }

  static func interpret(
    pending: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String?,
    charactersIgnoringModifiers: String?,
    mappings: CompiledMappings
  ) -> NormalModeTransition {
    let independent = modifierFlags.intersection(.deviceIndependentFlagsMask)
    if keyCode == 53 { return .consume }

    if let mapping = modifiedMapping(
      keyCode: keyCode,
      modifierFlags: independent,
      mappings: mappings)
    {
      return .action(mapping.action)
    }

    if independent.contains(.command) || independent.contains(.option) {
      // Hermetic normal mode: any Cmd/Opt-prefixed chord without an
      // explicit mapping is swallowed. If the user wants Cmd+W to
      // close a tab, Cmd+L to focus the URL bar, etc., they bind it
      // in `[mode.normal.mappings]`. The previous "forward Cmd+letter
      // to the focused app" path leaked OS shortcuts (Cmd+Tab,
      // Cmd+Shift+T, Cmd+L) through normal mode and silently
      // dropped capture into the underlying window.
      return .consume
    }

    let hasControl = independent.contains(.control)
    let ignoredChar = firstCharacter(charactersIgnoringModifiers)?.lowercased().first
    let actualChar = firstCharacter(characters)
    let state = pendingState(pending)

    if state.prefix.isEmpty, let digit = digitValue(ignoredChar) {
      if state.count == nil, digit == 0 {
        return .consume
      }
      let next = min(((state.count ?? 0) * 10) + digit, maxRepeatCount)
      return .pending(PendingState(count: next, prefix: "").encoded)
    }

    let keys = mappingKeys(
      keyCode: keyCode,
      hasControl: hasControl,
      hasShift: independent.contains(.shift),
      ignoredChar: ignoredChar,
      actualChar: actualChar)
    guard !keys.isEmpty else {
      return .consume
    }
    for key in keys {
      let sequence = state.prefix + key
      let exact = mappings.mapping(for: sequence)
      let hasLonger = mappings.hasStrictPrefix(sequence)
      if let mapping = exact, !hasLonger {
        return .action(mapping.action, repeatCount: state.repeatCount)
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
        keyCode: keyCode,
        modifierFlags: modifierFlags,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        mappings: mappings)
    }
    return .consume
  }

  /// Mapping keys that name a single named keystroke (Tab, Space, the
  /// forward-delete key) rather than a sequence of characters the user
  /// types one at a time. Excluded from the sequence-continuation
  /// search so a `t` keystroke doesn't get stuck waiting for `ab`.
  static let atomicKeyNames: Set<String> = [
    "tab", "space", "delete_forward", "forward_delete",
  ]

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
    return PendingNormalModeCommand(action: mapping.action, repeatCount: state.repeatCount)
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
    let digitPrefix = pending.prefix { ch in
      guard let value = ch.wholeNumberValue else { return false }
      return value >= 0 && value <= 9
    }
    let prefix = String(pending.dropFirst(digitPrefix.count))
    let count = digitPrefix.isEmpty ? nil : Int(digitPrefix).map { min($0, maxRepeatCount) }
    return PendingState(count: count, prefix: prefix)
  }

  private static func digitValue(_ char: Character?) -> Int? {
    guard let char, let value = char.wholeNumberValue, value >= 0, value <= 9 else {
      return nil
    }
    return value
  }

  private static func modifiedMapping(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    mappings: CompiledMappings
  ) -> ModeMapping? {
    let carbonModifiers = Self.carbonModifiers(from: modifierFlags)
    guard carbonModifiers != 0 else { return nil }
    return mappings.chordMapping(modifiers: carbonModifiers, virtualKey: UInt32(keyCode))
  }

  private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    let independent = flags.intersection(.deviceIndependentFlagsMask)
    var out: UInt32 = 0
    if independent.contains(.command) { out |= UInt32(cmdKey) }
    if independent.contains(.shift) { out |= UInt32(shiftKey) }
    if independent.contains(.control) { out |= UInt32(controlKey) }
    if independent.contains(.option) { out |= UInt32(optionKey) }
    return out
  }

  private static func mappingKeys(
    keyCode: UInt16,
    hasControl: Bool,
    hasShift: Bool,
    ignoredChar: Character?,
    actualChar: Character?
  ) -> [String] {
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
    return keys
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
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
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
