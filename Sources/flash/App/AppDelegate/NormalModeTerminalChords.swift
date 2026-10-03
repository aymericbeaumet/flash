import Carbon.HIToolbox
import CoreGraphics
import FlashCore

// The terminal rule: the one place NORMAL names keys of its own. It decides
// whether a chord is safe to synthesize into a terminal emulator, never which
// chord an action sends — that is plugin data (`action_bindings`).

extension AppDelegate {
  /// Command chords every macOS terminal emulator binds. A terminal that does
  /// NOT bind a Command chord does not ignore it: its key encoder falls
  /// through to the plain text path and writes the chord's base character to
  /// the pty, so an unbound `cmd+g` types a literal `g` into the shell. That
  /// is true of a hardware chord too — the emulator, not the synthesis, is
  /// what turns it into text. NORMAL is hermetic, so a mapping that would
  /// resolve to a chord outside this set does nothing in a terminal instead.
  private static let terminalBoundCommandChords: Set<CGKeyCode> = [
    CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_ANSI_W),
    CGKeyCode(kVK_ANSI_T), CGKeyCode(kVK_ANSI_N), CGKeyCode(kVK_ANSI_Q),
    CGKeyCode(kVK_ANSI_F),
    CGKeyCode(kVK_ANSI_1), CGKeyCode(kVK_ANSI_2), CGKeyCode(kVK_ANSI_3),
    CGKeyCode(kVK_ANSI_4), CGKeyCode(kVK_ANSI_5), CGKeyCode(kVK_ANSI_6),
    CGKeyCode(kVK_ANSI_7), CGKeyCode(kVK_ANSI_8), CGKeyCode(kVK_ANSI_9),
  ]

  /// Whether synthesizing `key`+`flags` into a terminal would type a
  /// character instead of running a shortcut. Shift-bracket is the macOS
  /// standard tab traversal and every emulator binds it, as it binds
  /// `terminalBoundCommandChords`; any other Command chord is safe only where
  /// a plugin binds it for that emulator in `action_bindings` (split
  /// traversal on the bare brackets, for one). `isDeclared` is asked last.
  static func commandChordTypesTextInTerminal(
    key: CGKeyCode,
    flags: CGEventFlags,
    isDeclared: () -> Bool
  ) -> Bool {
    let modifiers = flags.intersection(normalModeKeyModifierMask)
    guard modifiers.contains(.maskCommand) else { return false }
    let bracket = key == CGKeyCode(kVK_ANSI_LeftBracket) || key == CGKeyCode(kVK_ANSI_RightBracket)
    let boundEverywhere =
      bracket
      ? modifiers == [.maskCommand, .maskShift]
      : modifiers.subtracting([.maskCommand, .maskShift]).isEmpty
        && terminalBoundCommandChords.contains(key)
    return !boundEverywhere && !isDeclared()
  }

  /// `commandChordTypesTextInTerminal` for the app `bundleIdentifier`; any app
  /// but a terminal emulator ignores a Command chord it doesn't bind.
  func commandChordTypesText(
    key: CGKeyCode, flags: CGEventFlags, bundleIdentifier: String
  ) -> Bool {
    guard TerminalEmulators.contains(bundleIdentifier) else { return false }
    return Self.commandChordTypesTextInTerminal(key: key, flags: flags) {
      pluginManager.declaresActionBinding(
        key: key, flags: flags.intersection(Self.normalModeKeyModifierMask),
        in: PluginSelectorContext(bundleID: bundleIdentifier))
    }
  }

}
