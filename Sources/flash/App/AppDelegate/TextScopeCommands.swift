import AppKit
import FlashCore

// Text engagement (`TextScope`): which focused field NORMAL acts on. The
// explicit acts engage it; a focus reading naming another element, Escape
// and the mode changes end it. NORMAL's table follows the engagement only.

extension AppDelegate {
  /// Applies one transition of the engagement: logged without content, and
  /// NORMAL's table follows it.
  func updateTextScope(_ body: (inout TextScope) -> TextScope.Change?) {
    guard let change = body(&textScope) else { return }
    let bundle =
      NSRunningApplication(processIdentifier: change.element.pid)?.bundleIdentifier ?? "-"
    switch change {
    case .engaged(_, let reason):
      FlashLog.debug("[text] engaged", fields: ["reason": reason.rawValue, "bundle": bundle])
    case .disengaged(_, let reason):
      FlashLog.debug("[text] disengaged", fields: ["reason": reason.rawValue, "bundle": bundle])
    }
    applyTextScopeTable()
  }

  /// Engages the field the focus is in now, if it is editable text: the
  /// cached reading, or the one still pending. A mode change meanwhile
  /// (INSERT again, a command line) drops the request.
  func engageFocusedText(reason: TextScope.EngageReason) {
    guard let context = normalModeDispatchContext() else { return }
    let pid = context.processID
    let bundle = context.bundleIdentifier
    let mode = modeStore.mode
    focusRegionTracker.withReading(for: pid) { [weak self] reading in
      guard let self, self.modeStore.mode == mode, case .text = reading.region,
        let element = reading.element
      else { return }
      self.updateTextScope {
        $0.engage(TextScope.Element(pid: pid, identity: element), in: bundle, reason: reason)
      }
    }
  }

  /// The config's switch and per-app `text.enabled` keys apply from now on
  /// (`TextScope.Policy`); an engagement the new policy refuses ends.
  func applyTextScopePolicy(_ mode: Config.Mode, invalidatesPending: Bool = false) {
    updateTextScope {
      $0.update(policy: TextScope.Policy(mode), invalidatesPending: invalidatesPending) { pid in
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
      }
    }
    if modeStore.mode.isVisual, let session = visualSession,
      !textScope.engages(NSRunningApplication(processIdentifier: session.pid)?.bundleIdentifier)
    {
      leaveVisual(collapse: false)
    }
  }

  /// A click, `gi` or an `f` commit went out in `pid` (nil: whichever app
  /// the click brings forward): the focus readings until the next key
  /// engage the editable text they name. The focus is read again now, as a
  /// click in the field already focused moves nothing the app reports.
  func awaitTextFocus(in pid: pid_t?, reason: TextScope.EngageReason) {
    textScope.awaitFocus(in: pid, reason: reason)
    guard let read = pid ?? currentNonFlashRunningApplication()?.processIdentifier else {
      return
    }
    focusRegionTracker.focusMayHaveChanged(pid: read)
  }

  /// The engagement across a mode change: INSERT and VISUAL round trips
  /// keep it, leaving INSERT engages the focused field, every other mode
  /// ends it.
  func textScopeModeChanged(from previous: Mode, to next: Mode) {
    switch TextScope.effect(ofModeChange: previous, to: next) {
    case .keep: break
    case .engageFocus: engageFocusedText(reason: .leftInsert)
    case .disengage: updateTextScope { $0.disengage(.modeChanged) }
    }
  }
}
