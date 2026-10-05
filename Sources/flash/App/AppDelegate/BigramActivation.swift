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
    let context = focusedAboutContext() ?? contextOverride
    guard let context else {
      FlashLog.debug("[bigram] no_context")
      endHintActivationEmpty(bundleIdentifier: nil, path: "no_context", surface: "bigram")
      applyModeOverlay()
      return
    }
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
    case .click, .move: break
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
    overlay.setBigramQueryEcho("")
    let screenH = ActionDispatcher.primaryScreenHeight()
    bigramSearcher.start(context: context, screenH: screenH) { [weak self] result in
      self?.presentBigramMatches(result)
    }
  }

  func presentBigramMatches(_ result: BigramSearch.Result) {
    guard result.generation == bigramSearch?.currentGeneration else { return }
    guard case .bigram = hintSession.phase, hintSession.bigramQuery == result.query else { return }
    FlashLog.debug(
      "[bigram] matches=\(result.targets.count) query_len=\(result.query.count) "
        + "runs=\(result.runCount)")
    guard !result.targets.isEmpty else { return }
    // The letter is the search. The label is always a bigram (or longer,
    // once the matches outgrow the alphabet), so the sequence is the letter
    // and then those two keys.
    let hints = assignHints(result.targets, minLength: max(2, config.hints.minLength))
    guard !hints.isEmpty else { return }
    hintSession.hints = hints
    hintSession.prefix = ""
    overlay.clearBigramQueryEcho()
    hintSession.phase = .labels(anchor: nil)
    presentHints(
      hints, prepared: .miss, outcome: .miss, bundleIdentifier: result.bundleIdentifier,
      surface: "bigram")
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
      overlay.setBigramQueryEcho(query)
      bigramSearch?.setQuery(query)
    case .append(let character):
      guard case .bigram = hintSession.phase, var query = hintSession.bigramQuery, query.isEmpty
      else { return }
      query.append(character)
      hintSession.bigramQuery = query
      overlay.setBigramQueryEcho(query)
      bigramSearch?.setQuery(query)
    }
  }

  /// Backspace on the first hint label of a bigram session returns to the
  /// query with its last character removed.
  func retreatFromBigramLabels() {
    let query = hintSession.bigramQuery ?? ""
    overlay.hide()
    overlay.setBigramQueryEcho(query)
    bigramSearch?.setQuery(query)
  }
}
