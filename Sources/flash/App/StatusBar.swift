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
  /// Named click range from `#[range=user|<name>]…#[norange]` — tmux's
  /// status-line mouse model. The name resolves through the
  /// `[statusbar.click]` action map at click time.
  var range: String?
  /// Named hover popup from `#[popup=<name>]…#[nopopup]`.
  var popup: String?
  /// Popup body carried directly by a dynamic value through
  /// `#[popup=inline:<percent-encoded-markup>]`. Keeping this beside the
  /// visible segment makes carousel text and its details rotate atomically.
  var popupContent: String?

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
    link: String? = nil,
    range: String? = nil,
    popup: String? = nil,
    popupContent: String? = nil
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
    self.range = range
    self.popup = popup
    self.popupContent = popupContent
  }
}

struct FlashStatusPopupRun: Equatable {
  var xOffset: CGFloat
  var width: CGFloat
  var name: String
  var content: String
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
  case host
  case hostShort
  case user
  case uid
  case pid
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
    // `%` literals are strftime-expanded per publish (tmux behaviour), so
    // any percent in the template needs the minute clock too.
    if template.contains("%") { return true }
    return variables.contains {
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
  var pluginStatuses: [PluginStatusBarInfo]
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
    pluginStatuses: [PluginStatusBarInfo] = [],
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
  var popupTexts: [String: String]

  init(
    appText: String,
    modeText: String,
    rightText: String,
    popupTexts: [String: String] = [:]
  ) {
    self.appText = appText
    self.modeText = modeText
    self.rightText = rightText
    self.popupTexts = popupTexts
  }
}

enum FlashStatusBarTemplateEngine {
  enum Alignment: Equatable {
    case left
    case centre
    case right
  }

  static func render(
    template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
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
    var popupTexts: [String: String] = [:]
    for name in popupTemplates.keys.sorted() {
      guard let popup = popupTemplates[name] else { continue }
      var popupVariableByToken: [String: FlashStatusBarTemplateVariable] = [:]
      for variable in popup.variables where popupVariableByToken[variable.token] == nil {
        popupVariableByToken[variable.token] = variable
      }
      let rendered = renderAligned(
        popup.template,
        variableByToken: popupVariableByToken,
        context: context,
        dynamicValues: dynamicValues,
        preserveNewlines: true)
      popupTexts[name] = (rendered.left + rendered.centre + rendered.right)
        .trimmingCharacters(in: .newlines)
    }
    return FlashStatusBarModel(
      appText: split.centre,
      modeText: split.left,
      rightText: split.right,
      popupTexts: popupTexts)
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
    dynamicValues: [String: String],
    preserveNewlines: Bool = false
  ) -> (left: String, centre: String, right: String) {
    var raw =
      preserveNewlines
      ? raw.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      : normalizedTemplate(raw)
    // tmux passes status strings through strftime(3) BEFORE format
    // expansion, so literal `%H:%M` in the template works and `%` in
    // resolved values survives untouched. `%%` escapes a literal percent.
    if raw.contains("%") {
      raw = strftimeExpanded(raw, now: context.now)
    }
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

    let expansion = FormatExpansion(
      variableByToken: variableByToken, context: context, dynamicValues: dynamicValues)

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
        if raw[after] == "{",
          let close = FlashStatusBarMarkup.matchingBrace(in: raw, openingAt: after)
        {
          let bodyStart = raw.index(after: after)
          append(expansion.expandBody(String(raw[bodyStart..<close]).trimmed))
          index = raw.index(after: close)
          continue
        }
        if let token = tmuxShortFormatToken(for: raw[after]) {
          append(expansion.resolveLeaf(token))
          index = raw.index(after: after)
          continue
        }
      }
      append(String(raw[index]))
      index = raw.index(after: index)
    }

    return (left, centre, right)
  }

  /// One publish's format-expansion state: resolves `#{…}` bodies including
  /// the tmux modifier grammar — conditionals `#{?cond,a,b}`, comparators
  /// (`==` `!=` `<` `>` `<=` `>=`) and logic (`&&` `||`), substitution
  /// `s/re/repl/[i]`, padding `pN`/`p-N`, and both truncation spellings
  /// (`=N`/`=-N` with optional ellipsis, `=/N/marker`). Modifiers chain by
  /// nesting: `#{=10:#{s/a/b/:var}}`.
  struct FormatExpansion {
    var variableByToken: [String: FlashStatusBarTemplateVariable]
    var context: FlashStatusBarContext
    var dynamicValues: [String: String]

    /// Depth cap so a pathological self-referencing template can't spin.
    private static let maxDepth = 12
    static let comparators = ["==", "!=", "<=", ">=", "<", ">", "&&", "||"]

    func expandBody(_ body: String, depth: Int = 0) -> String {
      guard depth < Self.maxDepth else { return "" }
      if body.hasPrefix("?") {
        let args = FlashStatusBarMarkup.splitFormatArguments(body.dropFirst())
        guard args.count >= 2 else { return "" }
        let condition = expandOperand(args[0].trimmed, depth: depth + 1)
        let branch = Self.isTruthy(condition) ? args[1] : (args.count > 2 ? args[2] : "")
        return expandFormatString(branch, depth: depth + 1)
      }
      for op in Self.comparators where body.hasPrefix(op + ":") {
        let args = FlashStatusBarMarkup.splitFormatArguments(body.dropFirst(op.count + 1))
        guard args.count == 2 else { return "" }
        // Comparator arguments are FORMAT strings — literal text compares
        // as itself (`#{==:#{mode},NORMAL}`), unlike a bare conditional
        // condition which names a variable.
        let a = Self.visibleText(expandFormatString(args[0].trimmed, depth: depth + 1))
        let b = Self.visibleText(expandFormatString(args[1].trimmed, depth: depth + 1))
        return Self.compare(op, a, b) ? "1" : "0"
      }
      if body.hasPrefix("s/"), let substitution = Self.parseSubstitution(body) {
        let value = expandOperand(substitution.operand, depth: depth + 1)
        return Self.applySubstitution(
          value, pattern: substitution.pattern, replacement: substitution.replacement,
          caseInsensitive: substitution.caseInsensitive)
      }
      if let padding = Self.parsePadding(body) {
        let value = expandOperand(padding.operand, depth: depth + 1)
        return Self.applyPadding(value, width: padding.width, leftPad: padding.leftPad)
      }
      let (token, truncation) = FlashStatusBarTemplateEngine.parseTokenTruncation(body)
      let value = expandOperand(token, depth: depth + 1)
      if let truncation {
        return FlashStatusBarTemplateEngine.applyTruncation(value, truncation: truncation)
      }
      return value
    }

    /// A modifier argument: braced content is a mini format string, a bare
    /// word is a leaf variable.
    func expandOperand(_ operand: String, depth: Int) -> String {
      guard depth < Self.maxDepth else { return "" }
      if operand.contains("#{") || operand.contains("#[") {
        return expandFormatString(operand, depth: depth)
      }
      return resolveLeaf(operand)
    }

    /// Expand a format string (conditional branch, comparator argument):
    /// text and `#[…]` markers pass through, `##` unescapes, `#{…}` expands.
    func expandFormatString(_ format: String, depth: Int) -> String {
      guard depth < Self.maxDepth else { return "" }
      var out = ""
      var index = format.startIndex
      while index < format.endIndex {
        if format[index] == "#",
          let after = format.index(index, offsetBy: 1, limitedBy: format.endIndex),
          after < format.endIndex
        {
          if format[after] == "#" {
            out += "#"
            index = format.index(after: after)
            continue
          }
          if format[after] == "{",
            let close = FlashStatusBarMarkup.matchingBrace(in: format, openingAt: after)
          {
            out += expandBody(
              String(format[format.index(after: after)..<close]).trimmed, depth: depth + 1)
            index = format.index(after: close)
            continue
          }
          if format[after] == "[", let close = format[after...].firstIndex(of: "]") {
            out += String(format[index...close])
            index = format.index(after: close)
            continue
          }
        }
        out.append(format[index])
        index = format.index(after: index)
      }
      return out
    }

    func resolveLeaf(_ token: String) -> String {
      let variable =
        variableByToken[token]
        ?? FlashStatusBarTemplateEngine.sdkValue(for: token).map {
          FlashStatusBarTemplateVariable(
            id: "statusbar.template.\(token)",
            token: token,
            source: .sdk($0))
        }
      guard let variable else { return "" }
      return FlashStatusBarTemplateEngine.resolve(
        variable: variable, context: context, dynamicValues: dynamicValues)
    }

    /// tmux truthiness: non-empty and not "0" (markers are zero-width).
    static func isTruthy(_ value: String) -> Bool {
      let visible = visibleText(value)
      return !visible.isEmpty && visible != "0"
    }

    static func visibleText(_ value: String) -> String {
      FlashStatusBarMarkup.tokenizeValue(value).reduce(into: "") { out, token in
        if case .text(let text) = token { out += text }
      }
    }

    static func compare(_ op: String, _ a: String, _ b: String) -> Bool {
      switch op {
      case "==": return a == b
      case "!=": return a != b
      case "&&": return isTruthy(a) && isTruthy(b)
      case "||": return isTruthy(a) || isTruthy(b)
      default:
        // Numeric when both sides parse (tmux compares numbers as
        // numbers), lexicographic otherwise.
        if let na = Double(a), let nb = Double(b) {
          switch op {
          case "<": return na < nb
          case ">": return na > nb
          case "<=": return na <= nb
          default: return na >= nb
          }
        }
        switch op {
        case "<": return a < b
        case ">": return a > b
        case "<=": return a <= b
        default: return a >= b
        }
      }
    }

    static func parseSubstitution(_ body: String)
      -> (pattern: String, replacement: String, caseInsensitive: Bool, operand: String)?
    {
      // s/pattern/replacement/[flags]:operand — '/' inside the pattern is
      // escaped as `\/` (tmux convention).
      var rest = Substring(body.dropFirst(2))
      func take(until separator: Character) -> String? {
        var out = ""
        var index = rest.startIndex
        while index < rest.endIndex {
          let ch = rest[index]
          if ch == "\\",
            let next = rest.index(index, offsetBy: 1, limitedBy: rest.endIndex),
            next < rest.endIndex, rest[next] == separator
          {
            out.append(separator)
            index = rest.index(after: next)
            continue
          }
          if ch == separator {
            rest = rest[rest.index(after: index)...]
            return out
          }
          out.append(ch)
          index = rest.index(after: index)
        }
        return nil
      }
      guard let pattern = take(until: "/"), let replacement = take(until: "/") else {
        return nil
      }
      guard let colon = rest.firstIndex(of: ":") else { return nil }
      let flags = rest[..<colon]
      let operand = String(rest[rest.index(after: colon)...]).trimmed
      guard !operand.isEmpty else { return nil }
      return (pattern, replacement, flags.contains("i"), operand)
    }

    static func applySubstitution(
      _ value: String, pattern: String, replacement: String, caseInsensitive: Bool
    ) -> String {
      var options: NSRegularExpression.Options = []
      if caseInsensitive { options.insert(.caseInsensitive) }
      guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return value
      }
      // tmux backreferences are \1; NSRegularExpression templates use $1.
      var template = ""
      var index = replacement.startIndex
      while index < replacement.endIndex {
        let ch = replacement[index]
        if ch == "\\",
          let next = replacement.index(index, offsetBy: 1, limitedBy: replacement.endIndex),
          next < replacement.endIndex, replacement[next].isNumber
        {
          template.append("$")
          template.append(replacement[next])
          index = replacement.index(after: next)
          continue
        }
        if ch == "$" { template.append("\\$") } else { template.append(ch) }
        index = replacement.index(after: index)
      }
      let range = NSRange(value.startIndex..., in: value)
      return regex.stringByReplacingMatches(
        in: value, options: [], range: range, withTemplate: template)
    }

    static func parsePadding(_ body: String)
      -> (width: Int, leftPad: Bool, operand: String)?
    {
      guard body.hasPrefix("p") else { return nil }
      var digits = Substring(body.dropFirst())
      let leftPad = digits.hasPrefix("-")
      if leftPad { digits = digits.dropFirst() }
      guard let colon = digits.firstIndex(of: ":") else { return nil }
      guard let width = Int(digits[..<colon]), width > 0 else { return nil }
      let operand = String(digits[digits.index(after: colon)...]).trimmed
      guard !operand.isEmpty else { return nil }
      return (width, leftPad, operand)
    }

    static func applyPadding(_ value: String, width: Int, leftPad: Bool) -> String {
      let visible = visibleText(value).count
      guard visible < width else { return value }
      let pad = String(repeating: " ", count: width - visible)
      return leftPad ? pad + value : value + pad
    }
  }

  /// strftime(3) over the template — tmux-compatible clock literals. The
  /// buffer is generous; on overflow the template passes through unexpanded.
  static func strftimeExpanded(_ raw: String, now: Date) -> String {
    var time = time_t(now.timeIntervalSince1970)
    var components = tm()
    localtime_r(&time, &components)
    var buffer = [CChar](repeating: 0, count: 8192)
    let written = raw.withCString { format in
      strftime(&buffer, buffer.count, format, &components)
    }
    guard written > 0 else { return raw }
    return String(cString: buffer)
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
    /// tmux's `#{=/N/marker:…}` form: keep `n` visible characters and
    /// append `marker` when trimmed. The marker does NOT count toward `n`
    /// (tmux semantics — unlike the Flash `…` extension above).
    case headMarker(Int, String)
    /// `#{=-/N/marker:…}`: keep the LAST `n`, prepending `marker`.
    case tailMarker(Int, String)
  }

  /// Split `#{=N:mode}` into (`"mode"`, `.head(N)`), `#{=-N:mode}` into
  /// (`"mode"`, `.tail(N)`), and plain `#{mode}` into (`"mode"`, nil).
  /// Mirrors tmux's `=N:` / `=-N:` length-limit operators and its
  /// `=/N/marker:` custom-marker form, plus a Flash extension: a trailing
  /// `…` (or ASCII `...`) on the width — `#{=N…:…}` / `#{=-N…:…}` —
  /// appends an ellipsis glyph when the value is trimmed.
  static func parseTokenTruncation(_ body: String) -> (token: String, truncation: Truncation?) {
    guard body.hasPrefix("=") else { return (body, nil) }
    var afterEquals = body.dropFirst()
    let isTail = afterEquals.first == "-"
    if isTail { afterEquals = afterEquals.dropFirst() }
    // tmux marker form: `=/N/marker:token` (tail: `=-/N/marker:token`).
    if afterEquals.first == "/" {
      let afterSlash = afterEquals.dropFirst()
      guard let widthEnd = afterSlash.firstIndex(of: "/"),
        let width = Int(afterSlash[..<widthEnd]), width > 0
      else { return (body, nil) }
      let rest = afterSlash[afterSlash.index(after: widthEnd)...]
      guard let colon = rest.firstIndex(of: ":") else { return (body, nil) }
      let marker = String(rest[..<colon])
      let token = String(rest[rest.index(after: colon)...]).trimmed
      return (token, isTail ? .tailMarker(width, marker) : .headMarker(width, marker))
    }
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
    guard let width = Int(widthSlice), width > 0 else { return (body, nil) }
    return (token, isTail ? .tail(width, ellipsis: ellipsis) : .head(width, ellipsis: ellipsis))
  }

  static func normalizedTemplate(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\r\n", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
  }

  /// The tmux one-letter aliases Flash can actually resolve. Only the host
  /// pair survives: tmux-STATE aliases (`#S #W #I #P #D`) were removed with
  /// the tmux-state dialect — that state lives in the tmux plugin and
  /// renders through `#{plugin:tmux.<segment>}` status segments.
  static func tmuxShortFormatToken(for character: Character) -> String? {
    switch character {
    case "H": return "host"
    case "h": return "host_short"
    default: return nil
    }
  }

  /// Bare `#{token}` names the engine resolves itself, shared by config
  /// validation and the render-time leaf fallback. tmux-state names
  /// (`session_name`, `window_name`, `window_index`, `pane_index`,
  /// `pane_id`) are deliberately absent: unknown bare identifiers are a
  /// config error, not silently-empty output.
  static func sdkValue(for token: String) -> FlashStatusBarSDKValue? {
    switch token {
    case "mode": return .modeLabel
    case "active_app_name": return .activeAppName
    case "active_bundle_identifier": return .activeBundleIdentifier
    case "date": return .date
    case "host": return .host
    case "host_short": return .hostShort
    case "user": return .user
    case "uid": return .uid
    case "pid": return .pid
    default: return nil
    }
  }

  /// Truncation walks the token stream, so `#[…]` markers are zero-width
  /// AND survive the cut on either side — the old character walk dropped
  /// trailing markers, which is how a >80-char cycle line lost its
  /// `#[nocyc]` sentinel and silently killed the slide animation.
  static func applyTruncation(_ value: String, truncation: Truncation) -> String {
    let (limit, fromTail, ellipsis, marker): (Int, Bool, Bool, String?)
    switch truncation {
    case .head(let n, let e): (limit, fromTail, ellipsis, marker) = (n, false, e, nil)
    case .tail(let n, let e): (limit, fromTail, ellipsis, marker) = (n, true, e, nil)
    case .headMarker(let n, let m): (limit, fromTail, ellipsis, marker) = (n, false, false, m)
    case .tailMarker(let n, let m): (limit, fromTail, ellipsis, marker) = (n, true, false, m)
    }
    let tokens = FlashStatusBarMarkup.tokenizeValue(value)
    guard FlashStatusBarMarkup.visibleCount(tokens) > limit else { return value }
    return FlashStatusBarMarkup.serialize(
      FlashStatusBarMarkup.truncate(
        tokens, limit: limit, fromTail: fromTail, ellipsis: ellipsis, marker: marker))
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

  static func resolve(
    variable: FlashStatusBarTemplateVariable,
    context: FlashStatusBarContext,
    dynamicValues: [String: String]
  ) -> String {
    switch variable.source {
    case .sdk(let value):
      return resolveSDK(value, context: context)
    case .plugin(let value):
      return resolvePlugin(value, statuses: context.pluginStatuses)
    case .command:
      return dynamicValues[variable.id]?.trimmed ?? ""
    case .cycle:
      // A cycle publishes its current line into `dynamicValues[id]` (with its
      // own `#[link=…]` marker), so it reads back like a command — but wrapped
      // in `#[cyc]…#[nocyc]` sentinels so the renderer can pull the rotating run
      // into its own clipped layer and slide it. The sentinels are zero-width
      // `#[…]` markers, so truncation/measurement ignore them, and an
      // unhandled region renders them as nothing.
      let line = dynamicValues[variable.id]?.trimmed ?? ""
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
      // Wrapped in zero-width sentinels (the `#[cyc]` trick) so the
      // renderer can pull the pill out of the left region no matter what
      // markers surround it — the old first-`#[` split made
      // `#[fg=…]#{mode}` render an EMPTY pill and `foo #{mode}` absorb
      // "foo" into it. Elsewhere (centre/right) the sentinels are unknown
      // style tokens and render as nothing.
      let label = context.modeLabel.trimmed
      return label.isEmpty ? "" : "#[pill]" + label + "#[nopill]"
    case .date:
      let date = FlashStatusBarRenderer.dateText(
        now: context.now,
        calendar: context.calendar,
        locale: context.locale)
      return "#[fg=colour178]\(date)"
    case .host:
      return context.hostName.trimmed
    case .hostShort:
      let host = context.hostName.trimmed
      guard let dot = host.firstIndex(of: ".") else { return host }
      return String(host[..<dot])
    case .user:
      return context.userName.trimmed
    case .uid:
      return "\(context.userID)"
    case .pid:
      return "\(context.processID)"
    }
  }

  private static func resolvePlugin(
    _ value: FlashStatusBarPluginValue,
    statuses: [PluginStatusBarInfo]
  ) -> String {
    switch value {
    case .loadedCount:
      // Failed rows (load failures and parked plugins) surface through
      // errorCount, not counted as loaded plugins.
      return "\(statuses.filter { $0.state != "failed" }.count)"
    case .readyCount:
      // Manifest-only plugins are fully serviceable without a process.
      return "\(statuses.filter { $0.state == "running" || $0.state == "manifest_only" }.count)"
    case .errorCount:
      return "\(statuses.filter(\.hasError).count)"
    case .statusSegment(let pluginID, let name):
      guard
        let text = statuses.first(where: { $0.id == pluginID })?
          .statusSegments[name]?
          .trimmed,
        !text.isEmpty
      else { return "" }
      return text
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

  static func segments(
    from raw: String,
    defaultForeground: FlashStatusTextColor = .colour245
  ) -> [FlashStatusTextSegment] {
    let rootStyle = FlashStatusTextStyle(foreground: defaultForeground)
    var style = rootStyle
    // tmux style scoping: `#[default]` resets to the current default style,
    // `#[push-default]` makes the current style the default (saving the old
    // one), `#[pop-default]` restores it — the native answer to fg-bleed.
    var baseStyle = rootStyle
    var defaultsStack: [FlashStatusTextStyle] = []
    var link: String?
    var range: String?
    var popup: String?
    var popupContent: String?
    var inlinePopupIndex = 0
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
          link: link,
          range: range,
          popup: popup,
          popupContent: popupContent))
      buffer = ""
    }

    for token in FlashStatusBarMarkup.tokenizeValue(raw) {
      switch token {
      case .text(let text):
        buffer += text
      case .marker(let parts):
        flush()
        applyLinkMarker(parts, to: &link)
        // Tokens apply strictly left-to-right so `#[fg=colour196
        // push-default]` sets the colour BEFORE pushing it as the default.
        for part in parts {
          switch part {
          case "default": style = baseStyle
          case "push-default":
            defaultsStack.append(baseStyle)
            baseStyle = style
          case "pop-default":
            baseStyle = defaultsStack.popLast() ?? rootStyle
          case "norange": range = nil
          case "nopopup":
            popup = nil
            popupContent = nil
          case let part where part.hasPrefix("popup="):
            let value = String(part.dropFirst("popup=".count))
            if value.hasPrefix("inline:") {
              let encoded = String(value.dropFirst("inline:".count))
              // Dynamic status output is trusted config data, but cap inline
              // bodies so malformed command output cannot allocate an
              // unbounded popup or leak its full stdout into the overlay.
              if !encoded.isEmpty, encoded.utf8.count <= 16_384,
                let decoded = encoded.removingPercentEncoding,
                !decoded.isEmpty
              {
                popup = "inline-\(inlinePopupIndex)"
                popupContent = decoded
                inlinePopupIndex += 1
              } else {
                popup = nil
                popupContent = nil
              }
            } else {
              popup = value.isEmpty ? nil : value
              popupContent = nil
            }
          case let part where part.hasPrefix("range="):
            // Only `range=user|<name>` spans are actionable (tmux's
            // window/session ranges have no Flash analogue).
            let spec = part.dropFirst("range=".count)
            range = spec.hasPrefix("user|") ? String(spec.dropFirst("user|".count)) : nil
          default: applyTmuxMarker([part], to: &style)
          }
        }
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

  /// The mode pill renders in its own layer, so its popup state cannot travel
  /// through ordinary text-run geometry. Recover the popup active over visible
  /// text between the engine's `#[pill]` sentinels.
  static func popupNameForPill(in raw: String) -> String? {
    var popup: String?
    var insidePill = false
    for token in FlashStatusBarMarkup.tokenizeValue(raw) {
      switch token {
      case .text(let text):
        if insidePill, !text.isEmpty, let popup { return popup }
      case .marker(let parts):
        for part in parts {
          if part == "pill" {
            insidePill = true
          } else if part == "nopill" {
            insidePill = false
          } else if part == "nopopup" {
            popup = nil
          } else if part.hasPrefix("popup=") {
            let name = String(part.dropFirst("popup=".count))
            popup = name.isEmpty ? nil : name
          }
        }
      case .variable, .alias:
        break
      }
    }
    return nil
  }

  /// Elastic fit: shrink ONLY the `#[shrink]…#[noshrink]` span until `raw`
  /// renders within `available` points. Fixed content (labels, domains,
  /// arrows) keeps its full width; the elastic span absorbs all overflow
  /// with a `…`, pixel-accurately (iterative measure-and-trim — the bar
  /// font is monospaced, so the first estimate is nearly exact). A string
  /// with no shrink span passes through untouched (legacy behaviour: the
  /// region just runs long). Markers inside the span survive the cut, so
  /// links/styles never bleed.
  static func fitToWidth(_ raw: String, font: NSFont, available: CGFloat) -> String {
    guard available > 0, raw.contains("#[shrink]") else { return raw }
    var width = ceil(attributedStatusString(from: raw, font: font).size().width)
    guard width > available else { return raw }
    guard let open = raw.range(of: "#[shrink]"),
      let close = raw.range(of: "#[noshrink]", range: open.upperBound..<raw.endIndex)
    else { return raw }
    let prefix = String(raw[..<open.upperBound])
    let spanTokens = FlashStatusBarMarkup.tokenizeValue(
      String(raw[open.upperBound..<close.lowerBound]))
    let suffix = String(raw[close.lowerBound...])
    let charWidth = max(
      1,
      ceil(
        NSAttributedString(
          string: "M", attributes: [.font: font]
        ).size().width))
    var limit = FlashStatusBarMarkup.visibleCount(spanTokens)
    var current = raw
    for _ in 0..<10 {
      let overflow = width - available
      if overflow <= 0.5 { break }
      limit -= max(1, Int(ceil(overflow / charWidth)))
      if limit < 1 { limit = 1 }
      let trimmed = FlashStatusBarMarkup.serialize(
        FlashStatusBarMarkup.truncate(
          spanTokens, limit: limit, fromTail: false, ellipsis: true))
      current = prefix + trimmed + suffix
      width = ceil(attributedStatusString(from: current, font: font).size().width)
      if limit == 1 { break }
    }
    return current
  }

  /// Pseudo-scheme carrying a `#[range=user|<name>]` click span through the
  /// URL-typed rect plumbing (click windows + `f` hints). Consumers branch
  /// on the scheme and dispatch the named `[statusbar.click]` action instead
  /// of opening it.
  static let rangeActionScheme = "flash-statusbar-action"

  static func rangeActionURL(name: String) -> URL? {
    var components = URLComponents()
    components.scheme = rangeActionScheme
    components.host = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
    return components.url
  }

  static func rangeActionName(from url: URL) -> String? {
    guard url.scheme == rangeActionScheme else { return nil }
    return url.host?.removingPercentEncoding ?? url.host
  }

  /// Measure the clickable runs in `raw` against `font`: `#[link=…]` spans
  /// and named `#[range=user|…]` spans (carried as `rangeActionURL`s).
  /// Returns each run's x-offset (from the text's leading edge, before any
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
      let target =
        segment.link
        ?? segment.range.flatMap { Self.rangeActionURL(name: $0)?.absoluteString }
      if let target {
        // Merge directly-adjacent runs that share a target so a styled
        // link (e.g. coloured + bold spans) registers one rect.
        if var last = runs.last, last.url == target,
          abs(last.xOffset + last.width - x) < 0.5
        {
          last.width += width
          runs[runs.count - 1] = last
        } else {
          runs.append((xOffset: x, width: width, url: target))
        }
      }
      x += width
    }
    return (runs, x)
  }

  /// Measure named hover-popup spans using the same attributed runs and
  /// alignment geometry as links. Undefined/empty popup names are passive.
  static func popupRuns(
    from raw: String,
    font: NSFont,
    popupTexts: [String: String]
  ) -> (runs: [FlashStatusPopupRun], totalWidth: CGFloat) {
    var runs: [FlashStatusPopupRun] = []
    var x: CGFloat = 0
    for segment in segments(from: raw) {
      let width = attributedSegment(segment, font: font).size().width
      if let name = segment.popup,
        let content = segment.popupContent ?? popupTexts[name],
        !content.isEmpty
      {
        if var last = runs.last, last.name == name, last.content == content,
          abs(last.xOffset + last.width - x) < 0.5
        {
          last.width += width
          runs[runs.count - 1] = last
        } else {
          runs.append(
            FlashStatusPopupRun(xOffset: x, width: width, name: name, content: content))
        }
      }
      x += width
    }
    return (runs, x)
  }

  static func attributedStatusString(
    from raw: String,
    font: NSFont,
    currentTime: TimeInterval = 0,
    defaultForeground: FlashStatusTextColor = .colour245
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments(from: raw, defaultForeground: defaultForeground) {
      attributed.append(attributedSegment(segment, font: font, currentTime: currentTime))
    }
    return attributed
  }

  /// The static base-layer render: animated (`#[breathing]`/`#[blink]`)
  /// spans keep their glyphs — so measurement and layout are identical —
  /// but draw at foreground alpha 0. A pooled overlay layer paints those
  /// spans at full colour with a render-server opacity animation, so the
  /// process does zero periodic work. Backgrounds stay in the base at full
  /// alpha (matching the old renderer, which never animated fills).
  static func attributedStatusStringHidingAnimatedSpans(
    from raw: String,
    font: NSFont
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments(from: raw) {
      let piece = attributedSegment(segment, font: font, currentTime: 0)
      if segment.blink || segment.breathing {
        let mutable = NSMutableAttributedString(attributedString: piece)
        let range = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
          guard let color = value as? NSColor else { return }
          mutable.addAttribute(
            .foregroundColor, value: color.withAlphaComponent(0), range: subrange)
        }
        attributed.append(mutable)
      } else {
        attributed.append(piece)
      }
    }
    return attributed
  }

  /// Measure the animated (`#[breathing]`/`#[blink]`) spans of `raw` the
  /// same way `linkRuns` measures link spans: x-offsets from the text's
  /// leading edge, widths, the ready-to-draw full-colour text, and the
  /// effect flags. Adjacent segments sharing the same flags merge into one
  /// run (a styled span stays one overlay layer).
  static func effectRuns(
    from raw: String,
    font: NSFont
  ) -> (
    runs: [(
      xOffset: CGFloat, width: CGFloat, text: NSAttributedString, blink: Bool, breathing: Bool
    )],
    totalWidth: CGFloat
  ) {
    var runs:
      [(xOffset: CGFloat, width: CGFloat, text: NSAttributedString, blink: Bool, breathing: Bool)] =
        []
    var x: CGFloat = 0
    for segment in segments(from: raw) {
      let width = attributedSegment(segment, font: font, currentTime: 0).size().width
      if segment.blink || segment.breathing {
        // Render the overlay text effect-NEUTRAL (flags stripped): the
        // layer's opacity animation is the single alpha source, so baking
        // the curve's value here would apply it twice.
        var flat = segment
        flat.blink = false
        flat.breathing = false
        let piece = attributedSegment(flat, font: font, currentTime: 0)
        if var last = runs.last, last.blink == segment.blink,
          last.breathing == segment.breathing,
          abs(last.xOffset + last.width - x) < 0.5
        {
          let merged = NSMutableAttributedString(attributedString: last.text)
          merged.append(piece)
          last.text = merged
          last.width += width
          runs[runs.count - 1] = last
        } else {
          runs.append(
            (
              xOffset: x, width: width, text: piece, blink: segment.blink,
              breathing: segment.breathing
            ))
        }
      }
      x += width
    }
    return (runs, x)
  }

  /// A repeating render-server opacity animation reproducing
  /// `effectAlphaMultiplier`'s curve for the given flags — the pure
  /// function stays the single oracle (the keyframes are sampled from it).
  /// `beginTime` is anchored to the period grid of the shared layer clock,
  /// so every span on every bar animates in phase no matter when it was
  /// (re-)armed.
  static func effectOpacityAnimation(
    blink: Bool,
    breathing: Bool,
    anchoredTo layer: CALayer
  ) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    let period: TimeInterval = breathing ? 10 : 1
    if breathing {
      // Sample the sinusoid (and the blink square wave when combined —
      // 10 s is a whole multiple of blink's 1 s period) finely enough
      // that linear interpolation is invisible.
      let probe = FlashStatusTextSegment(
        text: "", foreground: .defaultForeground, blink: blink, breathing: true)
      let steps = blink ? 400 : 80
      animation.values = (0...steps).map { step in
        effectAlphaMultiplier(
          segment: probe, currentTime: period * TimeInterval(step) / TimeInterval(steps))
      }
      animation.calculationMode = blink ? .discrete : .linear
    } else {
      // Pure blink: tmux's half-second square wave.
      animation.values = [1.0, 0.15]
      animation.keyTimes = [0, 0.5]
      animation.calculationMode = .discrete
    }
    animation.duration = period
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    let now = layer.convertTime(CACurrentMediaTime(), from: nil)
    animation.beginTime = now - now.truncatingRemainder(dividingBy: period)
    return animation
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
    // The slowest motion happens at the peak and trough (sine has zero
    // derivative there), matching the pause between inhale and exhale.
    var alpha: CGFloat = 1.0
    if segment.breathing {
      // 10 s cycle — well under a baseline meditation breath (~6 s) so
      // the chip never feels like it's *signalling*, just sitting
      // there alive. Alpha rides [0.76, 1.0] — a slightly stronger 24 %
      // swing that remains peripheral. Knobs tunable here in one place.
      let period: TimeInterval = 10.0
      let phase = (currentTime.truncatingRemainder(dividingBy: period)) / period
      let sine = sin(phase * 2 * .pi)
      let low: CGFloat = 0.76
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
  private var popupTemplates: [String: FlashStatusBarTemplate]
  private let pluginStatusesProvider: () -> [PluginStatusBarInfo]
  private var refreshTimer: DispatchSourceTimer?
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
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
    refreshIntervalSeconds: TimeInterval = 5,
    pluginStatusesProvider: @escaping () -> [PluginStatusBarInfo] = { [] }
  ) {
    self.overlay = overlay
    self.template = template
    self.popupTemplates = popupTemplates
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
    popupTemplates: [String: FlashStatusBarTemplate]? = nil,
    refreshIntervalSeconds: TimeInterval? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.template = template
      if let popupTemplates { self.popupTemplates = popupTemplates }
      if let refreshIntervalSeconds {
        self.refreshIntervalSeconds = refreshIntervalSeconds
      }
      let commandIDs = Set(self.allCommandSections.map(\.id))
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

  private var allTemplates: [FlashStatusBarTemplate] {
    [template] + popupTemplates.keys.sorted().compactMap { popupTemplates[$0] }
  }

  private var allCommandSections: [FlashStatusBarTemplateVariable] {
    var seen: Set<String> = []
    return allTemplates.flatMap(\.commandSections).filter { seen.insert($0.id).inserted }
  }

  private var allCycleSections: [FlashStatusBarTemplateVariable] {
    var seen: Set<String> = []
    return allTemplates.flatMap(\.cycleSections).filter { seen.insert($0.id).inserted }
  }

  /// Kick off every command/cycle section whose deadline has passed and
  /// that isn't already running. Each section runs as its own job on the
  /// concurrent command queue, so cadences are independent.
  private func runDueCommandSections(now: Date) {
    let generation = commandRefreshGeneration
    for section in allCommandSections {
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
    let cycleIDs = Set(allCycleSections.map(\.id))
    cycles = cycles.filter { id, _ in cycleIDs.contains(id) }
    commandSchedules = [:]
    nextClockRefreshAt = nil
    commandRefreshGeneration &+= 1

    publishCurrentModel()
    runDueCommandSections(now: Date())
    scheduleNextClockRefresh(from: Date())
    armRefreshTimer()
  }

  private func scheduleNextClockRefresh(from now: Date) {
    guard allTemplates.contains(where: \.needsClockRefresh) else {
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
      popupTemplates: popupTemplates,
      context: context,
      dynamicValues: dynamicValues)
    let modelChanged = model != lastPublishedModel
    if modelChanged {
      lastPublishedModel = model
      DispatchQueue.main.async { [weak overlay] in
        overlay?.setStatusBarModel(model)
      }
    }
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
