import Darwin
import Foundation

/// A monitor's state: what its latest value says against its thresholds.
/// `unknown` is a value that is missing or does not start with a number.
enum MonitorLevel: String, Equatable, Comparable, CaseIterable {
  case unknown
  case ok
  case warning
  case error

  private var severity: Int {
    switch self {
    case .unknown: return -1
    case .ok: return 0
    case .warning: return 1
    case .error: return 2
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
}

/// Which side of a threshold is bad: `above` for usage, `below` for charge.
enum MonitorDirection: String, Equatable, CaseIterable {
  case above
  case below
}

/// What a monitor's `run` hears from the value it watches: a rise into
/// warning or error (with thresholds), or any change of the expanded text
/// (without).
enum MonitorFireMode: Equatable {
  case never
  case onRise
  case onChange
}

/// A value monitor fired: the status controller hands it to main, which
/// runs the monitor's `run`.
struct MonitorFire: Equatable {
  var monitor: String
  var display: String
  var level: MonitorLevel
}

/// The device a `[monitors.<name>] usb` table names, read against a
/// `core:usb.attached` or `core:usb.detached` payload: each field set must
/// match, the ids exactly and the name as a case-insensitive substring of
/// the product name, so a payload missing a field the filter names does not
/// match. Never a serial number: the payload carries none.
struct USBDeviceFilter: Equatable {
  var vendorID: Int?
  var productID: Int?
  var name: String?

  init(vendorID: Int? = nil, productID: Int? = nil, name: String? = nil) {
    self.vendorID = vendorID
    self.productID = productID
    self.name = name
  }

  /// A filter naming nothing narrows nothing; the loader rejects it.
  var isEmpty: Bool { vendorID == nil && productID == nil && name == nil }

  func matches(_ payload: [String: Any]) -> Bool {
    if let vendorID, payload["vendor_id"] as? Int != vendorID { return false }
    if let productID, payload["product_id"] as? Int != productID { return false }
    if let name {
      guard let reported = payload["name"] as? String,
        reported.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      else { return false }
    }
    return true
  }
}

/// A `[monitors.<name>]` that watches host events instead of a value: each
/// event its `event` globs admit — the names and globs a plugin's `listen`
/// takes — narrowed to `app`, runs its `run` and shows its `message`.
struct EventMonitorSpec: Equatable {
  var patterns: [PluginPattern]
  /// A bundle identifier the event's app must have; nil admits every app.
  var app: String?
  /// The USB device `core:usb.*` events must name; nil admits every device.
  var usb: USBDeviceFilter?
  /// The centred alert's title, shown as is; nil shows none.
  var message: String?
  /// Whether the message shows in the centred alert (`alert = false` does not).
  var alerts = true
  /// Whether the message also posts a macOS notification.
  var notifies = false
  /// The away time this monitor's `core:user.idle` fires at, and the least
  /// an episode must have lasted for its `core:user.active`.
  var idleSeconds = IdleWatch.defaultSeconds
  /// The times of day this monitor's `core:clock.minute` fires at.
  var clockTimes: Set<ClockTime> = []
  /// The days those times fire on; empty is every day.
  var weekdays: Set<Weekday> = []

  func listens(to name: String) -> Bool {
    patterns.contains { $0.matches(name) }
  }

  /// Whether this monitor listens to the idle events at all.
  var listensToIdle: Bool {
    listens(to: HostEvent.userIdle.rawValue) || listens(to: HostEvent.userActive.rawValue)
  }

  /// Whether this monitor fires at times of day.
  var listensToClock: Bool {
    !clockTimes.isEmpty && listens(to: HostEvent.clockMinute.rawValue)
  }

  func matches(_ event: PluginEvent) -> Bool {
    guard listens(to: event.name) else { return false }
    switch event.name {
    case HostEvent.clockMinute.rawValue:
      guard let time = (event.payload["time"] as? String).flatMap(ClockTime.init),
        clockTimes.contains(time)
      else { return false }
      return weekdays.isEmpty
        || (event.payload["weekday"] as? String).flatMap(Weekday.init).map(weekdays.contains)
          == true
    case HostEvent.userIdle.rawValue:
      return event.payload["seconds"] as? Int == idleSeconds
    case HostEvent.userActive.rawValue:
      return (event.payload["idle_seconds"] as? Int ?? 0) >= idleSeconds
    case HostEvent.usbAttached.rawValue, HostEvent.usbDetached.rawValue:
      return usb?.matches(event.payload) ?? true
    default: break
    }
    guard let app else { return true }
    return (event.bundleID ?? event.payload["bundle_id"] as? String) == app
  }
}

/// The environment a monitor's `run` executable starts with, beside Flash's
/// own: which monitor ran and why. A Flash command reads none of it.
enum MonitorEnvironment {
  /// `FLASH_MONITOR`, `FLASH_EVENT` and each scalar payload field as
  /// `FLASH_EVENT_<FIELD>` (`bundle_id` → `FLASH_EVENT_BUNDLE_ID`); a list
  /// of strings joins with newlines.
  static func event(_ event: PluginEvent, monitor: String) -> [String: String] {
    var environment = ["FLASH_MONITOR": monitor, "FLASH_EVENT": event.name]
    for (key, value) in event.payload {
      let name = "FLASH_EVENT_" + key.uppercased()
      switch value {
      case let text as String: environment[name] = text
      case let flag as Bool: environment[name] = flag ? "1" : "0"
      case let number as Int: environment[name] = String(number)
      case let number as Double: environment[name] = String(number)
      case let list as [String]: environment[name] = list.joined(separator: "\n")
      default: continue
      }
    }
    return environment
  }

  /// `FLASH_MONITOR`, `FLASH_VALUE` (the expanded value) and `FLASH_STATE`.
  static func value(_ fire: MonitorFire) -> [String: String] {
    [
      "FLASH_MONITOR": fire.monitor, "FLASH_VALUE": fire.display,
      "FLASH_STATE": fire.level.rawValue,
    ]
  }
}

/// What the status controller evaluates for one `[monitors.<name>]` table.
/// A disabled monitor is listed but never evaluated.
struct StatusMonitorSpec: Equatable {
  enum Origin: String, Equatable {
    /// One of Flash's built-in monitors, whatever a later layer changed.
    case `default`
    /// Declared by the user's configuration.
    case config
  }

  var enabled = true
  var origin = Origin.config
  /// The status format whose expanded text must start with a number.
  var value: FlashStatusBarTemplate
  /// The alert's title; nil derives one from the name and threshold.
  var message: FlashStatusBarTemplate?
  /// What is failing, shown under the title in place of the value: the
  /// plugins a count counts. Nil, or text that expands empty, shows the value.
  var detail: FlashStatusBarTemplate?
  var warning: Double?
  var error: Double?
  var direction = MonitorDirection.above
  /// How often the monitor needs a fresh value: the cadence of the `#()`
  /// jobs and sampled values it reads.
  var intervalSeconds: TimeInterval = 60
  /// When its `run` is called.
  var fires = MonitorFireMode.never
  /// Whether a rise shows the centred alert (`alert = false` runs only).
  var alerts = true
  /// Whether a rise also posts a macOS notification.
  var notifies = false

  /// The level `value` reaches: a threshold counts once the value is at or
  /// past it, the error threshold first.
  func level(of value: Double?) -> MonitorLevel {
    guard let value else { return .unknown }
    func reached(_ threshold: Double?) -> Bool {
      guard let threshold else { return false }
      return direction == .above ? value >= threshold : value <= threshold
    }
    if reached(error) { return .error }
    if reached(warning) { return .warning }
    return .ok
  }

  /// The threshold a level is about: the one crossed, or for `ok` and
  /// `unknown` the first one the monitor would cross.
  func threshold(for level: MonitorLevel) -> Double? {
    switch level {
    case .error: return error ?? warning
    case .warning: return warning ?? error
    case .ok, .unknown: return warning ?? error
    }
  }

  /// Plugin id → the status segments the value and message read: what the
  /// monitor keeps observed, so their plugins publish them.
  var pluginSegments: [String: Set<String>] {
    var segments: [String: Set<String>] = [:]
    for template in [value] + [message, detail].compactMap({ $0 }) {
      for token in template.program.dependencies.values where token.hasPrefix("flash.plugin.") {
        let field = token.dropFirst("flash.plugin.".count)
        guard let dot = field.lastIndex(of: "."), dot != field.startIndex,
          field.index(after: dot) < field.endIndex
        else { continue }
        segments[String(field[..<dot]), default: []].insert(
          String(field[field.index(after: dot)...]))
      }
    }
    return segments
  }

  /// The title an alert shows without a `message`: `Battery below 20`.
  func derivedMessage(name: String, level: MonitorLevel) -> String {
    let title = MonitorText.displayName(name)
    guard let threshold = threshold(for: level) else { return title }
    return "\(title) \(direction.rawValue) \(MonitorText.number(threshold))"
  }
}

/// One monitor's alerting state machine, pure over the time it is given.
/// Thresholds have no hysteresis; alerts are what keeps a persisting state
/// quiet: only a rise into warning or error alerts, a recovery to ok clears
/// it silently, and a value that blinks out (`unknown`, a plugin restarting)
/// and back does not alert again for the state it already reported.
struct MonitorTracker: Equatable {
  /// A flapping monitor alerts at most once per level in this many seconds.
  static let alertCooldownSeconds: TimeInterval = 5 * 60

  private(set) var level = MonitorLevel.unknown
  /// Wall-clock milliseconds of the last change of `level`.
  private(set) var sinceMs: Int64
  /// Wall-clock milliseconds of the last alert, of either level.
  private(set) var lastAlertMs: Int64?
  /// The last level that was not `unknown`; an alert needs a rise above it.
  private(set) var settled = MonitorLevel.ok
  /// Uptime of the last alert per level, for the cooldown.
  private var lastAlertAt: [MonitorLevel: TimeInterval] = [:]

  init(sinceMs: Int64) {
    self.sinceMs = sinceMs
  }

  /// Move to `next`. Returns the level to alert at, or nil: a rise into
  /// warning or error that the cooldown does not hold back.
  mutating func observe(_ next: MonitorLevel, now: TimeInterval, wallMs: Int64) -> MonitorLevel? {
    if next != level {
      level = next
      sinceMs = wallMs
    }
    guard next != .unknown else { return nil }
    let rose = next > settled
    settled = next
    guard rose, next >= .warning else { return nil }
    if let last = lastAlertAt[next], now - last < Self.alertCooldownSeconds { return nil }
    lastAlertAt[next] = now
    lastAlertMs = wallMs
    return next
  }
}

/// What a monitor shows the help page, refreshed on every evaluation.
struct MonitorSnapshot: Equatable {
  var id: String
  var origin: StatusMonitorSpec.Origin
  var enabled: Bool
  var value: Double?
  /// The expanded value text, styles removed.
  var display: String
  var level: MonitorLevel
  var direction: MonitorDirection
  var warning: Double?
  var error: Double?
  var intervalSeconds: TimeInterval
  /// The expanded message, or the derived one.
  var message: String
  /// The expanded detail, styles removed; empty without one.
  var detail = ""
  var sinceMs: Int64
  var lastAlertMs: Int64?
  /// The `value` status format as written.
  var expression: String

  init(id: String, spec: StatusMonitorSpec, tracker: MonitorTracker) {
    self.id = id
    origin = spec.origin
    enabled = spec.enabled
    value = nil
    display = ""
    level = tracker.level
    direction = spec.direction
    warning = spec.warning
    error = spec.error
    intervalSeconds = spec.intervalSeconds
    message = spec.message?.template ?? spec.derivedMessage(name: id, level: tracker.level)
    sinceMs = tracker.sinceMs
    lastAlertMs = tracker.lastAlertMs
    expression = spec.value.template
  }

  /// The alert a rise to `level` shows: the message over what is failing,
  /// or over the value when the monitor names nothing.
  func alert(at level: MonitorLevel) -> StatusAlert {
    let shown = detail.isEmpty ? display : detail
    return StatusAlert(
      title: message, value: shown.isEmpty ? nil : shown,
      style: level == .error ? .error : .warning)
  }

  /// One entry of `/api/state`'s `monitors` array.
  var jsonObject: [String: Any] {
    [
      "id": id,
      "name": MonitorText.displayName(id),
      "origin": origin.rawValue,
      "enabled": enabled,
      "value": value as Any? ?? NSNull(),
      "display": display,
      "state": level.rawValue,
      "direction": direction.rawValue,
      "warning": warning as Any? ?? NSNull(),
      "error": error as Any? ?? NSNull(),
      "interval_s": intervalSeconds,
      "message": message,
      "detail": detail,
      "since_ms": sinceMs,
      "last_alert_ms": lastAlertMs as Any? ?? NSNull(),
      "expression": expression,
    ]
  }
}

enum MonitorText {
  /// `disk_full` reads `Disk full`.
  static func displayName(_ id: String) -> String {
    let words = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// A threshold as written: `20`, `0.5`.
  static func number(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  /// The drawn text of expanded runs, without styles or the blank edges.
  static func plainText(_ runs: [FlashStatusTextSegment]) -> String {
    runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The number `text` starts with, read like a meter's (`42`, `-3`,
  /// `0.75`, `.5`); nil when it starts with anything else.
  static func leadingNumber(_ text: String) -> Double? {
    let bytes = Array(text.utf8)
    func digit(_ index: Int) -> Bool { index < bytes.count && (48...57).contains(bytes[index]) }
    func point(_ index: Int) -> Bool { index < bytes.count && bytes[index] == 46 }
    let start = bytes.first == 45 ? 1 : 0
    guard digit(start) || (point(start) && digit(start + 1)) else { return nil }
    return StatusFormatGauge.numbers(in: text, limit: 1).first
  }
}

/// Core values read from the kernel by the status controller on the
/// cadence of the surfaces showing them, never on a timer of their own.
enum HostStatusValue: String, CaseIterable, Hashable, Comparable {
  /// Memory pressure 0–100: the share of memory the kernel does not count
  /// as available (`100 - kern.memorystatus_level`, as `memory_pressure`
  /// prints its free percentage).
  case memoryPressure = "flash.memory_pressure"

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// The value now; nil when the kernel does not answer. One sysctl.
  func read() -> String? {
    switch self {
    case .memoryPressure:
      var level: Int32 = 0
      var size = MemoryLayout<Int32>.size
      guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0,
        (0...100).contains(level)
      else { return nil }
      return String(100 - level)
    }
  }
}
