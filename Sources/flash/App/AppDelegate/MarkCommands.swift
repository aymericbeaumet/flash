import AppKit

/// `mark set --letter=<x>` and `mark jump --letter=<x>`. `MarkStore`
/// reads and writes the file on its queue; the focused app, the activation
/// and the launch stay on main.
extension AppDelegate {
  func performMarkCommand(_ command: MarkCommand) {
    switch command {
    case .set(let slot):
      // The app the user was working in: the focused non-Flash app, else
      // the captured NORMAL target.
      guard let context = normalModeDispatchContext() else {
        displayCommandFailure(command.name, reason: "no focused app to mark")
        return
      }
      let entry = MarkEntry(pid: context.processID, bundleID: context.bundleIdentifier)
      markStore.set(slot, to: entry) { [weak self] saved in
        guard saved else {
          self?.displayCommandFailure(command.name, reason: "could not save mark \(slot)")
          return
        }
        FlashLog.debug("[marks] set letter=\(slot) pid=\(entry.pid) bundle=\(entry.bundleID)")
      }
    case .jump(let slot):
      markStore.entry(for: slot) { [weak self] entry in
        guard let self else { return }
        guard let entry else {
          self.displayCommandFailure(command.name, reason: "no mark \(slot)")
          return
        }
        self.jumpToMark(entry, slot: slot, command: command)
      }
    }
  }

  /// Raise the saved process while it is still the marked app, else another
  /// running instance of the bundle (the mark follows it), else launch the
  /// bundle.
  private func jumpToMark(_ entry: MarkEntry, slot: MarkSlot, command: MarkCommand) {
    var running: [(pid: pid_t, bundleID: String)] = []
    if let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated {
      running.append((app.processIdentifier, app.bundleIdentifier ?? ""))
    }
    if !entry.bundleID.isEmpty {
      running += NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID)
        .filter { !$0.isTerminated }
        .map { ($0.processIdentifier, entry.bundleID) }
    }
    if let pid = MarkStore.target(for: entry, running: running), activateCommandTarget(pid) {
      if pid != entry.pid { markStore.rewritePID(pid, for: slot, expecting: entry) }
      return
    }
    guard !entry.bundleID.isEmpty else {
      displayCommandFailure(command.name, reason: "mark \(slot) is no longer running")
      return
    }
    ApplicationLauncher.open(bundleID: entry.bundleID) { [weak self] error in
      guard let error else { return }
      FlashLog.warn("[marks] open \(entry.bundleID) for mark \(slot) failed: \(error)")
      self?.displayCommandFailure(command.name, reason: "could not open mark \(slot)")
    }
  }
}
