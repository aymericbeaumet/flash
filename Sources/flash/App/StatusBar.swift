import AppKit
import Foundation

enum FlashStatusTextColor: Equatable {
  case defaultForeground
  case defaultBackground
  case colour0
  case colour178
  case colour245
  case colour196
  case red
}

struct FlashStatusTextSegment: Equatable {
  var text: String
  var foreground: FlashStatusTextColor
  var background: FlashStatusTextColor
  var bold: Bool
  var italics: Bool
  var underline: Bool
  var dim: Bool
  var reverse: Bool

  init(
    text: String,
    foreground: FlashStatusTextColor,
    background: FlashStatusTextColor = .defaultBackground,
    bold: Bool = false,
    italics: Bool = false,
    underline: Bool = false,
    dim: Bool = false,
    reverse: Bool = false
  ) {
    self.text = text
    self.foreground = foreground
    self.background = background
    self.bold = bold
    self.italics = italics
    self.underline = underline
    self.dim = dim
    self.reverse = reverse
  }
}

private struct FlashStatusTextStyle {
  var foreground: FlashStatusTextColor = .colour245
  var background: FlashStatusTextColor = .defaultBackground
  var bold = false
  var italics = false
  var underline = false
  var dim = false
  var reverse = false
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

  static func script(_ path: String, timeoutSeconds: TimeInterval = 6)
    -> FlashStatusBarCommand
  {
    FlashStatusBarCommand(argv: ["/bin/sh", path], timeoutSeconds: timeoutSeconds)
  }

  static func shell(_ command: String, timeoutSeconds: TimeInterval = 6)
    -> FlashStatusBarCommand
  {
    FlashStatusBarCommand(argv: ["/bin/sh", "-lc", command], timeoutSeconds: timeoutSeconds)
  }

}

enum FlashStatusBarSource: Equatable {
  case sdk(FlashStatusBarSDKValue)
  case plugin(FlashStatusBarPluginValue)
  case command(FlashStatusBarCommand)
}

struct FlashStatusBarTemplateVariable: Equatable {
  var id: String
  var token: String
  var source: FlashStatusBarSource
}

struct FlashStatusBarTemplate: Equatable {
  /// Unified template string. `#[align=left|centre|right]` markers split
  /// the rendered output into three buckets (left / centre / right); style
  /// markers (`#[fg=…]`) and template variables (`#{token}`) are passed
  /// through to the per-region renderer unchanged.
  var template: String
  var variables: [FlashStatusBarTemplateVariable]

  var commandSections: [FlashStatusBarTemplateVariable] {
    var seen: Set<String> = []
    return variables.filter {
      if case .command = $0.source { return true }
      return false
    }.filter {
      seen.insert($0.id).inserted
    }
  }

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
  enum Alignment: Equatable {
    case left
    case centre
    case right
  }

  static func render(
    template: FlashStatusBarTemplate,
    context: FlashStatusBarContext,
    dynamicValues: [String: String] = [:]
  ) -> FlashStatusBarModel {
    var variableByToken: [String: FlashStatusBarTemplateVariable] = [:]
    for variable in template.variables where variableByToken[variable.token] == nil {
      variableByToken[variable.token] = variable
    }

    let split = renderAligned(
      template.template,
      variableByToken: variableByToken,
      context: context,
      dynamicValues: dynamicValues)
    return FlashStatusBarModel(
      appText: split.centre,
      modeText: split.left,
      rightText: split.right)
  }

  /// Parse `template` and split it into left/centre/right buckets driven
  /// by `#[align=…]` markers. Style markers (`#[fg=…]`, `#[bold=true]`)
  /// are kept verbatim in the bucket so the per-region renderer can apply
  /// them. Template variables (`#{token}`) are resolved against
  /// `variableByToken`. Tmux-flavoured extras supported here:
  ///   `##`               → literal `#`
  ///   `#{=N:token}`      → resolve `token`, then truncate to the first N
  ///                        visible characters (no terminal escape
  ///                        awareness — Flash's renderer drives the
  ///                        styling separately).
  ///   `#{=-N:token}`     → resolve `token`, then truncate to the last N
  ///                        visible characters (trailing window).
  static func renderAligned(
    _ raw: String,
    variableByToken: [String: FlashStatusBarTemplateVariable],
    context: FlashStatusBarContext,
    dynamicValues: [String: String]
  ) -> (left: String, centre: String, right: String) {
    var left = ""
    var centre = ""
    var right = ""
    var current: Alignment = .left

    func append(_ text: String) {
      switch current {
      case .left: left += text
      case .centre: centre += text
      case .right: right += text
      }
    }

    var index = raw.startIndex
    while index < raw.endIndex {
      if raw[index] == "#",
        let after = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        after < raw.endIndex
      {
        // `##` → literal `#`. Tmux's documented escape; the previous
        // parser silently consumed the second `#` as a non-marker
        // character which produced surprising output.
        if raw[after] == "#" {
          append("#")
          index = raw.index(after: after)
          continue
        }
        if raw[after] == "[", let close = raw[after...].firstIndex(of: "]") {
          let bodyStart = raw.index(after: after)
          let marker = String(raw[bodyStart..<close])
          if let alignment = parseAlignmentMarker(marker) {
            current = alignment
          } else {
            append("#[\(marker)]")
          }
          index = raw.index(after: close)
          continue
        }
        if raw[after] == "{", let close = raw[after...].firstIndex(of: "}") {
          let bodyStart = raw.index(after: after)
          let body = String(raw[bodyStart..<close]).trimmed
          let (token, truncation) = parseTokenTruncation(body)
          if let variable = variableByToken[token] {
            var value = resolve(
              variable: variable, context: context, dynamicValues: dynamicValues)
            if let truncation {
              value = applyTruncation(value, truncation: truncation)
            }
            append(value)
          }
          index = raw.index(after: close)
          continue
        }
      }
      append(String(raw[index]))
      index = raw.index(after: index)
    }

    return (left, centre, right)
  }

  enum Truncation: Equatable {
    /// Keep the first `n` characters.
    case head(Int)
    /// Keep the last `n` characters.
    case tail(Int)
  }

  /// Split `#{=N:mode}` into (`"mode"`, `.head(N)`), `#{=-N:mode}` into
  /// (`"mode"`, `.tail(N)`), and plain `#{mode}` into (`"mode"`, nil).
  /// Mirrors tmux's `=N:` / `=-N:` length-limit operators.
  static func parseTokenTruncation(_ body: String) -> (token: String, truncation: Truncation?) {
    guard body.hasPrefix("=") else { return (body, nil) }
    let afterEquals = body.dropFirst()
    guard let colon = afterEquals.firstIndex(of: ":") else { return (body, nil) }
    let widthSlice = afterEquals[..<colon]
    let token = String(afterEquals[afterEquals.index(after: colon)...]).trimmed
    let isTail = widthSlice.first == "-"
    let digits = isTail ? widthSlice.dropFirst() : widthSlice
    guard let width = Int(digits), width > 0 else { return (body, nil) }
    return (token, isTail ? .tail(width) : .head(width))
  }

  static func applyTruncation(_ value: String, truncation: Truncation) -> String {
    switch truncation {
    case .head(let n):
      if value.count <= n { return value }
      return String(value.prefix(n))
    case .tail(let n):
      if value.count <= n { return value }
      return String(value.suffix(n))
    }
  }

  /// Recognise an alignment marker body. Returns nil for style markers
  /// (`fg=…`, `bold=true`, …) so they fall through to the per-region
  /// renderer.
  static func parseAlignmentMarker(_ marker: String) -> Alignment? {
    let trimmed = marker.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("align=") else { return nil }
    switch trimmed.dropFirst("align=".count).lowercased() {
    case "left": return .left
    case "centre", "center": return .centre
    case "right": return .right
    default: return nil
    }
  }

  private static func resolve(
    variable: FlashStatusBarTemplateVariable,
    context: FlashStatusBarContext,
    dynamicValues: [String: String]
  ) -> String {
    switch variable.source {
    case .sdk(let value):
      return resolveSDK(value, context: context)
    case .plugin(let value):
      return resolvePlugin(value, snapshots: context.pluginSnapshots)
    case .command:
      return FlashStatusBarRenderer.stripClickRanges(
        from: dynamicValues[variable.id]?.trimmed ?? "")
    }
  }

  private static func resolveSDK(
    _ value: FlashStatusBarSDKValue,
    context: FlashStatusBarContext
  ) -> String {
    switch value {
    case .activeAppName:
      let name = context.activeAppName.trimmed
      if !name.isEmpty { return name }
      return context.activeBundleIdentifier.trimmed
    case .activeBundleIdentifier:
      return context.activeBundleIdentifier.trimmed
    case .modeLabel:
      return context.modeLabel.trimmed
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
        let stripped =
          marker
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
          background: style.background,
          bold: style.bold,
          italics: style.italics,
          underline: style.underline,
          dim: style.dim,
          reverse: style.reverse))
      buffer = ""
    }

    while index < raw.endIndex {
      // `##` → literal `#`.
      if raw[index] == "#",
        let next = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        next < raw.endIndex, raw[next] == "#"
      {
        buffer.append("#")
        index = raw.index(after: next)
        continue
      }
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
      attributed.append(attributedSegment(segment, font: font))
    }
    return attributed
  }

  static func attributedSegment(
    _ segment: FlashStatusTextSegment,
    font: NSFont
  ) -> NSAttributedString {
    // tmux's `reverse` swaps fg + bg; mirror that so `#[reverse]…#[noreverse]`
    // matches what the user expects.
    let foreground =
      segment.reverse ? segment.background : segment.foreground
    let background =
      segment.reverse ? segment.foreground : segment.background
    let fg = nsColor(for: foreground)
    let bg = segment.background == .defaultBackground && !segment.reverse
      ? nil : nsColor(for: background)
    // Dim ~ tmux's reduced-intensity attribute; render at 60% alpha on the
    // foreground colour. We can't dim a bg fill the same way, so leave bg
    // alone for dim.
    let dimmedFg = segment.dim ? fg.withAlphaComponent(0.6) : fg
    let segmentFont: NSFont
    if segment.bold && segment.italics {
      segmentFont = nsFontFor(font, traits: [.boldFontMask, .italicFontMask])
    } else if segment.bold {
      segmentFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
    } else if segment.italics {
      segmentFont = nsFontFor(font, traits: [.italicFontMask])
    } else {
      segmentFont = font
    }
    var attrs: [NSAttributedString.Key: Any] = [
      .font: segmentFont,
      .foregroundColor: dimmedFg,
    ]
    if let bg { attrs[.backgroundColor] = bg }
    if segment.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    return NSAttributedString(string: segment.text, attributes: attrs)
  }

  private static func nsFontFor(_ font: NSFont, traits: NSFontTraitMask) -> NSFont {
    let manager = NSFontManager.shared
    return manager.convert(font, toHaveTrait: traits)
  }

  private static func applyTmuxMarker(_ marker: String, to style: inout FlashStatusTextStyle) {
    let tokens = marker.split { ch in
      ch == " " || ch == ","
    }
    for tokenSub in tokens {
      let token = String(tokenSub)
      switch token {
      case "bold": style.bold = true
      case "nobold": style.bold = false
      case "italics", "italic": style.italics = true
      case "noitalics", "noitalic": style.italics = false
      case "underscore", "underline": style.underline = true
      case "nounderscore", "nounderline": style.underline = false
      case "dim": style.dim = true
      case "nodim": style.dim = false
      case "reverse", "invert": style.reverse = true
      case "noreverse", "noinvert": style.reverse = false
      default:
        if token.hasPrefix("fg=") {
          style.foreground = tmuxColor(String(token.dropFirst(3)))
        } else if token.hasPrefix("bg=") {
          style.background = tmuxColor(String(token.dropFirst(3)))
        }
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
    case .defaultBackground:
      return OverlayPanel.nordPolarNight0
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
  private var template: FlashStatusBarTemplate
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
    template: FlashStatusBarTemplate,
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

  func updateTemplate(_ template: FlashStatusBarTemplate) {
    queue.async { [weak self] in
      guard let self else { return }
      self.template = template
      let commandIDs = Set(template.commandSections.map(\.id))
      self.dynamicValues = self.dynamicValues.filter { commandIDs.contains($0.key) }
      self.refreshCommandSections()
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
    let trimmed = output.trimmed
    return trimmed.isEmpty ? nil : trimmed
  }

  private func expandHome(_ raw: String) -> String {
    guard raw == "~" || raw.hasPrefix("~/") else { return raw }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if raw == "~" { return home }
    return home + String(raw.dropFirst())
  }
}
