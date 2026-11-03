import Foundation

/// Flash's own instruments, exported as OpenTelemetry metrics. Attributes
/// are fixed, content-free names: plugin ids, request methods, outcomes,
/// monitor names. Never an app's bundle identifier, a window title, a key or
/// any text the user typed.
enum FlashInstrument: String, CaseIterable {
  /// Plugin request round trips; `plugin`, `method`, `outcome`.
  case pluginRequestDuration = "flash.plugin.request.duration"
  /// How long `posix_spawn` took for a plugin launch; `plugin`.
  case pluginSpawnDuration = "flash.plugin.spawn.duration"
  /// Plugin restarts after a crash or an exit; `plugin`.
  case pluginRestarts = "flash.plugin.restarts"
  /// Plugin lifecycle errors: failed launches, exits, handshakes; `plugin`.
  case pluginErrors = "flash.plugin.errors"
  /// From the input that asked for hints to the frame that shows them;
  /// `origin`, `surface`, `outcome`, `app_class`.
  case hintsLatency = "flash.hints.latency"
  /// Each monitor's latest value; `monitor`.
  case monitorValue = "flash.monitor.value"
  /// Each monitor's state: -1 unknown, 0 ok, 1 warning, 2 error; `monitor`.
  case monitorLevel = "flash.monitor.level"
  /// Telemetry the exporter dropped; `signal`, `reason`.
  case telemetryDropped = "flash.telemetry.dropped"

  var kind: MetricKind {
    switch self {
    case .pluginRequestDuration, .pluginSpawnDuration, .hintsLatency: return .histogram
    case .pluginRestarts, .pluginErrors, .telemetryDropped: return .counter
    case .monitorValue, .monitorLevel: return .gauge
    }
  }

  var unit: String {
    switch self {
    case .pluginRequestDuration, .pluginSpawnDuration, .hintsLatency: return "ms"
    case .pluginRestarts: return "{restart}"
    case .pluginErrors: return "{error}"
    case .telemetryDropped: return "{item}"
    case .monitorValue, .monitorLevel: return "1"
    }
  }

  var summary: String {
    switch self {
    case .pluginRequestDuration: return "Plugin request round trip"
    case .pluginSpawnDuration: return "Time to spawn a plugin process"
    case .pluginRestarts: return "Plugin restarts"
    case .pluginErrors: return "Plugin lifecycle errors"
    case .hintsLatency: return "Input to visible hints"
    case .monitorValue: return "Monitor value"
    case .monitorLevel: return "Monitor state: -1 unknown, 0 ok, 1 warning, 2 error"
    case .telemetryDropped: return "Telemetry dropped by the exporter"
    }
  }

  /// Millisecond buckets for the latency histograms.
  static let latencyBounds: [Double] = [
    1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000,
  ]

  /// The instrument as every metric stream is described, Flash's own and
  /// recorded ones alike.
  var instrument: MetricInstrument {
    MetricInstrument(
      name: rawValue, kind: kind, unit: unit, summary: summary, bounds: Self.latencyBounds)
  }
}

/// The one door instrumentation goes through. With the exporter off (the
/// default) and no surface reading Flash's metrics, every call is two lock
/// checks and returns. With the exporter on, a call records into the
/// `TelemetryRecorder` under its lock and never does I/O: the exporter's own
/// queue encodes and sends later, on the shared clock. A metric a status
/// format or monitor reads (`#{flash.otel:flash.hints.latency}`) is also kept
/// in the `TelemetryStore`, beside what the receiver ingests and what
/// `metrics record` records: one model for every metric Flash knows.
enum FlashTelemetry {
  private static let lock = NSLock()
  private static var recorder: TelemetryRecorder?
  private static var store: TelemetryStore?

  static func install(_ next: TelemetryRecorder?) {
    lock.lock()
    recorder = next
    lock.unlock()
  }

  /// The store Flash's own metrics are mirrored into while read.
  static func installStore(_ next: TelemetryStore?) {
    lock.lock()
    store = next
    lock.unlock()
  }

  private static var currentStore: TelemetryStore? {
    lock.lock()
    defer { lock.unlock() }
    return store
  }

  static var current: TelemetryRecorder? {
    lock.lock()
    defer { lock.unlock() }
    return recorder
  }

  static func record(
    _ instrument: FlashInstrument, _ value: Double, _ attributes: [String: String] = [:]
  ) {
    current?.record(instrument, value, attributes: attributes)
    currentStore?.recordIfObserved(
      MetricRecord(instrument: instrument.instrument, value: value, attributes: attributes),
      scope: MetricRecord.instrumentScope)
  }

  /// A span inside interaction `trace` (its text form, as plugin requests
  /// carry it), from `startUptime` to `endUptime` in `systemUptime` seconds.
  /// Without a trace nothing is recorded: a span needs the interaction it
  /// belongs to.
  static func span(
    _ name: String, trace: String?, startUptime: TimeInterval, endUptime: TimeInterval,
    attributes: [String: String] = [:], failed: Bool = false, origin: Trace.Origin? = nil
  ) {
    guard let trace, let id = UInt64(trace, radix: 36), let recorder = current,
      recorder.signals.contains(.traces)
    else { return }
    recorder.span(
      name, trace: id, startUptime: startUptime, endUptime: endUptime, attributes: attributes,
      failed: failed, origin: origin)
  }
}

/// What the exporter sends next: Flash's metrics aggregated in place, and
/// bounded queues of log records and finished spans. Thread-safe; recording
/// costs one lock and an append, and drops (counted) once a queue is full.
final class TelemetryRecorder {
  struct Limits: Equatable {
    var maxSeries = 512
    var maxLogs = 2048
    var maxSpans = 2048
    var maxOpenInteractions = 256
  }

  /// One metric stream's aggregation.
  struct MetricState: Equatable {
    var instrument: MetricInstrument
    var attributes: [String: String]
    var value = 0.0
    var count: UInt64 = 0
    var sum = 0.0
    var min = Double.infinity
    var max = -Double.infinity
    var buckets: [UInt64] = []
    var timeNs: UInt64 = 0
  }

  struct LogItem: Equatable {
    var timeNs: UInt64
    var level: FlashLog.Level
    var message: String
    var source: String
    var fields: [String: String]
    var trace: UInt64?
  }

  struct SpanItem: Equatable {
    var name: String
    var trace: UInt64
    /// Nil for an interaction's root span.
    var spanID: UInt64
    var parentID: UInt64?
    var startNs: UInt64
    var endNs: UInt64
    var attributes: [String: String]
    var failed: Bool
  }

  /// An interaction that took part in something worth a span; its root is
  /// emitted once it has been idle for `settleSeconds`.
  struct Interaction: Equatable {
    var startNs: UInt64
    var endNs: UInt64
    var origin: Trace.Origin?
    var lastActivity: TimeInterval
    var children = 0
  }

  static let settleSeconds: TimeInterval = 1

  let signals: Set<TelemetrySignal>
  let limits: Limits
  /// The high half of every exported trace id: random per launch, so ids
  /// from different runs never collide in a backend.
  let traceIDPrefix: UInt64
  /// When this recorder started: the start of every cumulative stream.
  let startNs: UInt64
  private let lock = NSLock()
  private var metrics: [String: MetricState] = [:]
  private var logs: [LogItem] = []
  private var spans: [SpanItem] = []
  private var interactions: [UInt64: Interaction] = [:]
  private var metricsDirty = false
  private var dropped: [TelemetrySignal: Int] = [:]
  /// Whether `onActivity` was told and the exporter has not drained since.
  private var activityPending = false
  private var onActivity: (() -> Void)?
  private let wallClock: () -> Date
  private let uptime: () -> TimeInterval

  init(
    signals: Set<TelemetrySignal>, limits: Limits = Limits(),
    traceIDPrefix: UInt64 = UInt64.random(in: 1...UInt64.max),
    wallClock: @escaping () -> Date = Date.init,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.signals = signals
    self.limits = limits
    self.traceIDPrefix = traceIDPrefix
    self.wallClock = wallClock
    self.uptime = uptime
    startNs = Self.nanoseconds(wallClock())
  }

  static func nanoseconds(_ date: Date) -> UInt64 {
    UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000)
  }

  /// Wall-clock nanoseconds of a `systemUptime` reading.
  func wallNanoseconds(uptime reading: TimeInterval) -> UInt64 {
    let offset = reading - uptime()
    return Self.nanoseconds(wallClock().addingTimeInterval(offset))
  }

  /// `handler` runs (on the recording thread) once per batch of activity:
  /// the first record after the exporter last drained.
  func setActivityHandler(_ handler: (() -> Void)?) {
    lock.lock()
    onActivity = handler
    lock.unlock()
  }

  /// Under `lock`; returns the handler to call once the lock is released.
  private func noteActivityLocked() -> (() -> Void)? {
    guard !activityPending else { return nil }
    activityPending = true
    return onActivity
  }

  func record(_ instrument: FlashInstrument, _ value: Double, attributes: [String: String]) {
    record(instrument.instrument, value, attributes: attributes)
  }

  /// Any instrument: Flash's own, or one `metrics record` described.
  func record(_ instrument: MetricInstrument, _ value: Double, attributes: [String: String]) {
    guard signals.contains(.metrics), value.isFinite else { return }
    lock.lock()
    recordLocked(instrument, value, attributes: attributes)
    let handler = noteActivityLocked()
    lock.unlock()
    handler?()
  }

  /// Under `lock`. A stream beyond `maxSeries` is dropped, and counted.
  private func recordLocked(
    _ instrument: MetricInstrument, _ value: Double, attributes: [String: String]
  ) {
    let key =
      instrument.name + "\u{0}"
      + attributes.keys.sorted().map { "\($0)=\(attributes[$0] ?? "")" }.joined(separator: "\u{1}")
    guard metrics[key] != nil || metrics.count < limits.maxSeries else {
      dropped[.metrics, default: 0] +=
        instrument.name == FlashInstrument.telemetryDropped.rawValue ? 0 : 1
      return
    }
    // A stream keeps one kind: recording the name as another starts it over.
    var state =
      metrics[key].flatMap { $0.instrument == instrument ? $0 : nil }
      ?? MetricState(
        instrument: instrument, attributes: attributes,
        buckets: instrument.kind == .histogram
          ? Array(repeating: 0, count: instrument.bounds.count + 1) : [])
    switch instrument.kind {
    case .counter:
      state.value += value
    case .gauge:
      state.value = value
    case .histogram:
      state.count += 1
      state.sum += value
      state.min = Swift.min(state.min, value)
      state.max = Swift.max(state.max, value)
      let bounds = instrument.bounds
      state.buckets[bounds.firstIndex { value <= $0 } ?? bounds.count] += 1
    }
    state.timeNs = Self.nanoseconds(wallClock())
    metrics[key] = state
    metricsDirty = true
  }

  /// A FlashLog record. Plugin stderr is never exported: it is third-party
  /// text the plugin's author, not Flash, chose to print.
  func log(_ record: FlashLog.Record) {
    guard signals.contains(.logs), !record.message.hasPrefix("[plugin] stderr") else { return }
    let item = LogItem(
      timeNs: UInt64(max(0, record.timeUnixMs)) * 1_000_000, level: record.level,
      message: record.message, source: record.source, fields: record.fields,
      trace: record.trace.flatMap { UInt64($0, radix: 36) })
    let now = uptime()
    lock.lock()
    guard logs.count < limits.maxLogs else {
      dropped[.logs, default: 0] += 1
      lock.unlock()
      return
    }
    logs.append(item)
    if let trace = item.trace, signals.contains(.traces) {
      touchInteractionLocked(trace, startNs: item.timeNs, endNs: item.timeNs, now: now)
    }
    let handler = noteActivityLocked()
    lock.unlock()
    handler?()
  }

  func span(
    _ name: String, trace: UInt64, startUptime: TimeInterval, endUptime: TimeInterval,
    attributes: [String: String], failed: Bool, origin: Trace.Origin?
  ) {
    let startNs = wallNanoseconds(uptime: startUptime)
    let endNs = max(startNs, wallNanoseconds(uptime: endUptime))
    let now = uptime()
    lock.lock()
    guard spans.count < limits.maxSpans else {
      dropped[.traces, default: 0] += 1
      lock.unlock()
      return
    }
    spans.append(
      SpanItem(
        name: name, trace: trace, spanID: UInt64.random(in: 1...UInt64.max), parentID: trace,
        startNs: startNs, endNs: endNs, attributes: attributes, failed: failed))
    touchInteractionLocked(trace, startNs: startNs, endNs: endNs, now: now)
    interactions[trace]?.children += 1
    if let origin { interactions[trace]?.origin = origin }
    let handler = noteActivityLocked()
    lock.unlock()
    handler?()
  }

  private func touchInteractionLocked(
    _ trace: UInt64, startNs: UInt64, endNs: UInt64, now: TimeInterval
  ) {
    if var interaction = interactions[trace] {
      interaction.startNs = Swift.min(interaction.startNs, startNs)
      interaction.endNs = Swift.max(interaction.endNs, endNs)
      interaction.lastActivity = now
      interactions[trace] = interaction
      return
    }
    if interactions.count >= limits.maxOpenInteractions,
      let oldest = interactions.min(by: { $0.value.lastActivity < $1.value.lastActivity })
    {
      // Settle the oldest early rather than lose it.
      interactions.removeValue(forKey: oldest.key)
      appendRootLocked(oldest.key, oldest.value)
    }
    interactions[trace] = Interaction(
      startNs: startNs, endNs: endNs, origin: nil, lastActivity: now)
  }

  private func appendRootLocked(_ trace: UInt64, _ interaction: Interaction) {
    guard spans.count < limits.maxSpans else {
      dropped[.traces, default: 0] += 1
      return
    }
    var attributes = ["flash.trace": String(trace, radix: 36)]
    if let origin = interaction.origin { attributes["flash.origin"] = origin.rawValue }
    spans.append(
      SpanItem(
        name: "flash.interaction", trace: trace, spanID: trace, parentID: nil,
        startNs: interaction.startNs, endNs: interaction.endNs, attributes: attributes,
        failed: false))
  }

  /// What the next export sends.
  struct Batch {
    var metrics: [MetricState]?
    var logs: [LogItem] = []
    var spans: [SpanItem] = []
    var dropped: [TelemetrySignal: Int] = [:]
    /// Whether anything is left behind: more queued than one batch takes,
    /// or interactions still settling.
    var remaining = false
  }

  /// Take up to `maxItems` log records and spans, settle idle interactions,
  /// and snapshot every metric stream when any changed. `skip` names the
  /// signals whose previous batch is still being retried: they keep queuing.
  func drain(maxItems: Int, skip: Set<TelemetrySignal> = []) -> Batch {
    let now = uptime()
    lock.lock()
    defer { lock.unlock() }
    var batch = Batch()
    for (trace, interaction) in interactions
    where now - interaction.lastActivity >= Self.settleSeconds {
      interactions.removeValue(forKey: trace)
      appendRootLocked(trace, interaction)
    }
    for (signal, count) in dropped where count > 0 {
      batch.dropped[signal] = count
      if signals.contains(.metrics) {
        recordLocked(
          FlashInstrument.telemetryDropped.instrument, Double(count),
          attributes: ["signal": signal.rawValue, "reason": "queue_full"])
      }
    }
    dropped.removeAll()
    if !skip.contains(.metrics), metricsDirty {
      batch.metrics = metrics.keys.sorted().compactMap { metrics[$0] }
      metricsDirty = false
    }
    if !skip.contains(.logs) {
      batch.logs = Array(logs.prefix(maxItems))
      logs.removeFirst(batch.logs.count)
    }
    if !skip.contains(.traces) {
      batch.spans = Array(spans.prefix(maxItems))
      spans.removeFirst(batch.spans.count)
    }
    batch.remaining =
      !interactions.isEmpty || logs.count > 0 && !skip.contains(.logs)
      || spans.count > 0 && !skip.contains(.traces)
    activityPending = batch.remaining
    return batch
  }

  /// Count items an export gave up on.
  func noteDropped(_ signal: TelemetrySignal, count: Int, reason: String) {
    guard count > 0 else { return }
    record(
      .telemetryDropped, Double(count), attributes: ["signal": signal.rawValue, "reason": reason])
  }

  /// The 16-byte OTLP trace id of interaction `trace`.
  func traceID(_ trace: UInt64) -> Data {
    Self.bigEndian(traceIDPrefix) + Self.bigEndian(trace)
  }

  static func bigEndian(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }
}
