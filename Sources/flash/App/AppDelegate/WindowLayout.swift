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
