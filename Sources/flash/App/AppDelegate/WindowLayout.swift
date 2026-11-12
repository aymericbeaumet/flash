import AppKit
import FlashCore

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
  /// `window focus`, `window next` and `window previous`: the nearest window
  /// in a direction from the prepared catalog, the next one in the stacking
  /// order, or the focused app's next window. The z-order comes from
  /// `WindowSnapshot.windowList`, read here on the main thread, never on the
  /// layout manager's queue.
  func focusWindow(_ request: WindowFocusRequest, targetPID: pid_t) {
    switch request {
    case .direction(let direction):
      windowLayoutManager.focusWindow(direction, targetPID: targetPID)
    case .cycle(let cycle):
      windowLayoutManager.focusWindow(cycle: cycle, targetPID: targetPID, zOrder: windowZOrder())
    case .app(let cycle):
      windowLayoutManager.focusAppWindow(cycle, targetPID: targetPID, zOrder: windowZOrder())
    }
  }

  /// `mouse screens --focus`: the frontmost window on `display` takes
  /// keyboard focus, chosen from the prepared catalog in stacking order like
  /// `window focus --direction=next`. A display without windows keeps focus
  /// where it is.
  func focusFrontmostWindow(on display: WindowScreenLayout, layouts: [WindowScreenLayout]) {
    windowLayoutManager.focusFrontmostWindow(
      onScreen: display.identity, screens: layouts, zOrder: windowZOrder())
  }

  private func windowZOrder() -> [WindowFocusZEntry] {
    let primaryH = ScreenSpace.primaryHeight
    let info = WindowSnapshot.windowList([.optionOnScreenOnly, .excludeDesktopElements]) ?? []
    return WindowSnapshot.entries(from: info, primaryH: primaryH)
      .filter { $0.layer == 0 && $0.pid != getpid() }
      .map { WindowFocusZEntry(pid: $0.pid, frame: $0.nsBounds) }
  }
}
