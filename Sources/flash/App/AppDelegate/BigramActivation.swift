import AppKit
import FlashCore

extension AppDelegate {
  private var bigramSearcher: BigramSearch {
    if bigramSearch == nil {
      bigramSearch = BigramSearch(queue: monitor.axQueue)
    }
    return bigramSearch!
  }

  func activateMouseBigram(_ command: MouseCommand, contextOverride: AppContext?) {
    guard prepareHintActivation(.bigram(command, contextOverride)) else { return }
    let base = focusedAboutContext() ?? contextOverride
    guard let base else {
      FlashLog.debug("[bigram] no_context")
      endHintActivationEmpty(bundleIdentifier: nil, path: "no_context", surface: "bigram")
      applyModeOverlay()
      return
    }
    let context = monitor.coveringInteractionContext(inFrontOf: base) ?? base
    guard !context.frontWindowFrame.isNull, !context.frontWindowFrame.isInfinite,
      !context.frontWindowFrame.isEmpty
    else {
      FlashLog.debug("[bigram] no_window pid=\(context.processID)")
      endHintActivationEmpty(
        bundleIdentifier: context.bundleIdentifier, path: "no_window", surface: "bigram")
      applyModeOverlay()
      return
    }
    guard isAccessibilityTrusted() else {
      promptForAccessibility()
      FlashLog.debug("[bigram] accessibility_denied pid=\(context.processID)")
      endHintActivationEmpty(
        bundleIdentifier: context.bundleIdentifier, path: "accessibility_denied",
        surface: "bigram", countsForApp: false)
      applyModeOverlay()
      return
    }
    switch command {
    case .click, .move, .gesture: break
    default:
      endHintActivationEmpty(
        bundleIdentifier: context.bundleIdentifier, path: "bad_command", surface: "bigram",
        countsForApp: false)
      applyModeOverlay()
      return
    }

    hintSession.command = command
    hintSession.surface = .targets
    hintSession.phase = .bigram
    hintSession.bigramQuery = ""
    hintSession.prefix = ""
    hintSession.sourceAppPID = context.processID
    applyModeOverlay()
    let screenH = ScreenSpace.primaryHeight
    bigramSearcher.start(
      context: context, screenH: screenH,
      discoverFrame: { [weak self] context in
        guard let self else { return context.frontWindowFrame }
        return self.monitor.providerFrame(for: context, primaryH: screenH)
      },
      deliver: { [weak self] result in
        self?.presentBigramMatches(result)
      })
  }

  func presentBigramMatches(_ result: BigramSearch.Result) {
    guard result.generation == bigramSearch?.currentGeneration else { return }
    guard case .bigram = hintSession.phase, hintSession.bigramQuery == result.query else { return }
    let barLetters = Self.statusBarLetterTargets(
      query: result.query, command: hintSession.command,
      surfaces: overlay.statusBarLetterSurfaces(),
      activeWindowFrame: result.windowFrame)
    for letter in barLetters {
      if let popup = letter.popup {
        hintSession.statusBarPopupSnapshots[letter.target.id] = popup
      }
    }
    let targets = result.targets + barLetters.map(\.target)
    FlashLog.debug(
      "[bigram] matches=\(targets.count) query_len=\(result.query.count) "
        + "runs=\(result.runCount) status_letters=\(barLetters.count)")
    guard !targets.isEmpty else { return }
    // The letter is the search. The label is always a bigram (or longer,
    // once the matches outgrow the alphabet), so the sequence is the letter
    // and then those two keys.
    let hints = assignHints(
      targets, minLength: max(2, config.hints.minLength), region: result.windowFrame)
    guard !hints.isEmpty else { return }
    hintSession.hints = hints
    hintSession.prefix = ""
    hintSession.phase = .labels(anchor: nil)
    if !barLetters.isEmpty { overlay.captureStatusBarHintSnapshot() }
    presentHints(
      hints, prepared: .miss, outcome: .miss, bundleIdentifier: result.bundleIdentifier,
      surface: "bigram")
  }

  func overlayEndsBigramCapture(for event: NSEvent) -> Bool {
    guard hintSession.isBigramCapture else { return false }
    let strict = event.modifierFlags.intersection([.command, .control, .option])
    // Bare Escape is the interpreters' cancel, for the query and the labels.
    if event.keyCode == 53, strict.isEmpty { return false }
    let keys = overlay.keyCharacters(for: event)
    let isLeader =
      config.mode.resolvedHyperMatcher.map {
        NormalModeInterpreter.isHyperKey(
          matcher: $0,
          keyCode: event.keyCode,
          modifierFlags: event.modifierFlags,
          characters: keys.characters,
          charactersIgnoringModifiers: keys.ignoringModifiers)
      } ?? false
    let chord = strict.isEmpty ? nil : mappings.action(for: event)
    let typed: MappingCommand? =
      strict.isEmpty
      ? NormalModeInterpreter.interpret(
        pending: "",
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        characters: keys.characters,
        charactersIgnoringModifiers: keys.ignoringModifiers,
        mappings: overlay.normalModeMappings
      ).action
      : nil
    switch BigramCapture.exit(isLeader: isLeader, chord: chord, typed: typed) {
    case .stay:
      return false
    case .leader:
      cancelOverlay()
      _ = handleLeaderHoldKeyDown(event)
      return true
    case .mode(let action):
      cancelOverlay()
      performMappingCommand(action)
      return true
    }
  }

  func overlayDidBigram(_ command: HintBigramCommand) {
    switch command {
    case .cancel:
      cancelOverlay()
    case .backspace:
      guard case .bigram = hintSession.phase, var query = hintSession.bigramQuery, !query.isEmpty
      else { return }
      query.removeLast()
      hintSession.bigramQuery = query
      bigramSearch?.setQuery(query)
    case .append(let character):
      guard case .bigram = hintSession.phase, var query = hintSession.bigramQuery, query.isEmpty
      else { return }
      query.append(character)
      hintSession.bigramQuery = query
      bigramSearch?.setQuery(query)
    }
  }

  /// Backspace on the first hint label of a bigram session returns to the
  /// query with its last character removed.
  func retreatFromBigramLabels() {
    overlay.hide()
    bigramSearch?.setQuery(hintSession.bigramQuery ?? "")
  }
}
