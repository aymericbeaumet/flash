import AppKit

enum OverlayKeyAction: Equatable {
  case cancel
  case backspace
  case commit(String, ClickModifiers)
  case ignore
}

enum OverlayInputMode: Equatable {
  case hints
  case normal
  case commandLine
  case help
  case candidateFinder
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
    if inputMode == .commandLine {
      super.keyDown(with: event)
      return
    }
    if !handleOverlayKeyEvent(event) {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if inputMode == .normal {
      return handleOverlayKeyEvent(event, swallowIgnored: true)
    }

    if inputMode == .commandLine { return super.performKeyEquivalent(with: event) }
    if inputMode == .help {
      return handleHelpKeyEvent(event)
    }
    if inputMode == .candidateFinder {
      return handleCandidateFinderKeyEvent(event)
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
      let now = Date()
      let pendingBeforeTimeout = normalModePending
      if NormalModeInterpreter.pendingSequenceTimedOut(
        pending: normalModePending,
        lastInputAt: normalModePendingUpdatedAt,
        now: now)
      {
        FlashLog.trace(
          "[input] normal pending_timeout pending=\(normalModePending) "
            + "timeout_ms=\(NormalModeInterpreter.sequenceTimeoutMs)")
        normalModePending = ""
      }
      let transition = NormalModeInterpreter.interpret(
        pending: normalModePending,
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        characters: event.characters,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        mappings: normalModeMappings)
      FlashLog.trace(
        "[input] normal key=\(event.keyCode) chars=\(event.characters ?? "nil") "
          + "ignoring=\(event.charactersIgnoringModifiers ?? "nil") pending_before=\(pendingBeforeTimeout) "
          + "pending_after=\(transition.pending) action=\(transition.action?.diagnosticDescription ?? "nil") "
          + "repeat=\(transition.repeatCount) pass_through=\(transition.passThrough)")
      if transition.passThrough { return true }
      normalModePending = transition.pending
      if !transition.pending.isEmpty {
        normalModePendingUpdatedAt = now
      }
      coordinator.overlayDidHandleNormalMode(
        transition.action,
        repeatCount: transition.repeatCount)
      return true
    }

    if inputMode == .commandLine { return false }
    if inputMode == .help {
      return handleHelpKeyEvent(event)
    }
    if inputMode == .candidateFinder {
      return handleCandidateFinderKeyEvent(event)
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
  private func handleCandidateFinderKeyEvent(_ event: NSEvent) -> Bool {
    guard let coordinator = coordinator else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first
    if event.keyCode == 53 || (modifiers.contains(.control) && ignoredChar == "c") {
      candidateFinderQuery = ""
      FlashLog.trace("[input] candidate_finder cancel key=\(event.keyCode)")
      coordinator.overlayDidCancelCandidateFinder()
      return true
    }
    if modifiers.contains(.control) {
      switch ignoredChar {
      case "n":
        coordinator.overlayDidMoveCandidateFinderSelection(-1)
        return true
      case "p":
        coordinator.overlayDidMoveCandidateFinderSelection(1)
        return true
      default:
        return true
      }
    }

    switch event.keyCode {
    case 36, 76:  // return / keypad enter
      coordinator.overlayDidSubmitCandidateFinder()
      return true
    case 51:  // delete
      if !candidateFinderQuery.isEmpty {
        candidateFinderQuery.removeLast()
        coordinator.overlayDidUpdateCandidateFinderQuery(candidateFinderQuery)
      }
      return true
    case 125:  // down
      coordinator.overlayDidMoveCandidateFinderSelection(-1)
      return true
    case 126:  // up
      coordinator.overlayDidMoveCandidateFinderSelection(1)
      return true
    default:
      break
    }

    if !modifiers.intersection([.command, .control, .option]).isEmpty {
      return true
    }
    guard let chars = event.characters, !chars.isEmpty else { return true }
    candidateFinderQuery.append(contentsOf: chars.filter { !$0.isNewline })
    FlashLog.trace("[input] candidate_finder query=\(candidateFinderQuery)")
    coordinator.overlayDidUpdateCandidateFinderQuery(candidateFinderQuery)
    return true
  }
}
