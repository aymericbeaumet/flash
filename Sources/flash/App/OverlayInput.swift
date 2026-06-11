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
  case modal
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

    if inputMode == .commandLine {
      if handleCommandLineEditingShortcut(event) { return true }
      return super.performKeyEquivalent(with: event)
    }
    if inputMode == .modal {
      return handleModalKeyEvent(event)
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
  /// resulting action. Shared by the NSPanel responder path and the
  /// always-on `NormalModeEventTap`: whichever sees the key first feeds it
  /// here. The tap swallows the event at the session level, so the panel
  /// path only runs as a fallback when the tap is absent — they never
  /// double-process the same keystroke.
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

  /// Single capture entry point for the always-on session event tap. Routes a
  /// keyDown to the handler for the current input mode and returns whether it
  /// was consumed (swallowed). A non-activating overlay panel can't reliably
  /// become the system key window over a frontmost foreign app, so this tap —
  /// not the panel's own key delivery — is the authoritative, hermetic capture
  /// path for every mode except INSERT (where the tap doesn't run). Returning
  /// false lets the key reach the focused app: modified chords reserved for the
  /// Carbon `[mode.*]` registry and global shortcuts (⌘-Tab) pass through.
  func routeCapturedKey(_ event: NSEvent) -> Bool {
    switch inputMode {
    case .normal:
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if modifiers.contains(.command) || modifiers.contains(.control)
        || modifiers.contains(.option)
      {
        // Carbon takes any chord with a `[mode.*]` mapping before the
        // event tap sees it; what reaches us is the user typing a
        // chord Flash doesn't claim — typically a third-party prefix
        // like ctrl-q for tmux, or a system shortcut. Engage a brief
        // lockout so the follow-up key (the tmux command, etc.) can't
        // accidentally resolve a standalone Flash mapping.
        normalModeChordLockoutUntil = Date().addingTimeInterval(
          TimeInterval(normalModeSequenceTimeoutMs) / 1_000)
        if !normalModePending.isEmpty {
          FlashLog.trace(
            "[input] normal chord_lockout_clears_pending pending=\(normalModePending)")
          normalModePending = ""
        }
        FlashLog.trace(
          "[input] normal chord_lockout_arm key=\(event.keyCode) "
            + "until=\(normalModeChordLockoutUntil.map { String(format: "%.3f", $0.timeIntervalSinceReferenceDate) } ?? "nil")")
        return false
      }
      if let lockoutUntil = normalModeChordLockoutUntil,
        Date() < lockoutUntil
      {
        // Pass the follow-up key through to the focused app rather
        // than letting Flash interpret it (the lockout's purpose) —
        // and drop the lockout after one key. Swallowing here was the
        // worst of both worlds: tmux didn't see its command and the
        // user's next `i` was eaten silently, so they'd press it
        // again wondering why nothing happened. One-key passthrough
        // matches the typical chord-prefix-then-command pattern
        // (tmux ctrl-q + letter, Karabiner layer + key); subsequent
        // keys resume normal-mode interpretation. <esc> works the
        // same as any other key: it clears the lockout and reaches
        // the focused app, so it can abort an in-progress chord
        // sequence (e.g. tmux's prefix-pending state).
        normalModeChordLockoutUntil = nil
        FlashLog.trace(
          "[input] normal chord_lockout_passthrough key=\(event.keyCode) "
            + "chars=\(event.charactersIgnoringModifiers ?? "nil")")
        return false
      }
      processNormalModeKey(event)
      return true
    case .hints:
      return routeCapturedHintKey(event)
    case .commandLine:
      return routeCapturedCommandLineKey(event)
    case .modal:
      return handleModalKeyEvent(event)
    case .candidateFinder:
      return handleCandidateFinderKeyEvent(event)
    }
  }

  private func routeCapturedHintKey(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) || modifiers.contains(.control)
      || modifiers.contains(.option)
    {
      // Let a configured hint-mode mapping claim it; otherwise pass through so
      // ⌘-Tab and the Carbon `[mode.*]` registry still fire — any resulting
      // focus change tears the hints down through the focus monitor.
      return coordinator?.overlayDidHandleMapping(event) == true
    }
    // Plain keys are hint typing or a dismissal (esc / space / arrows /
    // backspace); always consume so nothing leaks to the focused app.
    _ = handleOverlayKeyEvent(event)
    return true
  }

  private func routeCapturedCommandLineKey(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) {
      // ⌘a/c/x/v/z edit shortcuts run inline; any other ⌘ chord (⌘-Tab,
      // ⌘-space, global hotkeys) passes through untouched.
      if handleCommandLineEditingShortcut(event) { return true }
      return false
    }
    // Drive the real field editor so native single-line editing — cursor
    // motion, selection, ⌥-delete-word, and Return/Esc/Tab via the delegate —
    // keeps working even though the event arrived through the tap.
    if let editor = commandTextField.currentEditor() {
      editor.keyDown(with: event)
      return true
    }
    // The field editor isn't installed yet (the panel hasn't become key).
    // Re-arm capture and consume the key to stay hermetic rather than leak it.
    FlashLog.trace("[input] command_line capture_rearm key=\(event.keyCode)")
    captureKeyboardInput()
    return true
  }

  @discardableResult
  private func handleOverlayKeyEvent(_ event: NSEvent, swallowIgnored: Bool = false) -> Bool {
    guard let coordinator = coordinator else { return false }
    if inputMode == .normal {
      processNormalModeKey(event)
      return true
    }

    if inputMode == .commandLine { return false }
    if inputMode == .modal {
      return handleModalKeyEvent(event)
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
    // open). Plain Return only INSERTS — `<cmd+cr>` is the explicit
    // "act on this now" signal so the user can browse + insert without
    // committing.
    if event.keyCode == 36 || event.keyCode == 76 {
      coordinator?.overlayDidForceSubmitCommandLineSelection()
      return true
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
  private func handleModalKeyEvent(_ event: NSEvent) -> Bool {
    guard let coordinator = coordinator else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ignoredChar =
      NormalModeInterpreter.firstCharacter(event.charactersIgnoringModifiers)?
      .lowercased().first
    // Dismissal triggers: Esc, vim-style `q`, Ctrl-C, and Cmd-W. Every
    // other key is consumed silently — modal mode is hermetic, keys
    // never leak to the focused app.
    let isEsc = event.keyCode == 53
    let isQ = modifiers.isEmpty && ignoredChar == "q"
    let isCtrlC = modifiers == .control && ignoredChar == "c"
    let isCmdW = modifiers == .command && ignoredChar == "w"
    if isEsc || isQ || isCtrlC || isCmdW {
      FlashLog.trace("[input] modal dismiss key=\(event.keyCode)")
      coordinator.overlayDidCancelModal()
      return true
    }
    if modalSelectable {
      // The `:clipboard` list: Return / keypad-enter pastes the selection;
      // arrows, `j`/`k`, and Ctrl-N/Ctrl-P move it. Other keys fall through
      // to the silent consume below (the list has no text filter).
      if event.keyCode == 36 || event.keyCode == 76 {
        coordinator.overlayDidSubmitSelectableModal()
        return true
      }
      let isUp =
        event.keyCode == 126 || (modifiers.isEmpty && ignoredChar == "k")
        || (modifiers == .control && ignoredChar == "p")
      let isDown =
        event.keyCode == 125 || (modifiers.isEmpty && ignoredChar == "j")
        || (modifiers == .control && ignoredChar == "n")
      if isUp {
        moveSelectableModalSelection(-1)
        return true
      }
      if isDown {
        moveSelectableModalSelection(1)
        return true
      }
    } else if let scroll = consumeModalScrollKey(modifiers: modifiers, char: ignoredChar) {
      // Text modals (`:help`, `:plugins`, `:mappings`, plugin toasts):
      // vim-style scroll bindings navigate the modal's own scroll view,
      // hermetic to the focused app and without leaving modal mode.
      scrollModal(scroll)
      return true
    }
    FlashLog.trace("[input] modal consume key=\(event.keyCode)")
    coordinator.overlayDidPassThroughModalKey(event)
    return true
  }

  /// Maps a modal-mode key to the matching scroll motion. Mirrors the
  /// `[mode.normal.mappings]` defaults (`j/k`, `ctrl+e/y`, `ctrl+d/u`,
  /// `gg`, `G`) so modal scroll feels identical to normal-mode scroll.
  /// Manages a one-key `g` pending state for `gg` — cleared on any other
  /// key, on shift, or on the sequence timeout.
  private func consumeModalScrollKey(
    modifiers: NSEvent.ModifierFlags,
    char: Character?
  ) -> OverlayPanel.ModalScrollKind? {
    guard let char else {
      modalScrollGPending = false
      return nil
    }
    if modifiers.isEmpty {
      if char == "j" {
        modalScrollGPending = false
        return .lineDown
      }
      if char == "k" {
        modalScrollGPending = false
        return .lineUp
      }
      if char == "g" {
        if modalScrollGPending {
          modalScrollGPending = false
          return .top
        }
        modalScrollGPending = true
        DispatchQueue.main.asyncAfter(
          deadline: .now() + .milliseconds(normalModeSequenceTimeoutMs)
        ) { [weak self] in
          self?.modalScrollGPending = false
        }
        return nil
      }
    }
    if modifiers == .shift, char == "g" {
      modalScrollGPending = false
      return .bottom
    }
    if modifiers == .control {
      modalScrollGPending = false
      if char == "e" { return .lineDown }
      if char == "y" { return .lineUp }
      if char == "d" { return .halfPageDown }
      if char == "u" { return .halfPageUp }
    }
    modalScrollGPending = false
    return nil
  }

  /// Routes a `ModalTextView` keyDown through the modal interpreter when the
  /// modal is a selectable list, so plain arrows / `j` / `k` / Return reach
  /// `handleModalKeyEvent`. Read-only modals return false and keep the text
  /// view's existing pass-through behaviour.
  func consumeModalKeyDown(_ event: NSEvent) -> Bool {
    guard modalSelectable else { return false }
    return handleModalKeyEvent(event)
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
