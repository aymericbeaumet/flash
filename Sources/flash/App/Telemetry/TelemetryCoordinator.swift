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

/// `[telemetry.receiver]` and `[telemetry.exporter]`: the store of received
/// and recorded telemetry, the loopback OTLP receiver feeding
/// `#{flash.otel…}` values and the help's telemetry page, and the exporter
/// sending Flash's own telemetry. Reconciled from the configuration on launch
/// and every reload. Main queue only, like the configuration that drives it;
/// the store, receiver and exporter it owns work on their own queues.
final class TelemetryCoordinator {
  /// Received OpenTelemetry data; empty while the receiver is off.
  let store = TelemetryStore()
  private var receiver: OTLPReceiver?
  private var exporter: TelemetryExporter?
  private var logSink: UUID?
  private let statePush = TelemetryStatePush()
  /// The state `stateJSON` reports changed. Called on main, at most once per
  /// main turn for changes that arrive on another queue.
  private var stateChanged: () -> Void = {}

  /// Once, beside the status controller: received changes report a state
  /// change, and changes to metrics a surface reads re-evaluate it
  /// (`observedChanged`, on the store's queue).
  func wire(stateChanged: @escaping () -> Void, observedChanged: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.stateChanged = stateChanged
    store.setHandlers(changed: statusChanged, observedChanged: observedChanged)
    // Flash's own metrics join the store once a status format or monitor
    // reads them: one model for received, recorded and Flash's metrics.
    FlashTelemetry.installStore(store)
  }

  func configure(_ telemetry: Config.Telemetry) {
    dispatchPrecondition(condition: .onQueue(.main))
    let configured = telemetry.receiver
    store.setLimits(configured.limits)
    if configured.enabled {
      if receiver?.port != configured.port || receiver?.token != configured.token {
        receiver?.stop()
        let started = OTLPReceiver(port: configured.port, store: store, token: configured.token)
        started.onStatusChange = statusChanged
        receiver = started
        started.start()
      }
    } else if let running = receiver {
      running.stop()
      receiver = nil
      store.reset()
    }
    let settings = telemetry.exportEndpoint.map { endpoint in
      TelemetryExporter.Settings(
        endpoint: endpoint, encoding: telemetry.exporter.encoding,
        gzip: telemetry.exporter.gzip, headers: telemetry.exporter.headers,
        serviceName: telemetry.exporter.serviceName,
        signals: telemetry.exporter.signals,
        intervalSeconds: TimeInterval(telemetry.exporter.intervalSeconds),
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
          ?? "development")
    }
    if settings != exporter?.settings {
      stopExporter()
      if let settings, !settings.signals.isEmpty {
        startExporter(settings)
      }
    }
    stateChanged()
  }

  /// A status change on any queue: one report on main, whatever arrives
  /// before it runs.
  private var statusChanged: () -> Void {
    { [weak self, statePush] in statePush.schedule { self?.stateChanged() } }
  }

  private func startExporter(_ settings: TelemetryExporter.Settings) {
    let recorder = TelemetryRecorder(signals: settings.signals)
    let exporter = TelemetryExporter(settings: settings, recorder: recorder)
    exporter.onStatusChange = statusChanged
    FlashTelemetry.install(recorder)
    if settings.signals.contains(.logs) {
      // Follows `[debug] log_level`, as the log file does: exporting never
      // forces lower-level messages on hot paths to be built.
      logSink = FlashLog.addSink(minLevel: nil) { [weak recorder] record in
        recorder?.log(record)
      }
    }
    exporter.start()
    self.exporter = exporter
    FlashLog.info(
      "[telemetry] exporting signals=\(settings.signals.sorted().map(\.rawValue).joined(separator: ","))"
        + " protocol=\(settings.encoding.rawValue)")
  }

  private func stopExporter() {
    if let logSink { FlashLog.removeSink(logSink) }
    logSink = nil
    FlashTelemetry.install(nil)
    exporter?.stop()
    exporter = nil
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    stopExporter()
    receiver?.stop()
    receiver = nil
  }

  /// The receiver's and exporter's state for `/api/state`, beside what
  /// `configured` asks for. Header values are never included, only their
  /// names.
  func stateJSON(for configured: Config.Telemetry) -> [String: Any] {
    let counters = store.counterSnapshot()
    let receiverStatus = receiver?.currentStatus
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
    let exporterStatus = self.exporter?.currentStatus
    let loop =
      URLParsing.url(configured.exporter.endpoint).map {
        Config.Telemetry.targetsReceiver($0, receiver: configured.receiver)
      } ?? false
    let exporter: [String: Any] = [
      "enabled": self.exporter != nil,
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
