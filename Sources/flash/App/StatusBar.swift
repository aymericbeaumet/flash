import AppKit
import Darwin
import Foundation
import QuartzCore

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
  var blink: Bool
  var breathing: Bool

  var hasAnimatedEffect: Bool { blink || breathing }

  init(
    text: String,
    foreground: FlashStatusTextColor,
    background: FlashStatusTextColor = .defaultBackground,
    bold: Bool = false,
    italics: Bool = false,
    underline: Bool = false,
    dim: Bool = false,
    reverse: Bool = false,
    blink: Bool = false,
    breathing: Bool = false
  ) {
    self.text = text
    self.foreground = foreground
    self.background = background
    self.bold = bold
    self.italics = italics
    self.underline = underline
    self.dim = dim
    self.reverse = reverse
    self.blink = blink
    self.breathing = breathing
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
  var blink = false
  var breathing = false
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
  case statusSegment(pluginID: String, name: String)
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

  /// `#{script:path --arg1 --arg2}` form. The trailing whitespace-
  /// separated tokens are passed through as positional argv after the
  /// script path. Quoting / escaping is intentionally absent — the
  /// status-bar templates only ever pass simple option flags here
  /// (`--claude`, `--codex`, …) and the entire string came from
  /// trusted config the user authored.
  static func scriptWithArgs(
    _ path: String,
    args: [String],
    timeoutSeconds: TimeInterval = 6
  ) -> FlashStatusBarCommand {
    var argv: [String] = ["/bin/sh", path]
    argv.append(contentsOf: args)
    return FlashStatusBarCommand(argv: argv, timeoutSeconds: timeoutSeconds)
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
  case tmux(String)
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

  var needsClockRefresh: Bool {
    variables.contains {
      if case .sdk(.date) = $0.source { return true }
      return false
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
  var hostName: String
  var userName: String
  var userID: UInt32
  var processID: Int32

  init(
    activeAppName: String = "",
    activeBundleIdentifier: String = "",
    modeLabel: String = "INSERT",
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = Locale(identifier: "en_US_POSIX"),
    pluginSnapshots: [PluginStatusSnapshot] = [],
    hostName: String = ProcessInfo.processInfo.hostName,
    userName: String = NSUserName(),
    userID: UInt32 = getuid(),
    processID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) {
    self.activeAppName = activeAppName
    self.activeBundleIdentifier = activeBundleIdentifier
    self.modeLabel = modeLabel
    self.now = now
    self.calendar = calendar
    self.locale = locale
    self.pluginSnapshots = pluginSnapshots
    self.hostName = hostName
    self.userName = userName
    self.userID = userID
    self.processID = processID
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
    let raw = normalizedTemplate(raw)
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
          let variable =
            variableByToken[token]
            ?? (isTmuxFormatVariable(token)
              ? FlashStatusBarTemplateVariable(
                id: "statusbar.template.\(token)",
                token: token,
                source: .tmux(token))
              : nil)
          if let variable {
            var value = resolve(variable: variable, context: context, dynamicValues: dynamicValues)
            if let truncation {
              value = applyTruncation(value, truncation: truncation)
            }
            append(value)
          }
          index = raw.index(after: close)
          continue
        }
        if let token = tmuxShortFormatToken(for: raw[after]) {
          let variable =
            variableByToken[token]
            ?? FlashStatusBarTemplateVariable(
              id: "statusbar.template.\(token)",
              token: token,
              source: .tmux(token))
          append(resolve(variable: variable, context: context, dynamicValues: dynamicValues))
          index = raw.index(after: after)
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

  static func normalizedTemplate(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\r\n", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
  }

  static func tmuxShortFormatToken(for character: Character) -> String? {
    switch character {
    case "H": return "host"
    case "h": return "host_short"
    case "S": return "session_name"
    case "W": return "window_name"
    case "I": return "window_index"
    case "P": return "pane_index"
    case "D": return "pane_id"
    default: return nil
    }
  }

  static func isTmuxFormatVariable(_ token: String) -> Bool {
    let trimmed = token.trimmed
    guard let first = trimmed.first else { return false }
    if first == "@" {
      return trimmed.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    guard first.isLetter || first == "_" else { return false }
    return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
    case .tmux(let name):
      return resolveTmux(name, context: context)
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
    case .statusSegment(let pluginID, let name):
      guard
        let text = snapshots.first(where: { $0.id == pluginID })?
          .statusSegments[name]?
          .trimmed,
        !text.isEmpty
      else { return "" }
      return FlashStatusBarRenderer.stripClickRanges(from: text)
    }
  }

  private static func resolveTmux(_ rawName: String, context: FlashStatusBarContext) -> String {
    let name = rawName.trimmed.lowercased()
    switch name {
    case "host", "hostname":
      return context.hostName.trimmed
    case "host_short":
      let host = context.hostName.trimmed
      guard let dot = host.firstIndex(of: ".") else { return host }
      return String(host[..<dot])
    case "user":
      return context.userName.trimmed
    case "uid":
      return "\(context.userID)"
    case "pid":
      return "\(context.processID)"
    default:
      return ""
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
          reverse: style.reverse,
          blink: style.blink,
          breathing: style.breathing))
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

  static func attributedStatusString(
    from raw: String,
    font: NSFont,
    currentTime: TimeInterval = CACurrentMediaTime()
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments(from: raw) {
      attributed.append(attributedSegment(segment, font: font, currentTime: currentTime))
    }
    return attributed
  }

  static func attributedSegment(
    _ segment: FlashStatusTextSegment,
    font: NSFont,
    currentTime: TimeInterval = 0
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
    let baseDim: CGFloat = segment.dim ? 0.6 : 1.0
    let effectAlpha = effectAlphaMultiplier(segment: segment, currentTime: currentTime)
    let finalAlpha = baseDim * effectAlpha
    let dimmedFg = finalAlpha < 0.999 ? fg.withAlphaComponent(finalAlpha) : fg
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

  /// Pure function so tests can pin a specific time and verify the
  /// curve. Pass `currentTime = 0` (the default for `attributedSegment`)
  /// to disable animation entirely — handy for static snapshot tests
  /// that don't want flapping alpha values.
  static func effectAlphaMultiplier(
    segment: FlashStatusTextSegment,
    currentTime: TimeInterval
  ) -> CGFloat {
    // Sinusoidal breathing on a 6 s period — roughly the cadence of a
    // calm meditation breath (~10 breaths/min). The alpha rides a
    // **very subtle** [0.88, 1.0] band: a 12 % dim at the trough,
    // imperceptible enough that the chip never reads as "broken" or
    // "loading", yet alive enough that the user can spot at a glance
    // that the battery is plugged. The slowest motion happens at the
    // peak and trough (sine has zero derivative there), matching the
    // pause between inhale and exhale.
    var alpha: CGFloat = 1.0
    if segment.breathing {
      let period: TimeInterval = 6.0
      let phase = (currentTime.truncatingRemainder(dividingBy: period)) / period
      let sine = sin(phase * 2 * .pi)
      let low: CGFloat = 0.88
      let high: CGFloat = 1.0
      let mid = (low + high) / 2
      let halfRange = (high - low) / 2
      alpha *= mid + halfRange * CGFloat(sine)
    }
    if segment.blink {
      // Square wave, 1 s period (0.5 s on / 0.5 s off). Tmux's blink
      // attribute is approximately this cadence on terminals that honor
      // it, so the muscle memory carries over.
      let period: TimeInterval = 1.0
      let phase = currentTime.truncatingRemainder(dividingBy: period) / period
      alpha *= phase < 0.5 ? 1.0 : 0.15
    }
    return alpha
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
      // tmux's `blink` attribute — alternates the text at a steady
      // half-second period. Useful for "this needs your attention"
      // signals (low battery, retry timer, …).
      case "blink": style.blink = true
      case "noblink": style.blink = false
      // Flash extension. `breathing` rides a slow opacity sinusoid
      // calibrated to feel like a calm exhale (~4-second cycle, never
      // dimmer than 35%). The battery plugin wraps its percent in
      // `#[breathing]…#[nobreathing]` while charging.
      case "breathing", "breathe": style.breathing = true
      case "nobreathing", "nobreathe": style.breathing = false
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
  /// ~20 fps. Slow enough that the breathing dim feels organic (4-second
  /// period × 80 samples per cycle), fast enough to not introduce a
  /// noticeable stutter when blink toggles. The status-bar re-render is
  /// just an `NSAttributedString` rebuild + a CATextLayer reassignment,
  /// so the per-tick cost is well under a millisecond.
  static let effectsTickMilliseconds = 50

  private weak var overlay: OverlayPanel?
  private let queue = DispatchQueue(label: "flash.status_bar", qos: .utility)
  private let commandQueue = DispatchQueue(label: "flash.status_bar.commands", qos: .utility)
  private var template: FlashStatusBarTemplate
  private let pluginSnapshotsProvider: () -> [PluginStatusSnapshot]
  private var commandTimer: DispatchSourceTimer?
  private var clockTimer: DispatchSourceTimer?
  private var effectsTimer: DispatchSourceTimer?
  private var started = false
  private var commandRefreshGeneration: UInt64 = 0
  private var commandRefreshInFlight = false
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
      guard !self.started else {
        self.publishCurrentModel()
        return
      }
      self.started = true
      self.refreshSourcesForCurrentTemplate()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.commandTimer?.cancel()
      self.commandTimer = nil
      self.clockTimer?.cancel()
      self.clockTimer = nil
      self.effectsTimer?.cancel()
      self.effectsTimer = nil
      self.commandRefreshGeneration &+= 1
      self.commandRefreshInFlight = false
      self.started = false
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
      self.refreshSourcesForCurrentTemplate()
    }
  }

  func refreshPluginSections() {
    queue.async { [weak self] in
      self?.publishCurrentModel()
    }
  }

  private func refreshCommandSections() {
    let sections = template.commandSections
    guard !sections.isEmpty else {
      publishCurrentModel()
      return
    }
    guard !commandRefreshInFlight else { return }
    commandRefreshInFlight = true
    commandRefreshGeneration &+= 1
    let generation = commandRefreshGeneration
    commandQueue.async { [weak self] in
      guard let self else { return }
      var updates: [String: String] = [:]
      for section in sections {
        guard case .command(let command) = section.source else { continue }
        if let output = self.runCommand(command) {
          updates[section.id] = output
        }
      }
      self.queue.async { [weak self] in
        guard let self else { return }
        guard generation == self.commandRefreshGeneration else { return }
        for (id, output) in updates {
          self.dynamicValues[id] = output
        }
        self.commandRefreshInFlight = false
        self.publishCurrentModel()
      }
    }
  }

  private func refreshSourcesForCurrentTemplate() {
    commandTimer?.cancel()
    commandTimer = nil
    clockTimer?.cancel()
    clockTimer = nil
    commandRefreshGeneration &+= 1
    commandRefreshInFlight = false

    if template.commandSections.isEmpty {
      publishCurrentModel()
    } else {
      publishCurrentModel()
      refreshCommandSections()
      scheduleCommandRefresh()
    }
    scheduleClockRefresh()
  }

  private func scheduleCommandRefresh() {
    guard !template.commandSections.isEmpty else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let intervalMs = max(250, Int(refreshIntervalSeconds * 1_000))
    timer.schedule(
      deadline: .now() + .milliseconds(intervalMs),
      repeating: .milliseconds(intervalMs),
      leeway: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      self?.refreshCommandSections()
    }
    commandTimer = timer
    timer.resume()
  }

  private func scheduleClockRefresh() {
    guard template.needsClockRefresh else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(nextClockRefreshDelayMilliseconds()),
      leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.publishCurrentModel()
      self.scheduleClockRefresh()
    }
    clockTimer = timer
    timer.resume()
  }

  private func nextClockRefreshDelayMilliseconds() -> Int {
    let now = Date().timeIntervalSince1970
    let nextMinute = (floor(now / 60) + 1) * 60
    return max(250, Int((nextMinute - now) * 1_000))
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
    let modelChanged = model != lastPublishedModel
    if modelChanged {
      lastPublishedModel = model
      DispatchQueue.main.async { [weak overlay] in
        overlay?.setStatusBarModel(model)
      }
    }
    // Always re-evaluate the effects timer — the same model can flip
    // between "needs animation" and "doesn't" as plugins emit / clear
    // `#[breathing]` markers (the system battery plugin wraps its
    // percent only while charging).
    refreshEffectsTimer(for: model)
  }

  /// Re-publishes the *current* model to the overlay, bypassing the
  /// "skip if unchanged" guard. The renderer reads `CACurrentMediaTime`
  /// when it builds attributed strings, so the per-segment alpha for
  /// `#[breathing]` / `#[blink]` segments advances on each re-publish
  /// even though the underlying text hasn't moved.
  private func tickEffects() {
    guard let model = lastPublishedModel else { return }
    DispatchQueue.main.async { [weak overlay] in
      overlay?.setStatusBarModel(model)
    }
  }

  private func refreshEffectsTimer(for model: FlashStatusBarModel) {
    let needsTick = Self.modelNeedsEffectsTick(model)
    if needsTick {
      startEffectsTimer()
    } else {
      stopEffectsTimer()
    }
  }

  private func startEffectsTimer() {
    guard effectsTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let intervalMs = Self.effectsTickMilliseconds
    timer.schedule(
      deadline: .now() + .milliseconds(intervalMs),
      repeating: .milliseconds(intervalMs),
      leeway: .milliseconds(10))
    timer.setEventHandler { [weak self] in
      self?.tickEffects()
    }
    effectsTimer = timer
    timer.resume()
  }

  private func stopEffectsTimer() {
    effectsTimer?.cancel()
    effectsTimer = nil
  }

  /// Cheap substring check on the rendered model. The actual marker
  /// strings (`#[breathing]`, `#[blink]`) are kept verbatim in the
  /// per-region buckets until `FlashStatusBarRenderer.segments` parses
  /// them at attribute-string-build time — so a plain `contains` here
  /// is enough and saves the cost of running the marker parser on every
  /// publish just to discover "no, nothing to animate".
  static func modelNeedsEffectsTick(_ model: FlashStatusBarModel) -> Bool {
    return regionNeedsEffectsTick(model.appText)
      || regionNeedsEffectsTick(model.modeText)
      || regionNeedsEffectsTick(model.rightText)
  }

  private static func regionNeedsEffectsTick(_ raw: String) -> Bool {
    return raw.contains("#[breathing")
      || raw.contains("#[breathe")
      || raw.contains("#[blink")
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
