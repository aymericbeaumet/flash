import AppKit
import Foundation

/// The process values a status surface can show: conky's `${top}` tables and
/// the focused app's live resource figures.
enum ProcessStatusValue: String, CaseIterable, Hashable, Comparable {
  /// The busiest processes by CPU, one aligned row each.
  case topCPU = "flash.top_cpu"
  /// The busiest processes by resident memory.
  case topMemory = "flash.top_mem"
  /// The focused app's process tree: CPU, memory, sockets, threads, uptime,
  /// disk I/O.
  case focusedAppDetails = "flash.focused_app_details"

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var isTopTable: Bool { self != .focusedAppDetails }
}

/// The app whose process tree `flash.focused_app_details` shows.
struct FocusedProcess: Equatable {
  var pid: pid_t
  var bundleID: String
}

/// Application metadata is read on the sampler queue, once per process
/// identity, rather than doing bundle I/O on the focus-change path.
struct FocusedProcessMetadata: Equatable {
  var name = ""
  var version = ""
  var bundlePath = ""
  var executablePath = ""

  static func read(_ app: FocusedProcess) -> Self {
    guard let running = NSRunningApplication(processIdentifier: app.pid),
      app.bundleID.isEmpty || running.bundleIdentifier == app.bundleID
    else { return Self() }
    let bundle = running.bundleURL.flatMap { Bundle(url: $0) }
    let version =
      bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return Self(
      name: running.localizedName ?? "",
      version: version.isEmpty
        ? build : (build.isEmpty || build == version ? version : "\(version) (\(build))"),
      bundlePath: running.bundleURL?.path ?? "",
      executablePath: running.executableURL?.path ?? "")
  }
}

struct FocusedProcessMetadataCache {
  private struct Identity: Equatable {
    var app: FocusedProcess
    var startAbstime: UInt64
  }

  private var identity: Identity?
  private var value = FocusedProcessMetadata()

  mutating func read(
    _ app: FocusedProcess, startAbstime: UInt64,
    using read: (FocusedProcess) -> FocusedProcessMetadata
  ) -> FocusedProcessMetadata {
    let next = Identity(app: app, startAbstime: startAbstime)
    if identity != next {
      value = read(app)
      identity = next
    }
    return value
  }
}

/// How the process values read as text. Focused details have bold headings;
/// external names are escaped so they cannot open a style marker.
enum ProcessStatusFormat {
  /// `[statusbar] top_count`: rows per table.
  static let topCountRange = 1...20
  static let defaultTopCount = 5
  /// Visible width of the name column, conky's `top_name_width` default.
  static let nameWidth = 15
  /// Width of a `focused_app_details` row label.
  static let labelWidth = 14

  /// The `count` busiest processes as an aligned two-column table: the name
  /// padded to a fixed width, the value right-aligned. Busiest first; ties
  /// break by name, then pid, so equal figures never shuffle rows. Empty when
  /// there are no processes.
  static func topTable(
    _ value: ProcessStatusValue, processes: [ProcessTable.Process], count: Int
  ) -> String {
    let ranked = processes.sorted { left, right in
      switch value {
      case .topMemory where left.residentBytes != right.residentBytes:
        return left.residentBytes > right.residentBytes
      case .topCPU, .focusedAppDetails:
        if left.cpuPercent != right.cpuPercent { return left.cpuPercent > right.cpuPercent }
      case .topMemory:
        break
      }
      if left.name != right.name {
        return Array(left.name.utf8).lexicographicallyPrecedes(Array(right.name.utf8))
      }
      return left.pid < right.pid
    }.prefix(min(max(count, topCountRange.lowerBound), topCountRange.upperBound))
    guard !ranked.isEmpty else { return "" }
    let figures = ranked.map { process in
      value == .topMemory
        ? bytesIEC(process.residentBytes)
        : String(format: "%.1f%%", max(0, process.cpuPercent))
    }
    // The widest figure in ordinary use (`100.0%`, `1023 MiB`), so the value
    // column only widens for an outlier.
    let figureWidth = figures.map(\.count).reduce(value == .topMemory ? 8 : 6, max)
    let lines = zip(ranked, figures).map { process, figure in
      let name = cellName(process)
      return padded(name, to: nameWidth) + "  "
        + String(repeating: " ", count: max(0, figureWidth - figure.count)) + figure
    }
    return escaped(lines.joined(separator: "\n"))
  }

  /// A compact app summary; resource totals include the currently reachable
  /// descendants, while uptime belongs to the main process alone.
  static func focusedDetails(
    _ app: FocusedProcess, _ tree: ProcessTable.Tree,
    metadata: FocusedProcessMetadata = .init()
  ) -> String {
    let memoryPercent = Double(tree.residentBytes) / Double(ProcessTable.physicalMemory) * 100
    let title = metadata.name.isEmpty ? tree.name : metadata.name
    var identity = identityRows(app)
    if !metadata.version.isEmpty { identity.insert(row("Version", metadata.version), at: 0) }
    let resources = [
      row("CPU", String(format: "%.1f%% · 100%% = 1 core", tree.cpuPercent)),
      row(
        "Memory",
        "\(bytesIEC(tree.residentBytes)) (\(String(format: "%.1f%%", memoryPercent)) of RAM)"),
      row("Processes", "\(tree.processCount) · \(tree.threadCount) threads"),
      row("Sockets", String(tree.socketCount)),
      row("Running", "\(uptime(tree.uptimeSeconds)) · main process"),
      row("Disk read", "\(bytesIEC(tree.diskReadBytes)) cumulative"),
      row("Disk written", "\(bytesIEC(tree.diskWriteBytes)) cumulative"),
    ]
    var sections = [
      heading(title) + "\n" + escaped(identity.joined(separator: "\n")),
      heading("Resources · app + descendants") + "\n" + escaped(resources.joined(separator: "\n")),
    ]
    if !tree.descendants.isEmpty {
      let helpers = tree.descendants.sorted {
        if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
        if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
        return $0.pid < $1.pid
      }.prefix(5)
      let lines =
        [padded("Process", to: 24) + String(format: "%7@ %8@ %10@", "PID", "CPU", "Memory")]
        + helpers.map {
          padded(cellName($0, width: 24), to: 24)
            + String(format: "%7d %7.1f%% %10@", $0.pid, $0.cpuPercent, bytesIEC($0.residentBytes))
        }
      sections.append(
        heading("Busiest helpers · \(helpers.count) of \(tree.descendants.count)")
          + "\n" + escaped(lines.joined(separator: "\n")))
    }
    let paths = [
      ("Bundle path", metadata.bundlePath), ("Executable", metadata.executablePath),
    ].filter { !$0.1.isEmpty }.map { row($0.0, $0.1) }
    if !paths.isEmpty {
      sections.append(heading("Application") + "\n" + escaped(paths.joined(separator: "\n")))
    }
    return sections.joined(separator: "\n\n")
  }

  /// The app's identity over a state line, shown while its figures are being
  /// read or when they cannot be: never another app's figures.
  static func focusedPlaceholder(_ app: FocusedProcess, _ state: String) -> String {
    escaped((identityRows(app) + [state]).joined(separator: "\n"))
  }

  static let collecting = "Collecting metrics…"
  static let unavailable = "Metrics unavailable"

  /// Binary units with a space: `900 KiB`, `1.5 GiB`.
  static func bytesIEC(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    let number =
      unit == 0 || value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return "\(number) \(units[unit])"
  }

  /// Two units at most: `1d 2h`, `2h 3m`, `5m`, `42s`.
  static func uptime(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
  }

  /// `#` doubled: the status language reads `##` as one literal `#`.
  static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "#", with: "##")
  }

  private static func identityRows(_ app: FocusedProcess) -> [String] {
    let bundle = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    return [row("Bundle", bundle.isEmpty ? "Unavailable" : bundle), row("PID", String(app.pid))]
  }

  private static func row(_ label: String, _ value: String) -> String {
    padded(label, to: labelWidth) + oneLine(value)
  }

  private static func heading(_ title: String) -> String {
    "#[bold]" + escaped(oneLine(title)) + "#[nobold]"
  }

  private static func oneLine(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map {
          switch $0.properties.generalCategory {
          case .control, .lineSeparator, .paragraphSeparator: return "?"
          default: return $0
          }
        }))
  }

  private static func padded(_ text: String, to width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - text.count))
  }

  /// A process name as one table cell: a control character cannot break the
  /// row, a name wider than the column ends in an ellipsis, and a nameless
  /// process shows its pid.
  private static func cellName(_ process: ProcessTable.Process, width: Int = nameWidth) -> String {
    let trimmed = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = oneLine(trimmed)
    if name.isEmpty { return "[\(process.pid)]" }
    guard name.count > width else { return name }
    return String(name.prefix(width - 1)) + "…"
  }
}

/// Which process values a status surface shows, and what each change of that
/// set asks of the sampler: the pure state behind arming and disarming its
/// cadences.
struct ProcessStatusObservation: Equatable {
  enum Cadence: Equatable {
    case arm, disarm, keep
  }

  struct Change: Equatable {
    /// The top tables' shared cadence.
    var top: Cadence = .keep
    /// The focused app's cadence.
    var focused: Cadence = .keep
    /// A top table became observed: sample now rather than a period from now.
    var sampleTopNow = false
    /// `flash.focused_app_details` became observed.
    var sampleFocusedNow = false
    /// Values no longer observed. They clear rather than go stale, so a
    /// surface that shows one again never reads another moment's figures.
    var cleared: Set<ProcessStatusValue> = []
  }

  private(set) var observed: Set<ProcessStatusValue> = []

  var observesTop: Bool { observed.contains { $0.isTopTable } }
  var observesFocused: Bool { observed.contains(.focusedAppDetails) }

  /// Replace the observed set with the controller's complete report.
  mutating func update(_ next: Set<ProcessStatusValue>) -> Change {
    let previous = self
    observed = next
    func cadence(_ was: Bool, _ now: Bool) -> Cadence {
      switch (was, now) {
      case (false, true): return .arm
      case (true, false): return .disarm
      default: return .keep
      }
    }
    return Change(
      top: cadence(previous.observesTop, observesTop),
      focused: cadence(previous.observesFocused, observesFocused),
      sampleTopNow: next.contains { $0.isTopTable && !previous.observed.contains($0) },
      sampleFocusedNow: observesFocused && !previous.observesFocused,
      cleared: previous.observed.subtracting(next))
  }
}

/// Samples the process values while a status surface shows them, and only
/// then: each cadence is registered with the shared clock when its first
/// value becomes observed and dropped when its last one stops. Every read and
/// every format runs on `queue`, never on main; results go back through
/// `publish`, where nil clears a value.
final class ProcessStatusSampler {
  typealias Publish = ([ProcessStatusValue: String?]) -> Void

  static let topPollID = "core:process_top"
  static let focusedPollID = "core:process_focused"
  static let focusSettleID = "core:process_focus_settle"
  /// Fast enough for a desktop widget, slow enough that one libproc pass is
  /// noise.
  static let topPeriodMs = 2_000
  /// CPU use has no change event: the focused app's figures are re-read on
  /// this cadence while shown.
  static let focusedPeriodMs = 10_000
  /// A burst of focus changes (Command-Tab through several apps) reads only
  /// the app the user settles on.
  static let focusSettleMs = 300

  private let queue: DispatchQueue
  private let scheduler: PollScheduler
  private let readProcesses: () -> [ProcessTable.Process]
  private let readTree: (pid_t) -> ProcessTable.Tree?
  private let readMetadata: (FocusedProcess) -> FocusedProcessMetadata
  private let publish: Publish
  private let settle: PollDeadline
  // Confined to `queue`.
  private var observation = ProcessStatusObservation()
  private var topCount = ProcessStatusFormat.defaultTopCount
  private var focused: FocusedProcess?
  private var metadataCache = FocusedProcessMetadataCache()
  private var published: [ProcessStatusValue: String] = [:]
  private var topFailureLogged = false

  init(
    // `.userInitiated` to match the `high` registrations it serves: the table
    // and the focused app's figures are on screen.
    queue: DispatchQueue = DispatchQueue(label: "flash.processes.status", qos: .userInitiated),
    scheduler: PollScheduler = .shared,
    readProcesses: @escaping () -> [ProcessTable.Process] = {
      ProcessTable.shared.processes()
    },
    readTree: @escaping (pid_t) -> ProcessTable.Tree? = { ProcessTable.shared.tree(root: $0) },
    readMetadata: @escaping (FocusedProcess) -> FocusedProcessMetadata = FocusedProcessMetadata
      .read,
    publish: @escaping Publish
  ) {
    self.queue = queue
    self.scheduler = scheduler
    self.readProcesses = readProcesses
    self.readTree = readTree
    self.readMetadata = readMetadata
    self.publish = publish
    settle = PollDeadline(Self.focusSettleID, priority: .high, on: queue, scheduler: scheduler)
  }

  deinit {
    scheduler.unregister(Self.topPollID)
    scheduler.unregister(Self.focusedPollID)
  }

  /// The values the active surfaces show now, complete.
  func observe(_ values: Set<ProcessStatusValue>) {
    queue.async { [weak self] in self?.apply(values) }
  }

  /// `[statusbar] top_count`; the next sample uses it.
  func setTopCount(_ count: Int) {
    queue.async { [weak self] in
      guard let self, self.topCount != count else { return }
      self.topCount = count
      if self.observation.observesTop { self.sampleTop() }
    }
  }

  /// The focused app changed. While its details are shown, its placeholder
  /// shows at once and its figures are read once the focus burst settles.
  func focusChanged(_ app: FocusedProcess?) {
    queue.async { [weak self] in self?.applyFocus(app) }
  }

  /// Wait for every queued change and sample: tests only.
  func drain() { queue.sync {} }

  private func apply(_ values: Set<ProcessStatusValue>) {
    let change = observation.update(values)
    switch change.top {
    case .arm:
      // `.high`: a two-second table someone has open ticks visibly.
      scheduler.register(
        Self.topPollID, everyMs: Self.topPeriodMs, priority: .high, on: queue
      ) { [weak self] in self?.sampleTop() }
    case .disarm:
      scheduler.unregister(Self.topPollID)
    case .keep:
      break
    }
    switch change.focused {
    case .arm:
      // `.normal`: a ten-second refresh of figures on screen, where a tenth
      // of a second of slack is invisible.
      scheduler.register(
        Self.focusedPollID, everyMs: Self.focusedPeriodMs, priority: .normal, on: queue
      ) { [weak self] in self?.sampleFocused() }
    case .disarm:
      scheduler.unregister(Self.focusedPollID)
      settle.cancel()
      metadataCache = .init()
    case .keep:
      break
    }
    if !change.cleared.isEmpty {
      for value in change.cleared { published.removeValue(forKey: value) }
      publish(Dictionary(uniqueKeysWithValues: change.cleared.map { ($0, nil) }))
    }
    if change.sampleTopNow { sampleTop() }
    if change.sampleFocusedNow, let focused {
      send([
        .focusedAppDetails: ProcessStatusFormat.focusedPlaceholder(
          focused, ProcessStatusFormat.collecting)
      ])
      sampleFocused()
    }
  }

  private func applyFocus(_ app: FocusedProcess?) {
    guard app != focused else { return }
    focused = app
    metadataCache = .init()
    settle.cancel()
    guard observation.observesFocused else { return }
    guard let app else {
      published.removeValue(forKey: .focusedAppDetails)
      publish([.focusedAppDetails: nil])
      return
    }
    send([
      .focusedAppDetails: ProcessStatusFormat.focusedPlaceholder(
        app, ProcessStatusFormat.collecting)
    ])
    // `.high`: the placeholder on screen is waiting for it.
    settle.arm(afterMs: Self.focusSettleMs) { [weak self] in self?.sampleFocused() }
  }

  /// One table read, every observed table published if it changed. A tick
  /// that raced a disarm finds nothing observed and does not read; a failed
  /// read keeps the last tables.
  private func sampleTop() {
    let kinds = ProcessStatusValue.allCases.filter {
      $0.isTopTable && observation.observed.contains($0)
    }
    guard !kinds.isEmpty else { return }
    let processes = readProcesses()
    guard !processes.isEmpty else {
      if !topFailureLogged {
        topFailureLogged = true
        FlashLog.warn("[processes] top sample failed; keeping the last tables")
      }
      return
    }
    topFailureLogged = false
    var changes: [ProcessStatusValue: String] = [:]
    for kind in kinds {
      changes[kind] = ProcessStatusFormat.topTable(kind, processes: processes, count: topCount)
    }
    send(changes)
  }

  /// The focused app's figures, or its placeholder when they cannot be read.
  private func sampleFocused() {
    guard observation.observesFocused, let app = focused else { return }
    guard let tree = readTree(app.pid) else {
      metadataCache = .init()
      send([
        .focusedAppDetails: ProcessStatusFormat.focusedPlaceholder(
          app, ProcessStatusFormat.unavailable)
      ])
      return
    }
    let metadata = metadataCache.read(app, startAbstime: tree.startAbstime, using: readMetadata)
    let text = ProcessStatusFormat.focusedDetails(app, tree, metadata: metadata)
    send([.focusedAppDetails: text])
  }

  /// Publish what changed among values still observed.
  private func send(_ values: [ProcessStatusValue: String]) {
    let changed = values.filter {
      observation.observed.contains($0.key) && published[$0.key] != $0.value
    }
    guard !changed.isEmpty else { return }
    published.merge(changed) { _, new in new }
    publish(changed.mapValues { Optional($0) })
  }
}
