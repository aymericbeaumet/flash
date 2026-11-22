import Darwin
import FlashCore
import Foundation

/// How long a flow other than a hint activation takes (`HintLatencyProbe`
/// owns those): launch, a configuration reload, the flashlight opening and
/// each key typed into it, a popup showing. Logged once per flow as
///
///     [latency] <flow> ms=<n> origin=<key|hotkey|pointer|cli|command_line|->
///       <name>=<value>…
///
/// `ms` runs from the input that asked for the flow when the probe is armed
/// inside that input's turn (`origin` names it), else from the arming
/// (`origin=-`), to the moment the caller reports. The fields after `origin`
/// are the flow's own: its stages as `<stage>_ms`, and what it handled.
/// `Scripts/log-summary.py` aggregates every flow by name; see
/// docs/performance.md.
struct LatencyProbe: Equatable {
  enum Flow: String, CaseIterable {
    case launchReady = "launch_ready"
    case configReload = "config_reload"
    case flashlightOpen = "flashlight_open"
    case flashlightKey = "flashlight_key"
    case popupShow = "popup_show"

    /// A per-key flow logs at `trace`; the others run once per command.
    var level: FlashLog.Level { self == .flashlightKey ? .trace : .info }
  }

  let flow: Flow
  /// The interaction the flow belongs to, when there is one.
  let trace: Trace.ID?
  /// Nil when the flow was not armed inside an input's own turn.
  let origin: Trace.Origin?
  let startedAt: TimeInterval

  static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// The probe for a flow starting now. Inside the turn of the input that
  /// asked for it, it dates from that input's own timestamp.
  static func arm(_ flow: Flow, at uptime: TimeInterval = now) -> LatencyProbe {
    let trigger = Trace.currentTrigger
    return LatencyProbe(
      flow: flow, trace: trigger?.id ?? Trace.current, origin: trigger?.origin,
      startedAt: trigger?.uptime ?? uptime)
  }

  /// When this process started, in `systemUptime` seconds: the kernel's
  /// start time against the wall clock. Nil when the kernel does not say.
  static func processStartUptime() -> TimeInterval? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_starttime
    let age =
      Date().timeIntervalSince1970 - (Double(started.tv_sec) + Double(started.tv_usec) / 1e6)
    guard age >= 0 else { return nil }
    return now - age
  }

  /// Milliseconds from the start to `uptime`, never negative.
  func elapsedMs(at uptime: TimeInterval) -> Double {
    max(0, uptime - startedAt) * 1000
  }

  /// `fields` follow `origin=` in the order given.
  func line(endedAt uptime: TimeInterval, fields: [(String, String)] = []) -> String {
    var line =
      "[latency] \(flow.rawValue) ms=\(Self.format(elapsedMs(at: uptime))) "
      + "origin=\(origin?.rawValue ?? "-")"
    for (name, value) in fields {
      line += " \(name)=\(Self.field(value))"
    }
    return line
  }

  /// Log the flow and record it as telemetry: `flash.flow.latency`, and a
  /// span when the flow belongs to an interaction. `attributes` are the
  /// content-free ones worth a metric dimension (a popup's `state`, a
  /// reload's `reason`); the rest of `fields` stays in the log.
  func finish(
    endedAt uptime: TimeInterval = now, fields: [(String, String)] = [],
    attributes: [String: String] = [:]
  ) {
    Trace.run(in: trace) { FlashLog.log(flow.level, line(endedAt: uptime, fields: fields)) }
    guard FlashTelemetry.current != nil else { return }
    var attributes = attributes
    attributes["flow"] = flow.rawValue
    if let origin { attributes["origin"] = origin.rawValue }
    FlashTelemetry.record(.flowLatency, elapsedMs(at: uptime), attributes)
    // One span per key typed would bury the interaction it belongs to.
    guard flow != .flashlightKey else { return }
    FlashTelemetry.span(
      flow.rawValue.replacingOccurrences(of: "_", with: " "), trace: trace?.text,
      startUptime: startedAt, endUptime: uptime, attributes: attributes, origin: origin)
  }

  static func format(_ ms: Double) -> String {
    String(format: "%.1f", ms)
  }

  /// A value as one token: whitespace would end it, and an empty one is `-`,
  /// so every field still parses as `name=value`.
  private static func field(_ value: String) -> String {
    guard !value.isEmpty else { return "-" }
    return String(value.map { $0.isWhitespace ? "_" : $0 })
  }
}

/// The stages of one flow, as `<name>_ms` fields in the order they ran.
struct LatencyStages {
  private(set) var fields: [(String, String)] = []

  mutating func add(
    _ name: String, since startedAt: TimeInterval, until endedAt: TimeInterval = LatencyProbe.now
  ) {
    fields.append(("\(name)_ms", LatencyProbe.format(max(0, endedAt - startedAt) * 1000)))
  }

  mutating func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let startedAt = LatencyProbe.now
    defer { add(name, since: startedAt) }
    return try body()
  }
}
