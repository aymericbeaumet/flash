import AppKit

enum OverlayKeyAction: Equatable {
  case cancel
  case backspace
  case commit(String, ClickModifiers)
  case ignore
}

enum OverlayInputMode {
  case hints
  case normal
  case commandLine
  case help
  case appFinder
}

enum OverlayInputInterpreter {
  static func action(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?,
    magicModifiers: ClickModifiers = .defaultMagic
  ) -> OverlayKeyAction {
    switch keyCode {
    case 49,  // space
      53,  // escape
      123, 124, 125, 126:  // arrow_left/right/down/up
      return .cancel
    default:
      break
    }

    let independentModifiers =
      modifierFlags
      .intersection(.deviceIndependentFlagsMask)
    let strictModifiers = independentModifiers.intersection([.command, .control, .option])
    let requestedStrictModifiers = ClickModifiers(eventFlags: strictModifiers)
    if !magicModifiers.isSuperset(of: requestedStrictModifiers) {
      return .cancel
    }

    if keyCode == 51 {
      if !strictModifiers.isEmpty {
        return .cancel
      }
      return .backspace
    }

    guard let chars = charactersIgnoringModifiers, !chars.isEmpty else {
      return .ignore
    }
    let clickModifiers = ClickModifiers(eventFlags: independentModifiers, allowed: magicModifiers)
    return .commit(chars, clickModifiers)
  }
}

/// Hint typing lives in a custom NSPanel subclass so character input is
/// strictly scoped to the overlay window; native modified-key mappings
/// are handled separately by the explicit `[mode.*]` Carbon registry.
extension OverlayPanel {
  override func keyDown(with event: NSEvent) {
    if !handleOverlayKeyEvent(event) {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if inputMode == .normal {
      return handleOverlayKeyEvent(event, swallowIgnored: true)
    }

    if inputMode == .commandLine {
      return handleCommandLineKeyEvent(event)
    }
    if inputMode == .help {
      return handleHelpKeyEvent(event)
    }
    if inputMode == .appFinder {
      return handleAppFinderKeyEvent(event)
    }

    if coordinator?.overlayDidHandleMapping(event) == true {
      return true
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard
      modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control)
    else {
      return super.performKeyEquivalent(with: event)
    }
    return handleOverlayKeyEvent(event, swallowIgnored: modifiers.contains(.command))
  }

  @discardableResult
  private func handleOverlayKeyEvent(_ event: NSEvent, swallowIgnored: Bool = false) -> Bool {
    guard let coordinator = coordinator else { return false }
    if inputMode == .normal {
      let transition = NormalModeInterpreter.interpret(
        pending: normalModePending,
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        characters: event.characters,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        mappings: normalModeMappings)
      FlashLog.trace(
        "[input] normal key=\(event.keyCode) chars=\(event.characters ?? "nil") "
          + "ignoring=\(event.charactersIgnoringModifiers ?? "nil") pending_before=\(normalModePending) "
          + "pending_after=\(transition.pending) command=\(transition.command?.diagnosticDescription ?? "nil") "
          + "repeat=\(transition.repeatCount) pass_through=\(transition.passThrough)")
      if transition.passThrough { return true }
      normalModePending = transition.pending
      coordinator.overlayDidHandleNormalMode(
        transition.command,
        repeatCount: transition.repeatCount)
      return true
    }

    if inputMode == .commandLine {
      return handleCommandLineKeyEvent(event)
    }
    if inputMode == .help {
      return handleHelpKeyEvent(event)
    }
    if inputMode == .appFinder {
      return handleAppFinderKeyEvent(event)
    }

    if coordinator.overlayDidHandleMapping(event) {
      return true
    }

    // Hardcoded dismissal keys. Not configurable on purpose: arrows /
    // space / escape are common "abort what I was about to do" signals
    // in every macOS app, and matching that intuition keeps the
    // overlay out of the user's way. Scrolling is handled separately
    // by a global event monitor (see OverlayPanel.installScrollMonitor).
    switch OverlayInputInterpreter.action(
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      magicModifiers: magicModifiers)
    {
    case .cancel:
      coordinator.overlayDidCancel()
      return true
    case .backspace:
      coordinator.overlayDidUpdatePrefix("__BACKSPACE__")
      return true
    case .commit(let chars, let clickModifiers):
      coordinator.overlayDidCommit(prefix: chars, clickModifiers: clickModifiers)
      return true
    case .ignore:
      return swallowIgnored
    }
  }

  @discardableResult
  private func handleCommandLineKeyEvent(_ event: NSEvent) -> Bool {
    guard let coordinator = coordinator else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first
    if modifiers.contains(.control), ignoredChar == "c" {
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=ctrl-c")
      coordinator.overlayDidCancelCommandLine()
      return true
    }

    if modifiers.contains(.control) {
      switch ignoredChar {
      case "a":
        moveCommandLineCursor(to: 0)
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
        return true
      case "e":
        moveCommandLineCursor(to: commandLineText.count)
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
        return true
      case "b":
        moveCommandLineCursor(by: -1)
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
        return true
      case "f":
        moveCommandLineCursor(by: 1)
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
        return true
      case "d":
        deleteCommandLineForward()
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
        return true
      case "k":
        deleteCommandLineToEnd()
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
        return true
      case "u":
        commandLineText = ""
        commandLineCursorIndex = 0
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
        return true
      default:
        break
      }
    }

    switch event.keyCode {
    case 48:  // tab
      let delta = modifiers.contains(.shift) ? -1 : 1
      _ = coordinator.overlayDidMoveCommandLineSelection(delta)
      return true
    case 115:  // home
      moveCommandLineCursor(to: 0)
      coordinator.overlayDidUpdateCommandLine(
        commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
      return true
    case 119:  // end
      moveCommandLineCursor(to: commandLineText.count)
      coordinator.overlayDidUpdateCommandLine(
        commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
      return true
    case 123:  // left
      if modifiers.contains(.option) {
        moveCommandLineCursorToPreviousWord()
      } else if modifiers.contains(.command) {
        moveCommandLineCursor(to: 0)
      } else {
        moveCommandLineCursor(by: -1)
      }
      coordinator.overlayDidUpdateCommandLine(
        commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
      return true
    case 124:  // right
      if modifiers.contains(.option) {
        moveCommandLineCursorToNextWord()
      } else if modifiers.contains(.command) {
        moveCommandLineCursor(to: commandLineText.count)
      } else {
        moveCommandLineCursor(by: 1)
      }
      coordinator.overlayDidUpdateCommandLine(
        commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
      return true
    case 125:  // down
      _ = coordinator.overlayDidMoveCommandLineSelection(-1)
      return true
    case 126:  // up
      _ = coordinator.overlayDidMoveCommandLineSelection(1)
      return true
    case 53:  // escape
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=escape")
      coordinator.overlayDidCancelCommandLine()
      return true
    case 36, 76:  // return / keypad enter
      let command = commandLineText
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line submit command=\(command)")
      coordinator.overlayDidSubmitCommandLine(command)
      return true
    case 51:  // delete
      if deleteCommandLineBackward() {
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
      } else if commandLineText.isEmpty {
      coordinator.overlayDidCancelCommandLine()
      }
      return true
    case 117:  // forward delete
      if deleteCommandLineForward() {
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
      } else {
        coordinator.overlayDidUpdateCommandLine(
          commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: false)
      }
      return true
    default:
      break
    }

    if !modifiers.intersection([.command, .control, .option]).isEmpty {
      return true
    }
    guard let chars = event.characters, !chars.isEmpty else { return true }
    insertCommandLineText(String(chars.filter { !$0.isNewline }))
    FlashLog.trace("[input] command_line edit text=\(commandLineText) cursor=\(commandLineCursorIndex)")
    coordinator.overlayDidUpdateCommandLine(
      commandLineText, cursorIndex: commandLineCursorIndex, resetSelection: true)
    return true
  }

  @discardableResult
  private func handleHelpKeyEvent(_ event: NSEvent) -> Bool {
    guard let coordinator = coordinator else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first
    if event.keyCode == 53 || (modifiers.contains(.control) && ignoredChar == "c") {
      FlashLog.trace("[input] help cancel key=\(event.keyCode)")
      coordinator.overlayDidCancelHelp()
    }
    return true
  }

  @discardableResult
  private func handleAppFinderKeyEvent(_ event: NSEvent) -> Bool {
    guard let coordinator = coordinator else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first
    if event.keyCode == 53 || (modifiers.contains(.control) && ignoredChar == "c") {
      appFinderQuery = ""
      FlashLog.trace("[input] app_finder cancel key=\(event.keyCode)")
      coordinator.overlayDidCancelAppFinder()
      return true
    }
    if modifiers.contains(.control) {
      switch ignoredChar {
      case "n":
        coordinator.overlayDidMoveAppFinderSelection(-1)
        return true
      case "p":
        coordinator.overlayDidMoveAppFinderSelection(1)
        return true
      default:
        return true
      }
    }

    switch event.keyCode {
    case 36, 76:  // return / keypad enter
      coordinator.overlayDidSubmitAppFinder()
      return true
    case 51:  // delete
      if !appFinderQuery.isEmpty {
        appFinderQuery.removeLast()
        coordinator.overlayDidUpdateAppFinderQuery(appFinderQuery)
      }
      return true
    case 125:  // down
      coordinator.overlayDidMoveAppFinderSelection(-1)
      return true
    case 126:  // up
      coordinator.overlayDidMoveAppFinderSelection(1)
      return true
    default:
      break
    }

    if !modifiers.intersection([.command, .control, .option]).isEmpty {
      return true
    }
    guard let chars = event.characters, !chars.isEmpty else { return true }
    appFinderQuery.append(contentsOf: chars.filter { !$0.isNewline })
    FlashLog.trace("[input] app_finder query=\(appFinderQuery)")
    coordinator.overlayDidUpdateAppFinderQuery(appFinderQuery)
    return true
  }

  private func moveCommandLineCursor(by delta: Int) {
    moveCommandLineCursor(to: commandLineCursorIndex + delta)
  }

  private func moveCommandLineCursor(to index: Int) {
    commandLineCursorIndex = min(max(index, 0), commandLineText.count)
  }

  private func insertCommandLineText(_ text: String) {
    guard !text.isEmpty else { return }
    let index = commandLineStringIndex(at: commandLineCursorIndex)
    commandLineText.insert(contentsOf: text, at: index)
    commandLineCursorIndex += text.count
  }

  @discardableResult
  private func deleteCommandLineBackward() -> Bool {
    guard commandLineCursorIndex > 0 else { return false }
    let end = commandLineStringIndex(at: commandLineCursorIndex)
    let start = commandLineText.index(before: end)
    commandLineText.removeSubrange(start..<end)
    commandLineCursorIndex -= 1
    return true
  }

  @discardableResult
  private func deleteCommandLineForward() -> Bool {
    guard commandLineCursorIndex < commandLineText.count else { return false }
    let start = commandLineStringIndex(at: commandLineCursorIndex)
    let end = commandLineText.index(after: start)
    commandLineText.removeSubrange(start..<end)
    return true
  }

  private func deleteCommandLineToEnd() {
    guard commandLineCursorIndex < commandLineText.count else { return }
    let start = commandLineStringIndex(at: commandLineCursorIndex)
    commandLineText.removeSubrange(start..<commandLineText.endIndex)
  }

  private func moveCommandLineCursorToPreviousWord() {
    guard commandLineCursorIndex > 0 else { return }
    var index = commandLineCursorIndex
    while index > 0, commandLineCharacter(before: index)?.isWhitespace == true {
      index -= 1
    }
    while index > 0, commandLineCharacter(before: index)?.isWhitespace == false {
      index -= 1
    }
    moveCommandLineCursor(to: index)
  }

  private func moveCommandLineCursorToNextWord() {
    guard commandLineCursorIndex < commandLineText.count else { return }
    var index = commandLineCursorIndex
    while index < commandLineText.count, commandLineCharacter(at: index)?.isWhitespace == false {
      index += 1
    }
    while index < commandLineText.count, commandLineCharacter(at: index)?.isWhitespace == true {
      index += 1
    }
    moveCommandLineCursor(to: index)
  }

  private func commandLineCharacter(at offset: Int) -> Character? {
    guard offset >= 0, offset < commandLineText.count else { return nil }
    return commandLineText[commandLineStringIndex(at: offset)]
  }

  private func commandLineCharacter(before offset: Int) -> Character? {
    guard offset > 0 else { return nil }
    return commandLineText[commandLineStringIndex(at: offset - 1)]
  }

  private func commandLineStringIndex(at offset: Int) -> String.Index {
    commandLineText.index(
      commandLineText.startIndex,
      offsetBy: min(max(offset, 0), commandLineText.count))
  }
}
