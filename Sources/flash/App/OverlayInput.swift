import AppKit

enum OverlayKeyAction: Equatable {
  case cancel
  case backspace
  case commit(String, ClickModifiers)
  /// `<space>` — commit the mouse grid's centre cell (the coordinator
  /// resolves this to a center commit in mouse-grid mode and to a cancel
  /// otherwise).
  case commitCenter(ClickModifiers)
  case ignore
}

enum OverlayInputMode: Equatable {
  case hints
  case normal
  case commandLine
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
    case 53,  // escape
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

    // Click-pass-through: always allow shift to ride the click, even when
    // it has been stripped from `magicModifiers` for input-disambiguation
    // reasons (the auto-strip in `Config.removeAmbiguousShiftMagicModifier`
    // fires when the alphabet contains non-letters like the default
    // `qwerty_toprow` digits, so `shift+1` doesn't fight with `!`). Shift
    // on the synthesized mouse event isn't ambiguous with anything — it
    // simply becomes a shift+click — so the disambiguation rule that
    // makes sense at key-input time would break `f`+shift+hint at click
    // time. Strict modifiers (cmd/ctrl/option) still respect
    // `magicModifiers` so the cancel gate above remains the source of
    // truth for unknown chords.
    let clickAllowed = magicModifiers.union(.shift)
    let clickModifiers = ClickModifiers(eventFlags: independentModifiers, allowed: clickAllowed)

    // `<space>` is the fixed "centre of the grid" key. In mouse-grid mode
    // the coordinator commits the middle cell (always present — the grid
    // is an odd-N square) so the region centre is one keystroke away
    // whatever letter the layout assigned there; outside mouse-grid mode
    // it falls back to a cancel, preserving the universal
    // arrows/space/escape "abort the overlay" gesture. Routed through the
    // same magic-modifier gate above so a stray `cmd+space` can't slip
    // past as a center commit.
    if keyCode == 49 {  // space
      return .commitCenter(clickModifiers)
    }

    guard let chars = charactersIgnoringModifiers, !chars.isEmpty else {
      return .ignore
    }
    return .commit(chars, clickModifiers)
  }
}

/// Hint typing lives in a custom NSPanel subclass so character input is
/// strictly scoped to the overlay window. Normal-mode mappings are interpreted
/// through `processNormalModeKey`; configured modified mappings are handled by
/// the Carbon registry outside the panel.
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

    if inputMode == .commandLine {
      if handleCommandLineEditingShortcut(event) { return true }
      return super.performKeyEquivalent(with: event)
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

  /// Runs one key through the normal-mode interpreter and dispatches the
  /// resulting action while the overlay panel owns keyboard input.
  func processNormalModeKey(_ event: NSEvent) {
    guard let coordinator = coordinator else { return }
    let now = Date()
    let pendingBeforeTimeout = normalModePending
    if NormalModeInterpreter.pendingSequenceTimedOut(
      pending: normalModePending,
      lastInputAt: normalModePendingUpdatedAt,
      now: now,
      timeoutMs: normalModeSequenceTimeoutMs)
    {
      FlashLog.trace(
        "[input] normal pending_timeout pending=\(normalModePending) "
          + "timeout_ms=\(normalModeSequenceTimeoutMs)")
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
        + "repeat=\(transition.repeatCount)")
    normalModePending = transition.pending
    if !transition.pending.isEmpty {
      normalModePendingUpdatedAt = now
    }
    coordinator.overlayDidHandleNormalMode(
      transition.action,
      repeatCount: transition.repeatCount)
  }

  /// Route a key delivered by the global keyboard tap (NORMAL / hints capture
  /// that no longer relies on key-window focus). The tap already decided this
  /// key is ours; here we just dispatch it the same way `keyDown` /
  /// `performKeyEquivalent` would when the panel owned the key event.
  @discardableResult
  func handleTapCapturedKey(_ event: NSEvent) -> Bool {
    switch inputMode {
    case .normal:
      processNormalModeKey(event)
      return true
    case .hints:
      return handleOverlayKeyEvent(event)
    default:
      // Mode changed between the tap's decision and now (e.g. `:` opened the
      // command line, which owns the key window). Drop it — it was swallowed.
      return false
    }
  }

  @discardableResult
  private func handleOverlayKeyEvent(_ event: NSEvent, swallowIgnored: Bool = false) -> Bool {
    guard let coordinator = coordinator else { return false }
    if inputMode == .normal {
      return handleNormalModeKeyEvent(event)
    }

    if inputMode == .commandLine { return false }
    if inputMode == .candidateFinder {
      return handleCandidateFinderKeyEvent(event)
    }

    if coordinator.overlayDidHandleMapping(event) {
      return true
    }

    // Hardcoded dismissal keys. Not configurable on purpose: arrows /
    // escape are common "abort what I was about to do" signals in every
    // macOS app, and matching that intuition keeps the overlay out of
    // the user's way. `<space>` joins them as a cancel *except* in
    // mouse-grid mode, where it commits the grid's centre cell — the
    // coordinator makes that call (see `overlayDidCommitCenter`) since
    // only it knows the active commit behaviour. Scrolling is handled
    // separately by a global event monitor (see
    // OverlayPanel.installScrollMonitor).
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
    case .commitCenter(let clickModifiers):
      if !coordinator.overlayDidCommitCenter(clickModifiers: clickModifiers) {
        coordinator.overlayDidCancel()
      }
      return true
    case .ignore:
      return swallowIgnored
    }
  }

  private func handleNormalModeKeyEvent(_ event: NSEvent) -> Bool {
    // Normal mode is hermetic once this panel owns the key event. Carbon
    // receives explicit modified-key mappings first; anything unclaimed
    // here is interpreted or swallowed by `NormalModeInterpreter`, never
    // forwarded to the focused app. That keeps mode state deterministic
    // across keyboard layouts that surface dead keys as modified chords.
    processNormalModeKey(event)
    return true
  }

  /// Handles `⌘a` / `⌘c` / `⌘x` / `⌘v` / `⌘z` / `⌘⇧z` while the
  /// command-line is up. AppKit normally wires these via the Edit menu
  /// (which translates the key equivalent into the matching action and
  /// invokes it on the responder chain), but Flash is `LSUIElement` and
  /// ships no main menu — there's nothing to do the translation, and
  /// the field editor's standard implementations never get a chance to
  /// run. We do the translation here for the small set of edit
  /// shortcuts everyone expects from a single-line text input.
  private func handleCommandLineEditingShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.contains(.command) else { return false }
    // ⌘+Return / ⌘+Keypad-Enter: force-submit the selected flashlight
    // candidate (insert canonical token if it's a bang, then dispatch /
    // open). Plain Return is insert-first and only opens inferred
    // finishers; `<cmd+cr>` is the explicit "act on this now" signal.
    if event.keyCode == 36 || event.keyCode == 76 {
      coordinator?.overlayDidForceSubmitCommandLineSelection()
      return true
    }
    // The user's Karabiner Unix bindings translate Ctrl-E into Cmd-Right
    // (and Ctrl-A into Cmd-Left) before the event reaches us. Those modified
    // arrow events are eligible for `performKeyEquivalent`, so let the
    // command field's editor consume them here instead of letting the panel
    // swallow them before `doCommandBy:` can see the corresponding selector.
    if modifiers.intersection([.control, .option]).isEmpty,
      !modifiers.contains(.shift),
      let editor = commandTextField.currentEditor() as? NSTextView
    {
      switch event.keyCode {
      case 123:  // Cmd-Left
        editor.moveToBeginningOfLine(nil)
        commandLineCursorIndex = commandTextFieldCursorIndex()
        return true
      case 124:  // Cmd-Right
        editor.setSelectedRange(
          NSRange(location: editor.string.utf16.count, length: 0))
        commandLineCursorIndex = commandTextFieldCursorIndex()
        return true
      default:
        break
      }
    }
    guard
      let char = event.charactersIgnoringModifiers?.lowercased().first,
      let editor = commandTextField.currentEditor() as? NSTextView
    else { return false }
    let isShift = modifiers.contains(.shift)
    switch char {
    case "a" where !isShift:
      editor.selectAll(nil)
    case "c" where !isShift:
      editor.copy(nil)
    case "x" where !isShift:
      editor.cut(nil)
    case "v" where !isShift:
      editor.paste(nil)
    case "z" where !isShift:
      editor.undoManager?.undo()
    case "z" where isShift:
      editor.undoManager?.redo()
    default:
      return false
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
        // Best match is at the TOP of the panel and ranks descend downward.
        // Ctrl-N (emacs "next") moves visually downward → next-worse match →
        // higher index → delta +1. Same logic for the arrows below.
        coordinator.overlayDidMoveCandidateFinderSelection(1)
        return true
      case "p":
        coordinator.overlayDidMoveCandidateFinderSelection(-1)
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
      coordinator.overlayDidMoveCandidateFinderSelection(1)
      return true
    case 126:  // up
      coordinator.overlayDidMoveCandidateFinderSelection(-1)
      return true
    default:
      break
    }

    if !modifiers.intersection([.command, .control, .option]).isEmpty {
      return true
    }
    guard let chars = event.characters, !chars.isEmpty else { return true }
    candidateFinderQuery.append(contentsOf: chars.filter { !$0.isNewline })
    FlashLog.trace("[input] candidate_finder length=\(candidateFinderQuery.count)")
    coordinator.overlayDidUpdateCandidateFinderQuery(candidateFinderQuery)
    return true
  }
}
