import AppKit

extension AppDelegate {
  /// The semantic window restore runs off-main. Repaint only after each
  /// recovery pass has applied its AX frame so the border cannot sample the
  /// pre-handoff geometry and remain on the disconnected display.
  func windowLayoutRecovered() {
    updateActiveWindowBorder(reason: "screen_layout_recovered")
  }

  /// Window restores wait out a locked or sleeping session, and run for the
  /// windows that missed theirs once it is interactive again.
  func windowLayoutSessionChanged(suspended: Bool) {
    windowLayoutManager.setSessionSuspended(
      suspended,
      statusBarReservesSpace: statusBarVisible,
      statusBarMonitor: config.statusBar.monitor,
      beforeRecoveryPass: { [weak self] in self?.overlay.settleNativeMenuBarHeights() },
      afterRecoveryPass: { [weak self] _ in self?.windowLayoutRecovered() })
  }
}

extension AppDelegate {
  /// `window_focus`: the nearest window in a direction from the prepared
  /// catalog, or the next one in the stacking order. The z-order comes from
  /// `WindowSnapshot.windowList`, read here on the main thread, never on the
  /// layout manager's queue.
  func focusWindow(_ request: WindowFocusRequest, targetPID: pid_t) {
    switch request {
    case .direction(let direction):
      windowLayoutManager.focusWindow(direction, targetPID: targetPID)
    case .cycle(let cycle):
      let primaryH = ActionDispatcher.primaryScreenHeight()
      let info = WindowSnapshot.windowList([.optionOnScreenOnly, .excludeDesktopElements]) ?? []
      let zOrder = WindowSnapshot.entries(from: info, primaryH: primaryH)
        .filter { $0.layer == 0 && $0.pid != getpid() }
        .map { WindowFocusZEntry(pid: $0.pid, frame: $0.nsBounds) }
      windowLayoutManager.focusWindow(cycle: cycle, targetPID: targetPID, zOrder: zOrder)
    }
  }
}
