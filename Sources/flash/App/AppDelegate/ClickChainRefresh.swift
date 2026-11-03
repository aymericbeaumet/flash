import AppKit
import FlashCore

/// A click chain follows the app it labels between two picks. The click's
/// own walk runs as soon as the click went out; what the click set off — a
/// page arriving, a list filling in, a sheet sliding down — reports itself
/// through Accessibility afterwards, and once the app has been quiet for
/// `ClickChain.refreshSettleMs` the chain walks again. Targets still there
/// keep their labels, so only what appeared or went away changes on screen.
/// Event-driven: nothing is armed unless a waiting chain's app reported a
/// change, and an AX storm reports nothing (`AppMonitor.uiDidChange`).
extension AppDelegate {
  /// App `pid` reported a change to what it shows.
  func clickChainUIDidChange(pid: pid_t) {
    guard hintSession.command.isMulti, hintSession.sourceAppPID == pid else { return }
    guard
      ClickChain.refreshes(
        hintSession, reportedPID: pid, committing: activationLifecycle.isCommitting)
    else {
      // Half a label typed: the labels stay put until the prefix is empty.
      if !hintSession.prefix.isEmpty, hintSession.missionControl == nil {
        clickChainRefreshPending = true
      }
      return
    }
    armClickChainRefresh()
  }

  /// The label prefix changed; once it is empty again, a change that
  /// arrived meanwhile is caught up.
  func clickChainPrefixDidChange() {
    guard clickChainRefreshPending, hintSession.prefix.isEmpty else { return }
    clickChainRefreshPending = false
    guard let pid = hintSession.sourceAppPID else { return }
    clickChainUIDidChange(pid: pid)
  }

  /// A pick, a fresh walk or the session's end: no refresh still waiting or
  /// walking may relabel what comes next.
  func supersedeClickChainRefresh() {
    clickChainRefreshGeneration &+= 1
    clickChainRefreshPending = false
    clickChainRefreshDeadline.cancel()
  }

  private func armClickChainRefresh() {
    // `.high`: the labels on screen follow the change. Armed only while a
    // `--multi` chain waits for its next pick and its app reported a change;
    // a later report re-arms it, so one walk follows a burst.
    clickChainRefreshDeadline.arm(afterMs: ClickChain.refreshSettleMs) { [weak self] in
      self?.refreshClickChain()
    }
  }

  private func refreshClickChain() {
    guard let pid = hintSession.sourceAppPID else { return }
    // The click's own walk, or a pick's validation, is on its way: look
    // again once it is done.
    if activationInFlight {
      if hintSession.command.isMulti, hintSession.surface == .targets {
        armClickChainRefresh()
      }
      return
    }
    guard
      ClickChain.refreshes(
        hintSession, reportedPID: pid, committing: activationLifecycle.isCommitting)
    else {
      if hintSession.command.isMulti, !hintSession.prefix.isEmpty {
        clickChainRefreshPending = true
      }
      return
    }
    guard let context = monitor.context(for: pid) else { return }
    clickChainRefreshGeneration &+= 1
    let generation = clickChainRefreshGeneration
    let isCurrent: () -> Bool = { [weak self] in
      self?.clickChainRefreshGeneration == generation
    }
    monitor.discoverAsync(context: context, isCurrent: isCurrent) { [weak self] hints, _ in
      guard let self, isCurrent() else { return }
      guard !self.activationInFlight,
        ClickChain.refreshes(
          self.hintSession, reportedPID: pid, committing: self.activationLifecycle.isCommitting)
      else {
        if self.hintSession.command.isMulti, !self.hintSession.prefix.isEmpty {
          self.clickChainRefreshPending = true
        }
        return
      }
      // A refresh never ends the chain: a tree caught mid-change keeps the
      // labels it had, and the next report walks again.
      guard !hints.isEmpty else { return }
      let relabelled = self.assignHints(
        hints.map(\.target), preserving: self.hintSession.hints, region: context.frontWindowFrame)
      self.hintSession.hints = relabelled
      self.overlay.display(hints: relabelled)
      FlashLog.debug("[multi] refreshed pid=\(pid) hints=\(relabelled.count)")
    }
  }
}
