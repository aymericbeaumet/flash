import AppKit

/// `notify send` / `notify clear`, `logs write` and `metrics record`: a
/// script's, the command line's or a mapping's way into macOS notifications,
/// Flash's log and Flash's metrics.
extension AppDelegate {
  /// `completion` gets nil once done, or why not, on main.
  func performNotify(_ command: NotifyCommand, completion: @escaping (String?) -> Void) {
    guard let notifications else {
      return completion("notifications are unavailable in this process")
    }
    switch command {
    case .send(let request):
      notifications.send(request) { failure in
        if let failure {
          FlashLog.info("[notify] refused", fields: ["reason": failure])
        } else {
          FlashLog.debug("[notify] posted", fields: ["id": request.id ?? "-"])
        }
        completion(failure)
      }
    case .clear(let id):
      notifications.clear(id: id)
      completion(nil)
    }
  }

  /// One line into Flash's log, through the serial writer, as `user`.
  func performLogWrite(_ write: LogWrite) {
    FlashLog.log(write.level, write.line, fields: write.fields, source: LogWrite.source)
  }

  /// One measurement into the store status formats and monitors read, and
  /// into the exporter's recorder when it sends metrics.
  func performMetricRecord(_ record: MetricRecord) {
    telemetryStore.record(record, scope: MetricRecord.recordedScope)
    FlashTelemetry.current?.record(record.instrument, record.value, attributes: record.attributes)
  }

  /// Once at launch: Flash becomes its notifications' delegate, so a click
  /// acts even on one posted before a restart. Asks nothing.
  func activateNotificationClicks() {
    guard notifications != nil else { return }
    LiveNotificationCenter.shared.onClick = { [weak self] click in
      self?.notificationClicked(click)
    }
    LiveNotificationCenter.shared.activate()
  }

  /// A click on one of Flash's notifications: its URL opens, or its command
  /// runs as a mapping runs it.
  func notificationClicked(_ click: NotifyClick) {
    switch click {
    case .open(let url):
      FlashLog.debug("[notify] clicked", fields: ["action": "open", "scheme": url.scheme ?? ""])
      NSWorkspace.shared.open(url)
    case .run(let command):
      FlashLog.debug(
        "[notify] clicked",
        fields: ["action": "run", "command": command.argv.joined(separator: " ")])
      performMappedCommand(command)
    case .nothing:
      break
    }
  }

  /// A monitor with `notify = true` rose, or its event fired: one macOS
  /// notification, replacing the monitor's previous one. A refusal (Flash's
  /// notifications turned off) warns once until it changes.
  func notifyMonitor(_ name: String, title: String, body: String, error: Bool) {
    guard let notifications else { return }
    let request = NotifyRequest(
      title: title, subtitle: "", body: body, sound: error, url: nil, command: nil,
      id: "monitor.\(name)")
    notifications.send(request) { failure in
      let state = failure ?? "posted"
      if let failure, FlashLog.changed("notify.monitor", to: state) {
        FlashLog.warn("[notify] monitor_refused", fields: ["monitor": name, "reason": failure])
      } else if failure == nil {
        _ = FlashLog.changed("notify.monitor", to: state)
      }
    }
  }
}
