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

  static let colour0 = FlashStatusTextColor.palette(0)
  static let colour178 = FlashStatusTextColor.palette(178)
  static let colour245 = FlashStatusTextColor.palette(245)
  static let colour196 = FlashStatusTextColor.palette(196)
  static let red = FlashStatusTextColor.palette(1)
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
  var alignment: StatusFormatAlignment = .default
  var isStyleBoundary = false
  var origin: StatusFormatSpan? = nil
  var underlineColor: FlashStatusTextColor = .defaultForeground
  var underlineStyle: StatusFormatUnderline = .single
  var underlineMask: UInt8 = 0
  var noAttributes = false
  var strikethrough = false
  var hidden = false
  var overline = false
  var alternateCharacterSet = false
  var fill: FlashStatusTextColor? = nil
  var list: StatusFormatList = .off
  var nativeRange: StatusFormatRange? = nil
  var width: StatusFormatWidth? = nil
  var padding = 0
  var ignore = false
  var pill = false
  var shrink = false
  var cycle = false

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
    self.underlineMask = underline ? 1 : 0
    self.dim = dim
    self.reverse = reverse
    self.blink = blink
    self.breathing = breathing
    self.link = link
    self.range = range
    self.nativeRange = range.map { .init(kind: .user, argument: $0) }
    self.popup = popup
    self.popupContent = popupContent
  }
}

struct FlashStatusPopupRun: Equatable {
  var xOffset: CGFloat
  var width: CGFloat
  var name: String
  var content: String
  var document: [FlashStatusTextSegment]? = nil
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

enum FlashStatusBarSource: Equatable {
  case sdk(FlashStatusBarSDKValue)
  case plugin(FlashStatusBarPluginValue)

}

/// Deadline-stable state for one rotating status value. Time is expressed as
/// monotonic uptime so wall-clock corrections cannot speed up or stall a cycle.
struct FlashStatusBarCycleState: Equatable {
  private(set) var lines: [String]
  private(set) var visibleLine: String
  private(set) var periodSeconds: TimeInterval
  private(set) var nextRotationAt: TimeInterval
  private var currentIndex: Int?

  init(lines: [String], periodSeconds: TimeInterval, now: TimeInterval) {
    self.lines = lines
    self.visibleLine = lines.first ?? ""
    self.periodSeconds = max(1, periodSeconds)
    self.nextRotationAt = now + TimeInterval(max(1, periodSeconds))
    self.currentIndex = lines.isEmpty ? nil : 0
  }

  /// A refresh replaces the future playlist, never the currently visible
  /// line. This prevents a reordered feed from changing once at refresh time
  /// and again at the nearby rotation deadline.
  mutating func refresh(
    lines newLines: [String],
    periodSeconds newPeriodSeconds: TimeInterval,
    now: TimeInterval
  ) {
    let wasWaitingForRotation = needsRotationTimer
    let normalizedPeriod = max(1, newPeriodSeconds)
    let periodChanged = normalizedPeriod != periodSeconds

    lines = newLines
    currentIndex = newLines.firstIndex(of: visibleLine)
    periodSeconds = normalizedPeriod

    // A period edit starts a fresh cadence. Likewise, a cycle which had
    // nothing to rotate starts at the refresh that gives it a new future
    // value instead of immediately catching up through dormant deadlines.
    if periodChanged || (!wasWaitingForRotation && needsRotationTimer) {
      nextRotationAt = now + TimeInterval(normalizedPeriod)
    }
  }

  /// True while there is either another line to rotate to or a refreshed
  /// single-line value waiting for its scheduled reveal.
  var needsRotationTimer: Bool {
    guard !lines.isEmpty else { return false }
    return lines.count > 1 || currentIndex == nil
  }

  /// Advance by every elapsed scheduled interval. The next deadline is moved
  /// from the previous deadline, not from `now`, so delayed timer delivery
  /// does not accumulate drift.
  @discardableResult
  mutating func advanceIfDue(now: TimeInterval) -> Bool {
    guard needsRotationTimer, now >= nextRotationAt else { return false }

    let period = TimeInterval(periodSeconds)
    let elapsedPeriods = Int(floor((now - nextRotationAt) / period)) + 1
    nextRotationAt += TimeInterval(elapsedPeriods) * period

    let baseIndex = currentIndex ?? -1
    let step = elapsedPeriods % lines.count
    let nextIndex = (baseIndex + step + lines.count) % lines.count
    let nextLine = lines[nextIndex]
    let changed = nextLine != visibleLine
    currentIndex = nextIndex
    visibleLine = nextLine
    return changed
  }
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
  var template: String {
    didSet { program = StatusFormatProgram.compile(source: template, origin: program.origin) }
  }
  var variables: [FlashStatusBarTemplateVariable]
  var options: [String: String]
  var sourceNames: Set<String>
  var program: StatusFormatProgram

  init(
    template: String,
    variables: [FlashStatusBarTemplateVariable] = [],
    options: [String: String] = [:],
    sourceNames: Set<String> = [],
    origin: StatusFormatOrigin = .init()
  ) {
    self.template = template
    self.variables = variables
    self.options = options
    self.sourceNames = sourceNames
    self.program = StatusFormatProgram.compile(source: template, origin: origin)
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
  var popupDocuments: [String: [FlashStatusTextSegment]]
  var appDocument: [FlashStatusTextSegment] = []
  var modeDocument: [FlashStatusTextSegment] = []
  var rightDocument: [FlashStatusTextSegment] = []
  var document: StatusFormatDocument

  init(
    appText: String,
    modeText: String,
    rightText: String,
    popupTexts: [String: String] = [:],
    popupDocuments: [String: [FlashStatusTextSegment]] = [:],
    appDocument: [FlashStatusTextSegment]? = nil,
    modeDocument: [FlashStatusTextSegment]? = nil,
    rightDocument: [FlashStatusTextSegment]? = nil,
    document: StatusFormatDocument? = nil
  ) {
    self.appText = appText
    self.modeText = modeText
    self.rightText = rightText
    self.popupTexts = popupTexts
    self.popupDocuments =
      popupDocuments.isEmpty
      ? popupTexts.mapValues { StatusFormatDocument.parse($0).runs } : popupDocuments
    self.appDocument =
      appDocument ?? StatusFormatDocument.parse(appText, origin: .init("statusbar.centre")).runs
    self.modeDocument =
      modeDocument ?? StatusFormatDocument.parse(modeText, origin: .init("statusbar.left")).runs
    self.rightDocument =
      rightDocument ?? StatusFormatDocument.parse(rightText, origin: .init("statusbar.right")).runs
    func lane(_ runs: [FlashStatusTextSegment], alignment: StatusFormatAlignment)
      -> [FlashStatusTextSegment]
    {
      guard !runs.isEmpty else { return [] }
      var boundary = FlashStatusTextSegment(text: "", foreground: .defaultForeground)
      boundary.alignment = alignment
      boundary.isStyleBoundary = true
      return [boundary]
        + runs.map {
          var run = $0
          run.alignment = alignment
          return run
        }
    }
    self.document =
      document
      ?? StatusFormatDocument(
        runs:
          lane(self.modeDocument, alignment: .left) + lane(self.appDocument, alignment: .centre)
          + lane(self.rightDocument, alignment: .right))
    for run in self.document.runs {
      guard let name = run.popup, let content = run.popupContent,
        self.popupDocuments[name] == nil
      else { continue }
      self.popupTexts[name] = content
      self.popupDocuments[name] =
        StatusFormatDocument.parse(content, origin: .init("popup.\(name)")).runs
    }
  }
}

struct FlashStatusBarSourceDefinition: Equatable {
  var command: [String]
  var workingDirectory: String?
  var environment: [String: String]
  var intervalSeconds: Double
  var cycleIntervalSeconds: Double?
  var timeoutSeconds: Double

  init(
    command: [String], workingDirectory: String? = nil,
    environment: [String: String] = [:], intervalSeconds: Double = 5,
    cycleIntervalSeconds: Double? = nil, timeoutSeconds: Double = 6
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.intervalSeconds = intervalSeconds
    self.cycleIntervalSeconds = cycleIntervalSeconds
    self.timeoutSeconds = timeoutSeconds
  }
}

enum FlashStatusBarTemplateEngine {
  static func render(
    template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
    context: FlashStatusBarContext,
    dynamicValues: [String: String] = [:],
    jobValues: [String: String] = [:],
    options: [String: String] = [:],
    terminalPopupNames: Set<String> = []
  ) -> FlashStatusBarModel {
    evaluate(
      template: template, popupTemplates: popupTemplates, context: context,
      dynamicValues: dynamicValues, jobValues: jobValues, options: options,
      terminalPopupNames: terminalPopupNames
    ).model
  }

  /// Every input one evaluation read, captured so the next publish can skip
  /// re-evaluating when none of them changed. Plugin samplers publish at 1 Hz;
  /// most of those publishes change nothing the template references.
  struct EvaluationInputs: Equatable {
    var values: [String: String?]
    var options: [String: String?]
    var jobs: [String: String]
    var second: Int?

    static func capture(
      dependencies: StatusFormatDependencies, native: StatusFormatContext
    ) -> EvaluationInputs {
      var values: [String: String?] = [:]
      for name in dependencies.values { values[name] = native.values[name] }
      var options: [String: String?] = [:]
      for name in dependencies.options { options[name] = native.options[name] }
      return EvaluationInputs(
        values: values, options: options,
        jobs: dependencies.containsJobs ? native.jobs : [:],
        second: dependencies.containsTime ? Int(native.now.timeIntervalSince1970) : nil)
    }
  }

  /// Per-popup memo: a popup program is re-evaluated only when a value or
  /// option it read last time changed. Time- and job-dependent popups are
  /// never memoized.
  final class PopupEvaluationCache {
    struct Memo {
      var dependencies: StatusFormatDependencies
      var inputs: EvaluationInputs
      var runs: [FlashStatusTextSegment]
    }
    var memos: [String: Memo] = [:]
  }

  static func evaluate(
    template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
    context: FlashStatusBarContext,
    dynamicValues: [String: String] = [:],
    jobValues: [String: String] = [:],
    options: [String: String] = [:],
    terminalPopupNames: Set<String> = [],
    nativeContext: StatusFormatContext? = nil,
    popupCache: PopupEvaluationCache? = nil
  ) -> (
    model: FlashStatusBarModel, jobs: [StatusFormatJobRequest], sources: Set<String>,
    needsClock: Bool, dependencies: StatusFormatDependencies
  ) {
    var native =
      nativeContext ?? formatContext(context, dynamicValues: dynamicValues, jobValues: jobValues)
    native.options = options.merging(template.options) { _, local in local }
    let result = template.program.evaluate(native, expandTime: true)
    let document = StatusFormatDocument.parse(result)
    func barRuns(_ alignment: StatusFormatAlignment) -> [FlashStatusTextSegment] {
      document.aligned(alignment).map { run in
        var run = run
        run.text = normalizedTemplate(run.text)
        return run
      }.filter { !$0.text.isEmpty || $0.isStyleBoundary }
    }
    let left = barRuns(.left)
    let centre = barRuns(.centre) + barRuns(.absoluteCentre)
    let right = barRuns(.right)
    var popups: [String: [FlashStatusTextSegment]] = [:]
    var jobs = result.jobs
    var dependencies = result.dependencies
    for name in popupTemplates.keys.sorted() {
      guard let popup = popupTemplates[name] else { continue }
      var popupContext = native
      popupContext.options.merge(popup.options) { _, local in local }
      if let memo = popupCache?.memos[name],
        EvaluationInputs.capture(dependencies: memo.dependencies, native: popupContext)
          == memo.inputs
      {
        dependencies.formUnion(memo.dependencies)
        popups[name] = memo.runs
        continue
      }
      let expanded = popup.program.evaluate(popupContext, expandTime: true)
      jobs.append(contentsOf: expanded.jobs)
      dependencies.formUnion(expanded.dependencies)
      var runs = StatusFormatDocument.parse(expanded).runs
      while let first = runs.first, first.text.trimmingCharacters(in: .newlines).isEmpty {
        runs.removeFirst()
      }
      while let last = runs.last, last.text.trimmingCharacters(in: .newlines).isEmpty {
        runs.removeLast()
      }
      if !runs.isEmpty {
        while runs[0].text.first?.isNewline == true { runs[0].text.removeFirst() }
        while runs[runs.count - 1].text.last?.isNewline == true {
          runs[runs.count - 1].text.removeLast()
        }
      }
      popups[name] = runs
      if let popupCache, !expanded.dependencies.containsTime,
        !expanded.dependencies.containsJobs
      {
        popupCache.memos[name] = PopupEvaluationCache.Memo(
          dependencies: expanded.dependencies,
          inputs: EvaluationInputs.capture(
            dependencies: expanded.dependencies, native: popupContext),
          runs: runs)
      }
    }
    for name in terminalPopupNames { popups[name] = [] }
    return (
      FlashStatusBarModel(
        appText: StatusFormatDocument.serialize(centre),
        modeText: StatusFormatDocument.serialize(left),
        rightText: StatusFormatDocument.serialize(right),
        popupTexts: popups.mapValues(StatusFormatDocument.serialize),
        popupDocuments: popups, appDocument: centre, modeDocument: left, rightDocument: right,
        document: StatusFormatDocument(
          runs: document.runs.map {
            var run = $0
            run.text = normalizedTemplate(run.text)
            return run
          })), jobs,
      Set(
        dependencies.values.filter { $0.hasPrefix("flash.source.") }.map {
          String($0.dropFirst(13))
        }),
      dependencies.containsTime || dependencies.values.contains("flash.date"),
      dependencies
    )
  }

  static func normalizedTemplate(_ raw: String) -> String {
    raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
  }

  static func sdkValue(for token: String) -> FlashStatusBarSDKValue? {
    switch token {
    case "flash.mode": return .modeLabel
    case "flash.active_app_name": return .activeAppName
    case "flash.active_bundle_identifier": return .activeBundleIdentifier
    case "flash.date": return .date
    case "host": return .host
    case "host_short": return .hostShort
    case "user": return .user
    case "uid": return .uid
    case "pid": return .pid
    default: return nil
    }
  }

  static func formatContext(
    _ context: FlashStatusBarContext, dynamicValues: [String: String] = [:],
    jobValues: [String: String] = [:]
  ) -> StatusFormatContext {
    var native = StatusFormatContext()
    native.now = context.now
    native.timeZone = context.calendar.timeZone
    native.environment = FlashProcessEnvironment.shared.environment
    native.jobs = jobValues
    let host = context.hostName.trimmed
    native.values = [
      "flash.mode": context.modeLabel.trimmed,
      "flash.active_app_name": context.activeAppName.trimmed.isEmpty
        ? context.activeBundleIdentifier.trimmed : context.activeAppName.trimmed,
      "flash.active_bundle_identifier": context.activeBundleIdentifier.trimmed,
      "flash.date": FlashStatusBarRenderer.dateText(
        now: context.now, calendar: context.calendar, locale: context.locale),
      "host": host, "host_short": host.split(separator: ".").first.map(String.init) ?? host,
      "user": context.userName.trimmed, "uid": String(context.userID),
      "pid": String(context.processID),
      "flash.plugin.loaded_count": String(
        context.pluginStatuses.filter { $0.state != "failed" }.count),
      "flash.plugin.ready_count": String(
        context.pluginStatuses.filter { ["running", "manifest_only"].contains($0.state) }.count),
      "flash.plugin.error_count": String(context.pluginStatuses.filter(\.hasError).count),
    ]
    for plugin in context.pluginStatuses {
      for (name, value) in plugin.statusSegments {
        native.values["flash.plugin.\(plugin.id).\(name)"] = value
      }
    }
    for (key, value) in dynamicValues {
      native.values[key.hasPrefix("flash.") ? key : "flash.source.\(key)"] = value
    }
    return native
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
    defaultForeground: FlashStatusTextColor = .defaultForeground
  ) -> [FlashStatusTextSegment] {
    StatusFormatDocument.parse(raw, defaultForeground: defaultForeground).runs
      .filter { !$0.isStyleBoundary }.map { run in
        var run = run
        run.origin = nil
        return run
      }
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
  static func linkRuns(from raw: String, font: NSFont)
    -> (runs: [(xOffset: CGFloat, width: CGFloat, url: String)], totalWidth: CGFloat)
  {
    linkRuns(from: segments(from: raw), font: font)
  }

  static func popupRuns(from raw: String, font: NSFont, popupTexts: [String: String])
    -> (runs: [FlashStatusPopupRun], totalWidth: CGFloat)
  {
    popupRuns(from: segments(from: raw), font: font, popupTexts: popupTexts)
  }

  static func attributedStatusString(
    from raw: String, font: NSFont, currentTime: TimeInterval = 0,
    defaultForeground: FlashStatusTextColor = .defaultForeground
  ) -> NSAttributedString {
    attributedStatusString(
      from: segments(from: raw, defaultForeground: defaultForeground),
      font: font, currentTime: currentTime)
  }

  static func attributedStatusStringHidingAnimatedSpans(from raw: String, font: NSFont)
    -> NSAttributedString
  {
    attributedStatusStringHidingAnimatedSpans(from: segments(from: raw), font: font)
  }

  static func effectRuns(from raw: String, font: NSFont) -> (
    runs: [(
      xOffset: CGFloat, width: CGFloat, text: NSAttributedString, blink: Bool, breathing: Bool
    )],
    totalWidth: CGFloat
  ) {
    effectRuns(from: segments(from: raw), font: font)
  }

  static func linkRuns(
    from segments: [FlashStatusTextSegment],
    font: NSFont
  ) -> (runs: [(xOffset: CGFloat, width: CGFloat, url: String)], totalWidth: CGFloat) {
    var runs: [(xOffset: CGFloat, width: CGFloat, url: String)] = []
    var x: CGFloat = 0
    for segment in segments {
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
    from segments: [FlashStatusTextSegment],
    font: NSFont,
    popupTexts: [String: String]
  ) -> (runs: [FlashStatusPopupRun], totalWidth: CGFloat) {
    var runs: [FlashStatusPopupRun] = []
    var x: CGFloat = 0
    for segment in segments {
      let width = attributedSegment(segment, font: font).size().width
      if let name = segment.popup,
        let content = segment.popupContent ?? popupTexts[name]
      {
        if var last = runs.last, last.name == name, last.content == content,
          abs(last.xOffset + last.width - x) < 0.5
        {
          last.width += width
          runs[runs.count - 1] = last
        } else {
          runs.append(
            FlashStatusPopupRun(
              xOffset: x, width: width, name: name, content: content,
              document: segment.popupContent.map {
                StatusFormatDocument.parse($0, origin: .init("popup.\(name)")).runs
              }))
        }
      }
      x += width
    }
    return (runs, x)
  }

  static func attributedStatusString(
    from segments: [FlashStatusTextSegment],
    font: NSFont,
    currentTime: TimeInterval = 0,
    defaultForeground: FlashStatusTextColor = .colour245
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments {
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
    from segments: [FlashStatusTextSegment],
    font: NSFont
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    for segment in segments {
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
    from segments: [FlashStatusTextSegment],
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
    for segment in segments {
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
    let finalAlpha = segment.hidden ? 0 : baseDim * effectAlpha
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
    if segment.underline, segment.underlineStyle != .curly {
      let underline: NSUnderlineStyle
      switch segment.underlineStyle {
      case .single, .curly: underline = .single
      case .double: underline = .double
      case .dotted: underline = [.single, .patternDot]
      case .dashed: underline = [.single, .patternDash]
      }
      attrs[.underlineStyle] = underline.rawValue
      attrs[.underlineColor] =
        segment.underlineColor == .defaultForeground
        ? dimmedFg : nsColor(for: segment.underlineColor)
    }
    if segment.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    return NSAttributedString(string: segment.text, attributes: attrs)
  }

  static func nsColor(for color: FlashStatusTextColor) -> NSColor {
    FlashStatusTextColor.nsColor(color)
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

}
