import AppKit
import Darwin
import FlashCore
import Foundation
import QuartzCore

enum FlashStatusTextColor: Equatable {
  case defaultForeground
  case defaultBackground
  /// A numbered xterm-256 palette entry (`colourNNN` / `colorNNN`).
  case palette(UInt8)
  /// A literal `#RRGGBB` value.
  case rgb(UInt32)

  // Historical spellings kept for tests and call sites that named the four
  // colours the bar supported before the full palette existed.
  static let colour0 = FlashStatusTextColor.palette(0)
  static let colour178 = FlashStatusTextColor.palette(178)
  static let colour245 = FlashStatusTextColor.palette(245)
  static let colour196 = FlashStatusTextColor.palette(196)
  static let red = FlashStatusTextColor.palette(196)
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
  /// Target opened when this run is clicked. Populated from
  /// `#[link=URL]…#[nolink]` markers; nil for non-interactive text.
  var link: String?

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
    breathing: Bool = false,
    link: String? = nil
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
    self.link = link
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
  /// Per-source poll cadence from `#{script=N:…}` / `#{command=N:…}` /
  /// `#{cycle=R/N:…}`. `nil` falls back to the global `[statusbar]
  /// interval` (cycles default to `max(rotation, interval)` so a rotating
  /// source isn't re-fetched faster than it can even show a line).
  var refreshSeconds: TimeInterval?

  init(
    argv: [String],
    timeoutSeconds: TimeInterval = 6,
    refreshSeconds: TimeInterval? = nil
  ) {
    self.argv = argv
    self.timeoutSeconds = timeoutSeconds
    self.refreshSeconds = refreshSeconds
  }

  static func script(
    _ path: String,
    timeoutSeconds: TimeInterval = 6,
    refreshSeconds: TimeInterval? = nil
  ) -> FlashStatusBarCommand {
    FlashStatusBarCommand(
      argv: ["/bin/sh", path], timeoutSeconds: timeoutSeconds, refreshSeconds: refreshSeconds)
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
    timeoutSeconds: TimeInterval = 6,
    refreshSeconds: TimeInterval? = nil
  ) -> FlashStatusBarCommand {
    var argv: [String] = ["/bin/sh", path]
    argv.append(contentsOf: args)
    return FlashStatusBarCommand(
      argv: argv, timeoutSeconds: timeoutSeconds, refreshSeconds: refreshSeconds)
  }

  static func shell(
    _ command: String,
    timeoutSeconds: TimeInterval = 6,
    refreshSeconds: TimeInterval? = nil
  ) -> FlashStatusBarCommand {
    FlashStatusBarCommand(
      argv: ["/bin/sh", "-lc", command], timeoutSeconds: timeoutSeconds,
      refreshSeconds: refreshSeconds)
  }

}

enum FlashStatusBarSource: Equatable {
  case sdk(FlashStatusBarSDKValue)
  case plugin(FlashStatusBarPluginValue)
  case tmux(String)
  case command(FlashStatusBarCommand)
  /// Like `.command`, but the script's output is split into lines and shown one
  /// at a time, rotating (sliding up) every `periodSeconds`. The current line is
  /// what's published, so a `#[link=…]` marker on it makes the click target
  /// track whatever line is showing.
  case cycle(command: FlashStatusBarCommand, periodSeconds: Int)
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

  /// Variables whose value comes from running a subprocess — both plain
  /// `.command` and `.cycle` (which additionally rotates its lines).
  var commandSections: [FlashStatusBarTemplateVariable] {
    var seen: Set<String> = []
    return variables.filter {
      switch $0.source {
      case .command, .cycle: return true
      default: return false
      }
    }.filter {
      seen.insert($0.id).inserted
    }
  }

  var cycleSections: [FlashStatusBarTemplateVariable] {
    var seen: Set<String> = []
    return variables.filter {
      if case .cycle = $0.source { return true }
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
  var pluginStatuses: [PluginStatus]
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
    pluginStatuses: [PluginStatus] = [],
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
    self.pluginStatuses = pluginStatuses
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
  ///                        visible characters. `#[…]` style/link markers
  ///                        pass through without counting, so styled runs
  ///                        keep their formatting.
  ///   `#{=-N:token}`     → resolve `token`, then truncate to the last N
  ///                        visible characters (trailing window).
  ///   `#{=N…:token}`     → as above but append `…` (ASCII `...` also
  ///   `#{=-N…:token}`      accepted) when the value was actually trimmed;
  ///                        the glyph counts toward N.
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

  /// One Unicode ellipsis glyph stands in for the trimmed-away text. A
  /// single-cell character keeps the visible-length budget honest: a
  /// truncated `#{=N…:…}` run is exactly `N` visible characters wide.
  static let truncationEllipsis = "…"

  enum Truncation: Equatable {
    /// Keep the first `n` visible characters. `ellipsis` appends `…` when
    /// the value was actually shortened (the glyph counts toward `n`).
    case head(Int, ellipsis: Bool)
    /// Keep the last `n` visible characters; `ellipsis` prepends `…`.
    case tail(Int, ellipsis: Bool)
  }

  /// Split `#{=N:mode}` into (`"mode"`, `.head(N)`), `#{=-N:mode}` into
  /// (`"mode"`, `.tail(N)`), and plain `#{mode}` into (`"mode"`, nil).
  /// Mirrors tmux's `=N:` / `=-N:` length-limit operators, plus a Flash
  /// extension: a trailing `…` (or ASCII `...`) on the width — `#{=N…:…}`
  /// / `#{=-N…:…}` — appends an ellipsis glyph when the value is trimmed.
  static func parseTokenTruncation(_ body: String) -> (token: String, truncation: Truncation?) {
    guard body.hasPrefix("=") else { return (body, nil) }
    let afterEquals = body.dropFirst()
    guard let colon = afterEquals.firstIndex(of: ":") else { return (body, nil) }
    var widthSlice = afterEquals[..<colon]
    let token = String(afterEquals[afterEquals.index(after: colon)...]).trimmed
    var ellipsis = false
    if widthSlice.hasSuffix("…") {
      ellipsis = true
      widthSlice = widthSlice.dropLast()
    } else if widthSlice.hasSuffix("...") {
      ellipsis = true
      widthSlice = widthSlice.dropLast(3)
    }
    let isTail = widthSlice.first == "-"
    let digits = isTail ? widthSlice.dropFirst() : widthSlice
    guard let width = Int(digits), width > 0 else { return (body, nil) }
    return (token, isTail ? .tail(width, ellipsis: ellipsis) : .head(width, ellipsis: ellipsis))
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

  /// Truncation walks the token stream, so `#[…]` markers are zero-width
  /// AND survive the cut on either side — the old character walk dropped
  /// trailing markers, which is how a >80-char cycle line lost its
  /// `#[nocyc]` sentinel and silently killed the slide animation.
  static func applyTruncation(_ value: String, truncation: Truncation) -> String {
    let (limit, fromTail, ellipsis): (Int, Bool, Bool)
    switch truncation {
    case .head(let n, let e): (limit, fromTail, ellipsis) = (n, false, e)
    case .tail(let n, let e): (limit, fromTail, ellipsis) = (n, true, e)
    }
    let tokens = FlashStatusBarMarkup.tokenizeValue(value)
    guard FlashStatusBarMarkup.visibleCount(tokens) > limit else { return value }
    return FlashStatusBarMarkup.serialize(
      FlashStatusBarMarkup.truncate(
        tokens, limit: limit, fromTail: fromTail, ellipsis: ellipsis))
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
      return resolvePlugin(value, statuses: context.pluginStatuses)
    case .tmux(let name):
      return resolveTmux(name, context: context)
    case .command:
      return FlashStatusBarRenderer.stripClickRanges(
        from: dynamicValues[variable.id]?.trimmed ?? "")
    case .cycle:
      // A cycle publishes its current line into `dynamicValues[id]` (with its
      // own `#[link=…]` marker), so it reads back like a command — but wrapped
      // in `#[cyc]…#[nocyc]` sentinels so the renderer can pull the rotating run
      // into its own clipped layer and slide it. The sentinels are zero-width
      // `#[…]` markers, so truncation/measurement ignore them, and an
      // unhandled region renders them as nothing.
      let line = FlashStatusBarRenderer.stripClickRanges(
        from: dynamicValues[variable.id]?.trimmed ?? "")
      return line.isEmpty ? "" : "#[cyc]" + line + "#[nocyc]"
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
    statuses: [PluginStatus]
  ) -> String {
    switch value {
    case .loadedCount:
      return "\(statuses.count)"
    case .readyCount:
      return "\(statuses.filter { $0.state == "ready" }.count)"
    case .errorCount:
      return "\(statuses.filter { ($0.lastError ?? "").isEmpty == false }.count)"
    case .statusSegment(let pluginID, let name):
      guard
        let text = statuses.first(where: { $0.id == pluginID })?
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
  /// Shared formatter — allocating a DateFormatter per publish is the kind
  /// of avoidable churn a once-a-minute clock doesn't deserve. Reconfigured
  /// per call (cheap) because tests pass custom calendars/locales; safe
  /// because every production caller sits on the controller's single serial
  /// queue.
  private static let dateFormatter = DateFormatter()

  static func dateText(
    now: Date,
    calendar: Calendar = .current,
    locale: Locale = Locale(identifier: "en_US_POSIX")
  ) -> String {
    let formatter = Self.dateFormatter
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEE MMM d HH:mm"
    return formatter.string(from: now)
  }

  static func stripClickRanges(from raw: String) -> String {
    let tokens = FlashStatusBarMarkup.tokenizeValue(raw).compactMap {
      token -> FlashStatusBarMarkup.Token? in
      guard case .marker(let parts) = token else { return token }
      let stripped = parts.filter { $0 != "norange" && !$0.hasPrefix("range=") }
      return stripped.isEmpty ? nil : .marker(stripped)
    }
    return FlashStatusBarMarkup.serialize(tokens)
  }

  static func segments(from raw: String) -> [FlashStatusTextSegment] {
    var style = FlashStatusTextStyle()
    var link: String?
    var segments: [FlashStatusTextSegment] = []
    var buffer = ""

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
          breathing: style.breathing,
          link: link))
      buffer = ""
    }

    for token in FlashStatusBarMarkup.tokenizeValue(raw) {
      switch token {
      case .text(let text):
        buffer += text
      case .marker(let parts):
        flush()
        applyLinkMarker(parts, to: &link)
        applyTmuxMarker(parts, to: &style)
      case .variable(let body):
        // Values are never recursively expanded — a `#{…}` in dynamic
        // output is literal text.
        buffer += "#{\(body)}"
      case .alias(let ch):
        buffer += "#\(ch)"
      }
    }
    flush()
    return segments
  }

  /// Update the active link target from a `#[…]` marker body. `link=URL`
  /// opens `URL` on click; `nolink` (or the tmux-native `norange`) closes
  /// the run. Other tokens are left to `applyTmuxMarker`. URLs must be
  /// whitespace/comma-free (the marker tokenizer splits on both) — fine
  /// for ordinary http(s) links.
  static func applyLinkMarker(_ parts: [String], to link: inout String?) {
    for token in parts {
      if token == "nolink" || token == "norange" {
        link = nil
      } else if token.hasPrefix("link=") {
        let url = String(token.dropFirst("link=".count))
        link = url.isEmpty ? nil : url
      }
    }
  }

  /// Measure the clickable runs in `raw` against `font`. Returns each
  /// linked run's x-offset (from the text's leading edge, before any
  /// alignment padding) and width, plus the total rendered width so the
  /// caller can offset for centre/right alignment. Widths are measured the
  /// same way the renderer lays the text out, so the rects line up exactly.
  static func linkRuns(
    from raw: String,
    font: NSFont
  ) -> (runs: [(xOffset: CGFloat, width: CGFloat, url: String)], totalWidth: CGFloat) {
    var runs: [(xOffset: CGFloat, width: CGFloat, url: String)] = []
    var x: CGFloat = 0
    for segment in segments(from: raw) {
      let width = FlashStatusBarRenderer.attributedSegment(segment, font: font).size().width
      if let url = segment.link {
        // Merge directly-adjacent runs that share a target so a styled
        // link (e.g. coloured + bold spans) registers one rect.
        if var last = runs.last, last.url == url,
          abs(last.xOffset + last.width - x) < 0.5
        {
          last.width += width
          runs[runs.count - 1] = last
        } else {
          runs.append((xOffset: x, width: width, url: url))
        }
      }
      x += width
    }
    return (runs, x)
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
    let bg =
      segment.background == .defaultBackground && !segment.reverse
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
      // 10 s cycle — well under a baseline meditation breath (~6 s) so
      // the chip never feels like it's *signalling*, just sitting
      // there alive. Alpha rides [0.80, 1.0] — 20 % swing, ~13 %
      // luminance drop on the dark Nord chip, the smallest band that
      // still registers as motion in the user's periphery without
      // pulling attention. Knobs tunable here in one place.
      let period: TimeInterval = 10.0
      let phase = (currentTime.truncatingRemainder(dividingBy: period)) / period
      let sine = sin(phase * 2 * .pi)
      let low: CGFloat = 0.80
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

  private static func applyTmuxMarker(_ parts: [String], to style: inout FlashStatusTextStyle) {
    for token in parts {
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
          style.foreground = FlashStatusTextColor.parse(String(token.dropFirst(3)))
        } else if token.hasPrefix("bg=") {
          let parsed = FlashStatusTextColor.parse(String(token.dropFirst(3)))
          style.background = parsed == .defaultForeground ? .defaultBackground : parsed
        }
      }
    }
  }

  private static func nsColor(for color: FlashStatusTextColor) -> NSColor {
    FlashStatusTextColor.nsColor(color)
  }
}

final class FlashStatusBarController {
  /// 4 fps. The breathing curve has a 10-second period, so this still gives it
  /// 40 tiny alpha steps per cycle; blink reacts within 250 ms. Redrawing a
  /// CATextLayer requires real AppKit/WindowServer work even when geometry is
  /// unchanged, so a display-rate timer would waste CPU for no visible gain.
  static let effectsTickMilliseconds = 250

  private weak var overlay: OverlayPanel?
  private let queue = DispatchQueue(label: "flash.status_bar", qos: .utility)
  /// Concurrent so one slow section (a script waiting on the network) can't
  /// starve the others' cadences. Concurrency is bounded: each section runs
  /// at most one subprocess at a time (`inFlight`), and each blocked
  /// semaphore wait is capped by the command timeout — so the worst case
  /// parks #sections threads for a few seconds, never a growing pool.
  private let commandQueue = DispatchQueue(
    label: "flash.status_bar.commands", qos: .utility, attributes: .concurrent)
  private var template: FlashStatusBarTemplate
  private let pluginStatusesProvider: () -> [PluginStatus]
  private var refreshTimer: DispatchSourceTimer?
  private var effectsTimer: DispatchSourceTimer?
  private var cycleTimer: DispatchSourceTimer?
  /// Per-`#{cycle:…}` variable: its output lines, which one is showing, its
  /// rotation period, and when it last rotated. Refreshed (re-run) on its
  /// own poll cadence; rotated by `cycleTimer`.
  private struct CycleState {
    var lines: [String]
    var index: Int
    var periodSeconds: Int
    var lastRotate: Date
  }
  private var cycles: [String: CycleState] = [:]
  /// Per command/cycle section: when it next runs and whether a run is in
  /// flight. A section whose deadline passes while it's still in flight is
  /// skipped (tick dropped, not queued) — but only that section's.
  private struct CommandSchedule {
    var nextDueAt: Date
    var inFlight: Bool
  }
  private var commandSchedules: [String: CommandSchedule] = [:]
  private var started = false
  private var commandRefreshGeneration: UInt64 = 0
  private var nextClockRefreshAt: Date?
  private var refreshIntervalSeconds: TimeInterval
  private var dynamicValues: [String: String] = [:]
  private var activeAppName = ""
  private var activeBundleIdentifier = ""
  private var modeLabel = "INSERT"
  private var lastPublishedModel: FlashStatusBarModel?

  init(
    overlay: OverlayPanel,
    template: FlashStatusBarTemplate,
    refreshIntervalSeconds: TimeInterval = 5,
    pluginStatusesProvider: @escaping () -> [PluginStatus] = { [] }
  ) {
    self.overlay = overlay
    self.template = template
    self.pluginStatusesProvider = pluginStatusesProvider
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
      self.refreshTimer?.cancel()
      self.refreshTimer = nil
      self.commandSchedules = [:]
      self.nextClockRefreshAt = nil
      self.effectsTimer?.cancel()
      self.effectsTimer = nil
      self.cycleTimer?.cancel()
      self.cycleTimer = nil
      self.commandRefreshGeneration &+= 1
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

  func updateTemplate(
    _ template: FlashStatusBarTemplate,
    refreshIntervalSeconds: TimeInterval? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.template = template
      if let refreshIntervalSeconds {
        self.refreshIntervalSeconds = refreshIntervalSeconds
      }
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

  /// The effective poll cadence for a command/cycle section. `nil` means
  /// "run once when the template loads, never re-poll" — either the global
  /// interval is 0 (tmux's `status-interval 0` convention) and the source
  /// has no explicit `=N`, or the source isn't command-backed at all.
  static func effectiveRefreshSeconds(
    source: FlashStatusBarSource,
    globalSeconds: TimeInterval
  ) -> TimeInterval? {
    switch source {
    case .command(let command):
      if let explicit = command.refreshSeconds { return explicit }
      return globalSeconds > 0 ? globalSeconds : nil
    case .cycle(let command, let rotationSeconds):
      if let explicit = command.refreshSeconds { return explicit }
      // A cycle shows one line per rotation, so re-fetching faster than it
      // rotates is pure waste — the user's HN feed was re-running its
      // script every 5 s for a value rotated once a minute.
      guard globalSeconds > 0 else { return nil }
      return max(TimeInterval(rotationSeconds), globalSeconds)
    default:
      return nil
    }
  }

  /// Kick off every command/cycle section whose deadline has passed and
  /// that isn't already running. Each section runs as its own job on the
  /// concurrent command queue, so cadences are independent.
  private func runDueCommandSections(now: Date) {
    let generation = commandRefreshGeneration
    for section in template.commandSections {
      if let schedule = commandSchedules[section.id],
        schedule.inFlight || schedule.nextDueAt > now
      {
        continue
      }
      let interval = Self.effectiveRefreshSeconds(
        source: section.source, globalSeconds: refreshIntervalSeconds)
      let nextDue = interval.map { now.addingTimeInterval(max(1, $0)) } ?? Date.distantFuture
      commandSchedules[section.id] = CommandSchedule(nextDueAt: nextDue, inFlight: true)
      runCommandSection(section, generation: generation)
    }
  }

  private func runCommandSection(
    _ section: FlashStatusBarTemplateVariable,
    generation: UInt64
  ) {
    commandQueue.async { [weak self] in
      guard let self else { return }
      var update: String?
      var cycleUpdate: (lines: [String], period: Int)?
      switch section.source {
      case .command(let command):
        update = self.runCommand(command)
      case .cycle(let command, let period):
        // A failed/empty run keeps the previous lines (stale-while-refresh,
        // same contract as plain command sections).
        if let lines = self.runCommandLines(command) { cycleUpdate = (lines, period) }
      default:
        break
      }
      self.queue.async { [weak self] in
        guard let self else { return }
        // A stale generation means the template changed (or the bar
        // stopped) while this ran: the schedule map was rebuilt, so
        // touching it here would clobber the replacement's state.
        guard generation == self.commandRefreshGeneration else { return }
        self.commandSchedules[section.id]?.inFlight = false
        if let update { self.dynamicValues[section.id] = update }
        if let cycleUpdate {
          self.applyCycleRefresh(
            id: section.id, lines: cycleUpdate.lines, period: cycleUpdate.period)
          self.armCycleTimer()
        }
        self.publishCurrentModel()
        // The completed section's next deadline may now be the soonest —
        // and if it already passed while the run was in flight, this
        // re-arm fires it promptly instead of dropping the cadence.
        self.armRefreshTimer()
      }
    }
  }

  /// Fold a fresh run's lines into a cycle's state, keeping the currently shown
  /// index where possible so a re-fetch doesn't jump the visible line.
  private func applyCycleRefresh(id: String, lines: [String], period: Int) {
    var state =
      cycles[id]
      ?? CycleState(lines: [], index: 0, periodSeconds: period, lastRotate: Date())
    state.lines = lines
    state.periodSeconds = period
    if state.index >= lines.count { state.index = 0 }
    cycles[id] = state
    dynamicValues[id] = lines.isEmpty ? "" : lines[state.index]
    FlashLog.debug("[statusbar] cycle refresh id=\(id) lines=\(lines.count) index=\(state.index)")
  }

  /// Rotate cycles on their period. A single 1s timer drives it; `tickCycles`
  /// advances only cycles whose period has actually elapsed (time-based, off
  /// `lastRotate`). Armed once and left running — re-creating it on every
  /// command refresh would reset its deadline and it would never fire.
  private func armCycleTimer() {
    guard cycleTimer == nil else { return }
    guard cycles.values.contains(where: { $0.lines.count > 1 }) else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in self?.tickCycles() }
    cycleTimer = timer
    timer.resume()
  }

  private func tickCycles() {
    // Park the 1 s ticker whenever no cycle actually has anything to rotate
    // (single-line output, empty template, …) — otherwise it wakes 86,400×
    // a day for nothing. `armCycleTimer` re-arms it after the next refresh
    // that produces a rotatable cycle.
    guard cycles.values.contains(where: { $0.lines.count > 1 }) else {
      cycleTimer?.cancel()
      cycleTimer = nil
      return
    }
    let now = Date()
    var changed = false
    for id in Array(cycles.keys) {
      guard var state = cycles[id], state.lines.count > 1 else { continue }
      guard now.timeIntervalSince(state.lastRotate) >= Double(state.periodSeconds) - 0.5 else {
        continue
      }
      state.index = (state.index + 1) % state.lines.count
      state.lastRotate = now
      cycles[id] = state
      dynamicValues[id] = state.lines[state.index]
      changed = true
      FlashLog.debug("[statusbar] cycle rotate id=\(id) index=\(state.index)/\(state.lines.count)")
    }
    if changed { publishCurrentModel() }
  }

  private func refreshSourcesForCurrentTemplate() {
    refreshTimer?.cancel()
    refreshTimer = nil
    cycleTimer?.cancel()
    cycleTimer = nil
    cycles = cycles.filter { id, _ in template.cycleSections.contains { $0.id == id } }
    commandSchedules = [:]
    nextClockRefreshAt = nil
    commandRefreshGeneration &+= 1

    publishCurrentModel()
    runDueCommandSections(now: Date())
    scheduleNextClockRefresh(from: Date())
    armRefreshTimer()
  }

  private func scheduleNextClockRefresh(from now: Date) {
    guard template.needsClockRefresh else {
      nextClockRefreshAt = nil
      return
    }
    nextClockRefreshAt = now.addingTimeInterval(
      TimeInterval(nextClockRefreshDelayMilliseconds(from: now)) / 1_000)
  }

  private func armRefreshTimer() {
    refreshTimer?.cancel()
    refreshTimer = nil
    // In-flight sections are excluded: their (already-passed or upcoming)
    // deadline can't be acted on until the run returns, and including it
    // would spin the timer against the in-flight guard. The completion
    // handler re-arms, which picks the deadline back up.
    var dates = commandSchedules.values
      .filter { !$0.inFlight && $0.nextDueAt != .distantFuture }
      .map(\.nextDueAt)
    if let clock = nextClockRefreshAt { dates.append(clock) }
    guard let next = dates.min() else { return }
    let delayMs = max(1, Int(next.timeIntervalSinceNow * 1_000))
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .milliseconds(delayMs),
      leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.handleRefreshTimerFired()
    }
    refreshTimer = timer
    timer.resume()
  }

  private func handleRefreshTimerFired() {
    refreshTimer?.cancel()
    refreshTimer = nil
    let now = Date()
    runDueCommandSections(now: now)
    if let due = nextClockRefreshAt, due <= now {
      publishCurrentModel()
      scheduleNextClockRefresh(from: now)
    }
    armRefreshTimer()
  }

  private func nextClockRefreshDelayMilliseconds(from date: Date = Date()) -> Int {
    let now = date.timeIntervalSince1970
    let nextMinute = (floor(now / 60) + 1) * 60
    return max(250, Int((nextMinute - now) * 1_000))
  }

  private func publishCurrentModel() {
    let context = FlashStatusBarContext(
      activeAppName: activeAppName,
      activeBundleIdentifier: activeBundleIdentifier,
      modeLabel: modeLabel,
      pluginStatuses: pluginStatusesProvider())
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

  /// Advances only the attributed strings carrying time-based effects. Text,
  /// geometry, link targets, and screen layout are unchanged by an effect tick,
  /// so re-publishing the complete model here would wastefully rebuild the
  /// entire status bar at 20 fps.
  private func tickEffects() {
    guard lastPublishedModel != nil else { return }
    DispatchQueue.main.async { [weak overlay] in
      overlay?.refreshStatusBarEffects()
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
    guard effectsTimer != nil else { return }
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

  /// Single-line command value (stdout trimmed; nil if empty).
  private func runCommand(_ command: FlashStatusBarCommand) -> String? {
    let trimmed = runCommandOutput(command)?.trimmed
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  /// Multi-line command value for `#{cycle:…}` — one non-empty line per entry,
  /// each trimmed. nil if the command produced nothing.
  private func runCommandLines(_ command: FlashStatusBarCommand) -> [String]? {
    guard let output = runCommandOutput(command) else { return nil }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0).trimmed }
      .filter { !$0.isEmpty }
    return lines.isEmpty ? nil : lines
  }

  private func runCommandOutput(_ command: FlashStatusBarCommand) -> String? {
    guard let executable = command.argv.first, !executable.isEmpty else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: expandHome(executable))
    process.arguments = command.argv.dropFirst().map(expandHome)
    FlashProcessEnvironment.shared.apply(to: process)
    let stdout = Pipe()
    process.standardOutput = stdout
    // Discard stderr through the shared null device. An unread stderr `Pipe()`
    // can fill its ~64KB buffer and wedge the child before it exits.
    process.standardError = FileHandle.nullDevice

    // Signal completion from `terminationHandler` rather than parking a pooled
    // GCD thread in `waitUntilExit()`. A status command that hangs and ignores
    // SIGTERM would otherwise leak that blocked thread on every refresh until
    // the dispatch pool (soft limit ~70) is exhausted — which then starves even
    // Apple Event delivery, so `flash <verb>` (e.g. a script's `alert_show`)
    // starts timing out with errAETimeout (-1712). Only the dedicated command
    // queue blocks here, never a shared pool thread.
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    do {
      try process.run()
    } catch {
      return nil
    }

    if semaphore.wait(timeout: .now() + command.timeoutSeconds) == .timedOut {
      let pid = process.processIdentifier
      process.terminate()  // SIGTERM
      // Escalate to SIGKILL shortly after if it's still alive, without blocking
      // this queue or parking a thread on the process.
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
        if process.isRunning { kill(pid, SIGKILL) }
      }
      return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  private func expandHome(_ raw: String) -> String {
    guard raw == "~" || raw.hasPrefix("~/") else { return raw }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if raw == "~" { return home }
    return home + String(raw.dropFirst())
  }
}
