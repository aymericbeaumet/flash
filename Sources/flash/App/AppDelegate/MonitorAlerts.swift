import AppKit

/// Monitors (`[monitors.<name>]`) are evaluated by the status controller; it
/// hands their snapshots and the alerts their rises ask for to main here.
extension AppDelegate {
  /// The help page's `monitors`, pushed like every other state change.
  func monitorsDidChange(_ snapshots: [MonitorSnapshot]) {
    monitorSnapshots = snapshots
    debugStateDidChange()
  }

  /// A monitor rose into warning or error: show it as the one centred alert.
  /// A confirmation owns that alert while it asks, so the monitor's waits
  /// for the session to end rather than replace the question.
  func presentMonitorAlert(_ alert: StatusAlert) {
    guard hintSession.confirmation == nil else {
      pendingMonitorAlert = alert
      return
    }
    pendingMonitorAlert = nil
    shownConfigError = nil
    overlay.displayAlert(alert)
  }

  /// Show the alert held back by a confirmation, once none is asking.
  func presentPendingMonitorAlert() {
    guard let alert = pendingMonitorAlert, hintSession.confirmation == nil else { return }
    presentMonitorAlert(alert)
  }
}
