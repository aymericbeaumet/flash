import AppKit
import FlashCore

/// Coalesces telemetry status changes, which arrive on the receiver's,
/// exporter's and store's queues, into at most one inspector push per main
/// turn.
final class TelemetryStatePush {
  private let lock = NSLock()
  private var pending = false

  /// Run `push` on main unless a push is already on its way.
  func schedule(_ push: @escaping () -> Void) {
    lock.lock()
    let first = !pending
    pending = true
    lock.unlock()
    guard first else { return }
    DispatchQueue.main.async { [self] in
      lock.lock()
      pending = false
      lock.unlock()
      push()
    }
  }
}

/// `[telemetry.receiver]` and `[telemetry.exporter]`: the loopback OTLP
/// receiver feeding `#{flash.otel…}` values and the help's telemetry page,
/// and the exporter sending Flash's own telemetry. Reconciled from the
/// configuration on launch and every reload.
extension AppDelegate {
  /// Once, beside the status controller: received changes push the
  /// inspector, and changes to metrics a surface reads re-evaluate it.
  func wireTelemetryStore() {
    let controller = statusBarController
    let push = telemetryStatePush
    telemetryStore.setHandlers(
      changed: { [weak self] in push.schedule { self?.debugStateDidChange() } },
      observedChanged: { [weak controller] in controller?.telemetryDidChange() })
    // Flash's own metrics join the store once a status format or monitor
    // reads them: one model for received, recorded and Flash's metrics.
    FlashTelemetry.installStore(telemetryStore)
  }

  func configureTelemetry(for cfg: Config) {
    let receiver = cfg.telemetry.receiver
    telemetryStore.setLimits(receiver.limits)
    if receiver.enabled {
      if telemetryReceiver?.port != receiver.port || telemetryReceiver?.token != receiver.token {
        telemetryReceiver?.stop()
        let started = OTLPReceiver(
          port: receiver.port, store: telemetryStore, token: receiver.token)
        let push = telemetryStatePush
        started.onStatusChange = { [weak self] in push.schedule { self?.debugStateDidChange() } }
        telemetryReceiver = started
        started.start()
      }
    } else if let running = telemetryReceiver {
      running.stop()
      telemetryReceiver = nil
      telemetryStore.reset()
    }
    let settings = cfg.telemetry.exportEndpoint.map { endpoint in
      TelemetryExporter.Settings(
        endpoint: endpoint, encoding: cfg.telemetry.exporter.encoding,
        gzip: cfg.telemetry.exporter.gzip, headers: cfg.telemetry.exporter.headers,
        serviceName: cfg.telemetry.exporter.serviceName,
        signals: cfg.telemetry.exporter.signals,
        intervalSeconds: TimeInterval(cfg.telemetry.exporter.intervalSeconds),
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
          ?? "development")
    }
    if settings != telemetryExporter?.settings {
      stopTelemetryExporter()
      if let settings, !settings.signals.isEmpty {
        startTelemetryExporter(settings)
      }
    }
    debugStateDidChange()
  }

  private func startTelemetryExporter(_ settings: TelemetryExporter.Settings) {
    let recorder = TelemetryRecorder(signals: settings.signals)
    let exporter = TelemetryExporter(settings: settings, recorder: recorder)
    let push = telemetryStatePush
    exporter.onStatusChange = { [weak self] in push.schedule { self?.debugStateDidChange() } }
    FlashTelemetry.install(recorder)
    if settings.signals.contains(.logs) {
      // Follows `[debug] log_level`, as the log file does: exporting never
      // forces lower-level messages on hot paths to be built.
      telemetryLogSink = FlashLog.addSink(minLevel: nil) { [weak recorder] record in
        recorder?.log(record)
      }
    }
    exporter.start()
    telemetryExporter = exporter
    FlashLog.info(
      "[telemetry] exporting signals=\(settings.signals.sorted().map(\.rawValue).joined(separator: ","))"
        + " protocol=\(settings.encoding.rawValue)")
  }

  private func stopTelemetryExporter() {
    if let telemetryLogSink { FlashLog.removeSink(telemetryLogSink) }
    telemetryLogSink = nil
    FlashTelemetry.install(nil)
    telemetryExporter?.stop()
    telemetryExporter = nil
  }

  func stopTelemetry() {
    stopTelemetryExporter()
    telemetryReceiver?.stop()
    telemetryReceiver = nil
  }

  /// The receiver's and exporter's state for `/api/state`. Header values are
  /// never included, only their names.
  func telemetryStateJSON() -> [String: Any] {
    let configured = config.telemetry
    let counters = telemetryStore.counterSnapshot()
    let receiverStatus = telemetryReceiver?.currentStatus
    func bySignal(_ values: [TelemetrySignal: Int]) -> [String: Int] {
      Dictionary(
        uniqueKeysWithValues: TelemetrySignal.allCases.map { ($0.rawValue, values[$0] ?? 0) })
    }
    var receiver: [String: Any] = [
      "enabled": configured.receiver.enabled,
      "port": configured.receiver.port,
      "listening": receiverStatus?.listeningPort != nil,
      "error": receiverStatus?.error as Any? ?? NSNull(),
      "refused": Dictionary(
        uniqueKeysWithValues: (receiverStatus?.refused ?? [:]).map { (String($0.key), $0.value) }),
      "last_refusal": receiverStatus?.lastRefusal as Any? ?? NSNull(),
      "requests": bySignal(counters.counters.requests),
      "accepted": bySignal(counters.counters.accepted),
      "rejected": bySignal(counters.counters.rejected),
      "evicted_series": counters.counters.evictedSeries,
      "last_received_ms": counters.counters.lastReceivedMs as Any? ?? NSNull(),
      "series": counters.series,
      "logs": counters.logs,
      "spans": counters.spans,
      "revision": counters.revision,
      "limits": [
        "max_series": configured.receiver.maxSeries, "max_points": configured.receiver.maxPoints,
        "max_logs": configured.receiver.maxLogs, "max_spans": configured.receiver.maxSpans,
      ],
      // Whether one is set, never its value.
      "requires_token": !configured.receiver.token.isEmpty,
    ]
    if let port = receiverStatus?.listeningPort {
      receiver["endpoint"] = "http://127.0.0.1:\(port)"
    }
    let exporterStatus = telemetryExporter?.currentStatus
    let loop =
      URLParsing.url(configured.exporter.endpoint).map {
        Config.Telemetry.targetsReceiver($0, receiver: configured.receiver)
      } ?? false
    let exporter: [String: Any] = [
      "enabled": telemetryExporter != nil,
      "endpoint": configured.exporter.endpoint,
      "blocked": loop ? "targets Flash's own receiver" : NSNull(),
      "protocol": configured.exporter.encoding.rawValue,
      "compression": configured.exporter.gzip ? "gzip" : "none",
      "signals": configured.exporter.signals.sorted().map(\.rawValue),
      "interval_s": configured.exporter.intervalSeconds,
      "headers": configured.exporter.headers.keys.sorted(),
      "service_name": configured.exporter.serviceName,
      "sent": bySignal(exporterStatus?.sent ?? [:]),
      "dropped": bySignal(exporterStatus?.dropped ?? [:]),
      "failures": exporterStatus?.failures ?? 0,
      "retrying": (exporterStatus?.retrying ?? []).sorted().map(\.rawValue),
      "last_error": exporterStatus?.lastError as Any? ?? NSNull(),
      "last_success_ms": exporterStatus?.lastSuccessMs as Any? ?? NSNull(),
    ]
    return ["receiver": receiver, "exporter": exporter]
  }
}
