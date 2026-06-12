import AppKit
import Foundation

enum FlashStatusTextColor: Equatable {
  case defaultForeground
  case colour0
  case colour178
  case colour245
  case colour196
  case red
}

struct FlashStatusTextSegment: Equatable {
  var text: String
  var foreground: FlashStatusTextColor
  var bold: Bool
}

private struct FlashStatusTextStyle {
  var foreground: FlashStatusTextColor = .colour245
  var bold = false
}

enum FlashStatusBarPlacement: Equatable {
  case leading
  case mode
  case trailing
}

enum FlashStatusBarSDKValue: Equatable {
  case activeAppName
  case activeBundleIdentifier
  case modeLabel
  case date
}

enum FlashStatusBarPluginValue: Equatable {
  case loadedCount
  case readyCount
  case errorCount
}

struct FlashStatusBarCommand: Equatable {
  var argv: [String]
  var timeoutSeconds: TimeInterval

  init(argv: [String], timeoutSeconds: TimeInterval = 6) {
    self.argv = argv
    self.timeoutSeconds = timeoutSeconds
  }

  static func dotfilesScript(_ name: String, timeoutSeconds: TimeInterval = 6)
    -> FlashStatusBarCommand
  {
    FlashStatusBarCommand(
      argv: ["/bin/sh", "~/.dotfiles/scripts/\(name)"],
      timeoutSeconds: timeoutSeconds)
  }
}

enum FlashStatusBarSource: Equatable {
  case sdk(FlashStatusBarSDKValue)
  case plugin(FlashStatusBarPluginValue)
  case command(FlashStatusBarCommand)
}

struct FlashStatusBarTemplateSection: Equatable {
  var id: String
  var placement: FlashStatusBarPlacement
  var source: FlashStatusBarSource
}

struct FlashStatusBarTemplate: Equatable {
  var sections: [FlashStatusBarTemplateSection]
  var trailingSeparator: String

  var commandSections: [FlashStatusBarTemplateSection] {
    sections.filter {
      if case .command = $0.source { return true }
      return false
    }
  }

  static let `default` = FlashStatusBarTemplate(
    sections: [
      FlashStatusBarTemplateSection(
        id: "active_app",
        placement: .leading,
        source: .sdk(.activeAppName)),
      FlashStatusBarTemplateSection(
        id: "mode",
        placement: .mode,
        source: .sdk(.modeLabel)),
      FlashStatusBarTemplateSection(
        id: "agent",
        placement: .trailing,
        source: .command(.dotfilesScript("agent-quota-status.sh"))),
      FlashStatusBarTemplateSection(
        id: "battery",
        placement: .trailing,
        source: .command(.dotfilesScript("battery-status.sh"))),
      FlashStatusBarTemplateSection(
        id: "ip",
        placement: .trailing,
        source: .command(.dotfilesScript("ip-status.sh"))),
      FlashStatusBarTemplateSection(
        id: "date",
        placement: .trailing,
        source: .sdk(.date)),
    ],
    trailingSeparator: "#[fg=colour245] · ")
}

struct FlashStatusBarContext {
  var activeAppName: String
  var activeBundleIdentifier: String
  var modeLabel: String
  var now: Date
  var calendar: Calendar
  var locale: Locale
  var pluginSnapshots: [PluginStatusSnapshot]

  init(
    activeAppName: String = "",
    activeBundleIdentifier: String = "",
    modeLabel: String = "INSERT",
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = Locale(identifier: "en_US_POSIX"),
    pluginSnapshots: [PluginStatusSnapshot] = []
  ) {
    self.activeAppName = activeAppName
    self.activeBundleIdentifier = activeBundleIdentifier
    self.modeLabel = modeLabel
    self.now = now
    self.calendar = calendar
    self.locale = locale
    self.pluginSnapshots = pluginSnapshots
  }
}

struct FlashStatusBarModel: Equatable {
  var appText: String
  var modeText: String
  var rightText: String
}

enum FlashStatusBarTemplateEngine {
  static func render(
    template: FlashStatusBarTemplate,
    context: FlashStatusBarContext,
    dynamicValues: [String: String] = [:]
  ) -> FlashStatusBarModel {
    var leading: [String] = []
    var mode = ""
    var trailing: [String] = []

    for section in template.sections {
      let value = resolve(section: section, context: context, dynamicValues: dynamicValues)
      guard !value.isEmpty else { continue }
      switch section.placement {
      case .leading:
        leading.append(value)
      case .mode:
        if mode.isEmpty { mode = value }
      case .trailing:
        trailing.append(value)
      }
    }

    return FlashStatusBarModel(
      appText: leading.joined(separator: " "),
      modeText: mode.isEmpty ? context.modeLabel : mode,
      rightText: trailing.joined(separator: template.trailingSeparator))
  }

  private static func resolve(
    section: FlashStatusBarTemplateSection,
    context: FlashStatusBarContext,
    dynamicValues: [String: String]
  ) -> String {
    switch section.source {
    case .sdk(let value):
      return resolveSDK(value, context: context)
    case .plugin(let value):
      return resolvePlugin(value, snapshots: context.pluginSnapshots)
    case .command:
      return FlashStatusBarRenderer.stripClickRanges(
        from: dynamicValues[section.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
  }

  private static func resolveSDK(
    _ value: FlashStatusBarSDKValue,
    context: FlashStatusBarContext
  ) -> String {
    switch value {
    case .activeAppName:
      let name = context.activeAppName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
      return context.activeBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    case .activeBundleIdentifier:
      return context.activeBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    case .modeLabel:
      return context.modeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    case .date:
      let date = FlashStatusBarRenderer.dateText(
        now: context.now,
        calendar: context.calendar,
        locale: context.locale)
      return "#[fg=colour178]\(date)"
    }
  }

  private static func resolvePlugin(
    _ value: FlashStatusBarPluginValue,
    snapshots: [PluginStatusSnapshot]
  ) -> String {
    switch value {
    case .loadedCount:
      return "\(snapshots.count)"
    case .readyCount:
      return "\(snapshots.filter { $0.state == "ready" }.count)"
    case .errorCount:
      return "\(snapshots.filter { ($0.lastError ?? "").isEmpty == false }.count)"
    }
  }
}

enum FlashStatusBarRenderer {
  static func rightStatus(
    agent: String?,
    battery: String?,
    ip: String?,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = Locale(identifier: "en_US_POSIX")
  ) -> String {
    let context = FlashStatusBarContext(now: now, calendar: calendar, locale: locale)
    let values = [
      "agent": agent ?? "",
      "battery": battery ?? "",
      "ip": ip ?? "",
    ]
    return FlashStatusBarTemplateEngine.render(
      template: .default,
      context: context,
      dynamicValues: values).rightText
  }

  static func dateText(
    now: Date,
    calendar: Calendar = .current,
    locale: Locale = Locale(identifier: "en_US_POSIX")
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEE MMM d HH:mm"
    return formatter.string(from: now)
  }

  static func stripClickRanges(from raw: String) -> String {
    var result = ""
    var index = raw.startIndex

    while index < raw.endIndex {
      if raw[index] == "#",
        let open = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        open < raw.endIndex,
        raw[open] == "[",
        let close = raw[open...].firstIndex(of: "]")
      {
        let bodyStart = raw.index(after: open)
        let marker = String(raw[bodyStart..<close])
        let stripped = marker
          .split { $0 == " " || $0 == "," }
          .map(String.init)
          .filter { token in
            token != "norange" && !token.hasPrefix("range=")
          }
        if !stripped.isEmpty {
          result += "#[\(stripped.joined(separator: " "))]"
        }
        index = raw.index(after: close)
        continue
      }
      result.append(raw[index])
      index = raw.index(after: index)
    }

    return result
  }

  static func segments(from raw: String) -> [FlashStatusTextSegment] {
    let raw = stripClickRanges(from: raw)
    var style = FlashStatusTextStyle()
    var segments: [FlashStatusTextSegment] = []
    var buffer = ""
    var index = raw.startIndex

    func flush() {
      guard !buffer.isEmpty else { return }
      segments.append(
        FlashStatusTextSegment(
          text: buffer,
          foreground: style.foreground,
          bold: style.bold))
      buffer = ""
    }

    while index < raw.endIndex {
      if raw[index] == "#",
        let open = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        open < raw.endIndex,
        raw[open] == "[",
        let close = raw[open...].firstIndex(of: "]")
      {
        flush()
        let bodyStart = raw.index(after: open)
        let marker = String(raw[bodyStart..<close])
        applyTmuxMarker(marker, to: &style)
        index = raw.index(after: close)
        continue
      }
      buffer.append(raw[index])
      index = raw.index(after: index)
    }
    flush()
    return segments
  }

  static func attributedStatusString(from raw: String, font: NSFont) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments(from: raw) {
      let segmentFont = segment.bold
        ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        : font
      attributed.append(
        NSAttributedString(
          string: segment.text,
          attributes: [
            .font: segmentFont,
            .foregroundColor: nsColor(for: segment.foreground),
          ]))
    }
    return attributed
  }

  private static func applyTmuxMarker(_ marker: String, to style: inout FlashStatusTextStyle) {
    let tokens = marker.split { ch in
      ch == " " || ch == ","
    }
    for tokenSub in tokens {
      let token = String(tokenSub)
      if token == "bold" {
        style.bold = true
      } else if token == "nobold" {
        style.bold = false
      } else if token.hasPrefix("fg=") {
        style.foreground = tmuxColor(String(token.dropFirst(3)))
      }
    }
  }

  private static func tmuxColor(_ raw: String) -> FlashStatusTextColor {
    switch raw {
    case "colour0", "color0":
      return .colour0
    case "colour178", "color178":
      return .colour178
    case "colour245", "color245":
      return .colour245
    case "colour196", "color196":
      return .colour196
    case "red":
      return .red
    default:
      return .defaultForeground
    }
  }

  private static func nsColor(for color: FlashStatusTextColor) -> NSColor {
    switch color {
    case .defaultForeground:
      return OverlayPanel.tmuxGrey245
    case .colour0:
      return OverlayPanel.nordPolarNight0
    case .colour178:
      return OverlayPanel.nordAuroraYellow
    case .colour245:
      return OverlayPanel.tmuxGrey245
    case .colour196, .red:
      return OverlayPanel.tmuxRed196
    }
  }
}

final class FlashStatusBarController {
  private weak var overlay: OverlayPanel?
  private let queue = DispatchQueue(label: "flash.status_bar", qos: .utility)
  private let template: FlashStatusBarTemplate
  private let pluginSnapshotsProvider: () -> [PluginStatusSnapshot]
  private var timer: DispatchSourceTimer?
  private let refreshIntervalSeconds: TimeInterval
  private var dynamicValues: [String: String] = [:]
  private var activeAppName = ""
  private var activeBundleIdentifier = ""
  private var modeLabel = "INSERT"
  private var lastPublishedModel: FlashStatusBarModel?

  init(
    overlay: OverlayPanel,
    template: FlashStatusBarTemplate = .default,
    refreshIntervalSeconds: TimeInterval = 5,
    pluginSnapshotsProvider: @escaping () -> [PluginStatusSnapshot] = { [] }
  ) {
    self.overlay = overlay
    self.template = template
    self.pluginSnapshotsProvider = pluginSnapshotsProvider
    self.refreshIntervalSeconds = refreshIntervalSeconds
  }

  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.timer == nil else {
        self.publishCurrentModel()
        return
      }
      self.publishCurrentModel()

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      let intervalMs = max(250, Int(self.refreshIntervalSeconds * 1_000))
      timer.schedule(
        deadline: .now(),
        repeating: .milliseconds(intervalMs),
        leeway: .milliseconds(250))
      timer.setEventHandler { [weak self] in
        self?.refreshCommandSections()
      }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.timer?.cancel()
      self?.timer = nil
    }
  }

  func updateModeLabel(_ label: String) {
    queue.async { [weak self] in
      self?.modeLabel = label
      self?.publishCurrentModel()
    }
  }

  func updateFocusedApplication(_ app: NSRunningApplication?) {
    queue.async { [weak self] in
      guard let self else { return }
      self.activeAppName = app?.localizedName ?? ""
      self.activeBundleIdentifier = app?.bundleIdentifier ?? ""
      self.publishCurrentModel()
    }
  }

  func refreshPluginSections() {
    queue.async { [weak self] in
      self?.publishCurrentModel()
    }
  }

  private func refreshCommandSections() {
    for section in template.commandSections {
      guard case .command(let command) = section.source else { continue }
      if let output = runCommand(command) {
        dynamicValues[section.id] = output
      }
    }
    publishCurrentModel()
  }

  private func publishCurrentModel() {
    let context = FlashStatusBarContext(
      activeAppName: activeAppName,
      activeBundleIdentifier: activeBundleIdentifier,
      modeLabel: modeLabel,
      pluginSnapshots: pluginSnapshotsProvider())
    let model = FlashStatusBarTemplateEngine.render(
      template: template,
      context: context,
      dynamicValues: dynamicValues)
    guard model != lastPublishedModel else { return }
    lastPublishedModel = model
    DispatchQueue.main.async { [weak overlay] in
      overlay?.setStatusBarModel(model)
    }
  }

  private func runCommand(_ command: FlashStatusBarCommand) -> String? {
    guard let executable = command.argv.first, !executable.isEmpty else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: expandHome(executable))
    process.arguments = command.argv.dropFirst().map(expandHome)
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + command.timeoutSeconds) == .timedOut {
      process.terminate()
      _ = semaphore.wait(timeout: .now() + 0.5)
      return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func expandHome(_ raw: String) -> String {
    guard raw == "~" || raw.hasPrefix("~/") else { return raw }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if raw == "~" { return home }
    return home + String(raw.dropFirst())
  }
}
