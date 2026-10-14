import AppKit
import FlashCore
import FlashProviders

/// `mouse_target --words`: a hint on every visible word of the focused
/// window's text, from the same Accessibility text walk EasyMotion uses. The
/// click lands on the word's leading edge, so a click places the caret at a
/// word boundary and `--select` highlights the text between two words.
/// Flash never reads screen pixels: a window that publishes no text through
/// Accessibility shows nothing.
extension AppDelegate {
  func activateWordHints(_ command: MouseCommand, contextOverride: AppContext?) {
    guard prepareHintActivation(.words(command, contextOverride)) else { return }
    let base = focusedAboutContext() ?? contextOverride ?? currentNonFlashActivationContext()
    guard let base else {
      FlashLog.debug("[words] no_context")
      endHintActivationEmpty(bundleIdentifier: nil, path: "no_context", surface: "words")
      applyModeOverlay()
      return
    }
    let context = monitor.coveringInteractionContext(inFrontOf: base) ?? base
    guard !context.frontWindowFrame.isNull, !context.frontWindowFrame.isInfinite,
      !context.frontWindowFrame.isEmpty
    else {
      FlashLog.debug("[words] no_window pid=\(context.processID)")
      endHintActivationEmpty(
        bundleIdentifier: context.bundleIdentifier, path: "no_window", surface: "words")
      applyModeOverlay()
      return
    }
    guard isAccessibilityTrusted() else {
      promptForAccessibility()
      endHintActivationEmpty(
        bundleIdentifier: context.bundleIdentifier, path: "accessibility_denied",
        surface: "words", countsForApp: false)
      applyModeOverlay()
      return
    }
    hintSession.command = command
    hintSession.surface = .targets
    hintSession.prefix = ""
    hintSession.sourceAppPID = context.processID
    overlay.debugConfig = config.debug
    let token = activationLifecycle.begin()
    applyModeOverlay()
    let screenH = ScreenSpace.primaryHeight
    monitor.axQueue.async { [weak self] in
      guard let self else { return }
      let corpus = BigramTextCollector.collect(in: context, screenH: screenH)
      let window = BigramSearch.hintWindow(
        self.monitor.providerFrame(for: context, primaryH: screenH),
        fallback: context.frontWindowFrame)
      let targets = corpus.wordTargets()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        guard !targets.isEmpty else {
          FlashLog.debug("[words] no_words pid=\(context.processID) runs=\(corpus.runCount)")
          self.endHintActivationEmpty(
            bundleIdentifier: context.bundleIdentifier, path: "no_words", surface: "words")
          self.applyModeOverlay()
          return
        }
        let hints = self.assignHints(targets, region: window)
        self.hintSession.hints = hints
        self.hintSession.prefix = ""
        self.applyModeOverlay()
        self.presentHints(
          hints, prepared: .miss, outcome: .miss, bundleIdentifier: context.bundleIdentifier,
          surface: "words")
        FlashLog.debug(
          "[words] displayed pid=\(context.processID) words=\(hints.count) runs=\(corpus.runCount)")
      }
    }
  }
}
