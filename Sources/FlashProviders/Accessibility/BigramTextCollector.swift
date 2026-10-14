import AppKit
import ApplicationServices
import FlashCore
import Foundation

/// Visible text in one focused window, collected for a bigram jump.
///
/// The clickable-target walk stops at controls and at `maxTargets`, so body
/// text never reaches `f`. This walk is separate and on demand: it keeps every
/// visible run of at least one character. A single-line run places glyphs from
/// its frame. A tall run measures each visible line once while collecting, and
/// the letter is then a string search over those lines, placed first by that
/// estimate. Each match then asks Accessibility for its glyph's bounds, since a
/// run's frame can be far wider than its text. It does not read pixels.
public enum BigramTextCollector {
  public static let providerID = "bigram"

  /// How a run turns a letter into glyph rects. Resolved while collecting,
  /// before the letter is known, so the letter itself is only a string search.
  enum GlyphLayout {
    /// The frame is one visual line.
    case proportional
    /// Visible lines, measured once per line or estimated from the frame.
    case lines([BigramMatcher.BigramLineBox])
  }

  struct Run {
    let element: AXUIElement
    let text: String
    let role: String
    let subrole: String?
    let frame: CGRect
    let layout: GlyphLayout
  }

  public struct Corpus {
    let pid: pid_t
    public let bundleIdentifier: String
    let screenH: CGFloat
    let clip: CGRect
    let runs: [Run]

    public var runCount: Int { runs.count }

    /// Each hit on the bounds the app reports for its glyphs, one query per
    /// hit up to `maxMeasuredHits`; the line estimate stands in past that and
    /// for a run whose element answers no bounds (asked once per run). The
    /// frame of a run can be far wider than its text, so the estimate alone
    /// would put a label letters away from its glyph.
    private func measured(
      _ located: [(rect: CGRect, value: Hit)]
    ) -> [(rect: CGRect, value: Hit)] {
      let exact: [CGRect?] = GeckoAccessibility.withTree(
        pid: pid, bundleIdentifier: bundleIdentifier
      ) { _ in
        var unsupported = Set<Int>()
        return located.enumerated().map { index, item in
          let run = item.value.runIndex
          guard index < BigramTextCollector.maxMeasuredHits, !unsupported.contains(run) else {
            return nil
          }
          let bounds = AXAttribute.boundsForRange(
            runs[run].element, location: item.value.location, length: item.value.length,
            screenH: screenH)
          if bounds == nil { unsupported.insert(run) }
          return bounds
        }
      }
      return BigramMatcher.placeMeasured(
        zip(located, exact).map { item, exact in
          (estimate: item.rect, exact: exact, group: item.value.runIndex, value: item.value)
        }, clip: clip)
    }

    public func targets(matching query: String) -> [JumpTarget] {
      guard query.count == 1 else { return [] }
      var located: [(rect: CGRect, value: Hit)] = []
      for (index, run) in runs.enumerated() {
        let haystack = run.text as NSString
        for (occurrence, rect) in BigramTextCollector.glyphHits(run, query: query) {
          let label = haystack.substring(
            with: NSRange(location: occurrence.location, length: occurrence.length))
          located.append(
            (
              rect: rect,
              value: Hit(
                runIndex: index, location: occurrence.location, length: occurrence.length,
                label: label)
            ))
        }
      }
      let kept = BigramMatcher.dedupe(measured(located))
      let targets = kept.enumerated().map { ordinal, item in
        BigramTextCollector.target(
          hit: item.value, rect: item.rect, run: runs[item.value.runIndex], query: query,
          ordinal: ordinal, pid: pid, bundleIdentifier: bundleIdentifier, screenH: screenH,
          clip: clip)
      }
      return AccessibilityProvider.settlingInsertIntent(
        targets, bundleIdentifier: bundleIdentifier)
    }

    /// One target per visible word, in tree order then left to right, at most
    /// `limit` of them. The click lands on the word's leading edge
    /// (`WordMatcher.clickPoint`), inside the word.
    public func wordTargets(limit: Int = 1500) -> [JumpTarget] {
      var located: [(rect: CGRect, value: Hit)] = []
      for (index, run) in runs.enumerated() {
        let haystack = run.text as NSString
        for (occurrence, rect) in BigramTextCollector.wordHits(run) {
          let label = haystack.substring(
            with: NSRange(location: occurrence.location, length: occurrence.length))
          located.append(
            (
              rect: rect,
              value: Hit(
                runIndex: index, location: occurrence.location, length: occurrence.length,
                label: label)
            ))
          if located.count >= limit { break }
        }
        if located.count >= limit { break }
      }
      let kept = BigramMatcher.dedupe(measured(located))
      let targets = kept.enumerated().map { ordinal, item in
        BigramTextCollector.wordTarget(
          hit: item.value, rect: item.rect, run: runs[item.value.runIndex],
          ordinal: ordinal, pid: pid, bundleIdentifier: bundleIdentifier, screenH: screenH,
          clip: clip)
      }
      return AccessibilityProvider.settlingInsertIntent(
        targets, bundleIdentifier: bundleIdentifier)
    }
  }

  /// Bounds queries per letter or word session. At about 0.2 ms each this
  /// keeps the slowest common letter near a tenth of a second.
  static let maxMeasuredHits = 600

  public static func collect(in context: AppContext, screenH: CGFloat) -> Corpus {
    let clip = context.frontWindowFrame
    guard !clip.isNull, !clip.isInfinite else {
      return Corpus(
        pid: context.processID, bundleIdentifier: context.bundleIdentifier, screenH: screenH,
        clip: clip, runs: [])
    }
    let app = AXApp.make(pid: context.processID)
    let runs = GeckoAccessibility.withTree(
      pid: context.processID, bundleIdentifier: context.bundleIdentifier, app: app
    ) { app -> [Run] in
      let traits = AppTraits.of(
        bundleIdentifier: context.bundleIdentifier, pid: context.processID)
      if traits.needsAccessibilityWake {
        let enabled = kCFBooleanTrue as CFTypeRef
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, enabled)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, enabled)
      }
      let roots: [AXUIElement]
      switch context.walkRoot {
      case .focusedWindow:
        guard let window = AccessibilityProvider.focusedOrFirstWindow(in: app) else { return [] }
        roots = [window]
      case .elementsInFrame:
        roots = AccessibilityProvider.topLevelElements(in: app, meeting: clip, screenH: screenH)
      case .openMenus:
        roots = AccessibilityProvider.openMenus(
          in: app, recorded: context.menus, screenH: screenH
        ).map(\.element)
      }
      return roots.flatMap { walk(root: $0, clip: clip, screenH: screenH) }
    }
    return Corpus(
      pid: context.processID, bundleIdentifier: context.bundleIdentifier, screenH: screenH,
      clip: clip, runs: runs)
  }

  private struct Hit {
    let runIndex: Int
    let location: Int
    let length: Int
    let label: String
  }

  /// Parent indexes live on the node because a sibling can sit on the stack
  /// between a node and its parent, so the stack top is not the parent.
  private struct Node {
    var element: AXUIElement
    var depth: Int
    var parent: Int?
    var insideWebArea: Bool
    var emitted = false
    var role: String?
    var subrole: String?
    var title: String?
    var value: String?
    var frame: CGRect?
  }

  /// Post-order: a node's own string is emitted only when no descendant was.
  private static func walk(root: AXUIElement, clip: CGRect, screenH: CGFloat) -> [Run] {
    var nodes = [Node(element: root, depth: 0, parent: nil, insideWebArea: false)]
    var stack: [(index: Int, leave: Bool)] = [(0, false)]
    var runs: [Run] = []
    while let step = stack.popLast() {
      if step.leave {
        finish(step.index, nodes: &nodes, runs: &runs, clip: clip, screenH: screenH)
        continue
      }
      let index = step.index
      if nodes[index].depth > AccessibilityProvider.maxDepth { continue }
      guard let snapshot = read(nodes[index].element, screenH: screenH) else { continue }
      if snapshot.hidden { continue }
      if AccessibilityProvider.skipsOffscreenSubtree(
        frame: snapshot.frame, visible: clip, depth: nodes[index].depth,
        insideWebArea: nodes[index].insideWebArea)
      {
        continue
      }
      nodes[index].role = snapshot.role
      nodes[index].subrole = snapshot.subrole
      nodes[index].title = snapshot.title
      nodes[index].value = snapshot.value
      nodes[index].frame = snapshot.frame
      var children = snapshot.children
      if snapshot.childrenMissing {
        children = AXAttribute.children(nodes[index].element)
      }
      children = tableChildren(
        of: nodes[index].element, role: snapshot.role, insideWebArea: nodes[index].insideWebArea,
        children: children)
      stack.append((index, true))
      let parent = index
      let depth = nodes[index].depth + 1
      let childInsideWeb = nodes[index].insideWebArea || snapshot.role == "AXWebArea"
      for child in children.reversed() {
        nodes.append(
          Node(element: child, depth: depth, parent: parent, insideWebArea: childInsideWeb))
        stack.append((nodes.count - 1, false))
      }
    }
    return runs
  }

  private static func finish(
    _ index: Int, nodes: inout [Node], runs: inout [Run], clip: CGRect, screenH: CGFloat
  ) {
    if nodes[index].emitted { return }
    guard let role = nodes[index].role,
      let text = BigramText.ownString(
        role: role, title: nodes[index].title, value: nodes[index].value, descendantEmitted: false),
      let frame = nodes[index].frame,
      clip.containsInclusive(CGPoint(x: frame.midX, y: frame.midY))
    else { return }
    let element = nodes[index].element
    runs.append(
      Run(
        element: element, text: text, role: role, subrole: nodes[index].subrole, frame: frame,
        layout: glyphLayout(
          element: element, text: text, frame: frame, screenH: screenH, clip: clip)))
    markEmitted(&nodes, index)
  }

  /// Marks `index` and its ancestors. A descendant that emits suppresses the
  /// containers wrapped around the same glyphs.
  private static func markEmitted(_ nodes: inout [Node], _ index: Int) {
    var current: Int? = index
    while let cursor = current {
      if nodes[cursor].emitted { return }
      nodes[cursor].emitted = true
      current = nodes[cursor].parent
    }
  }

  private struct Snapshot {
    var role: String?
    var frame: CGRect?
    var children: [AXUIElement]
    var childrenMissing: Bool
    var title: String?
    var value: String?
    var hidden: Bool
    var subrole: String?
  }

  private static let batchNames: CFArray =
    [
      kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
      kAXTitleAttribute, kAXValueAttribute, kAXHiddenAttribute, kAXSubroleAttribute,
    ] as CFArray

  private static func read(_ element: AXUIElement, screenH: CGFloat) -> Snapshot? {
    var valuesRef: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, batchNames, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
    guard status == .success, let values = valuesRef as? [Any], values.count == 8 else {
      return nil
    }
    let children = values[3] as? [AXUIElement]
    return Snapshot(
      role: values[0] as? String,
      frame: frame(position: values[1], size: values[2], screenH: screenH),
      children: children ?? [],
      childrenMissing: children == nil,
      title: text(values[4]),
      value: text(values[5]),
      hidden: (values[6] as? Bool) ?? false,
      subrole: values[7] as? String)
  }

  private static func tableChildren(
    of element: AXUIElement, role: String?, insideWebArea: Bool, children: [AXUIElement]
  ) -> [AXUIElement] {
    guard role == "AXTable" || role == "AXOutline" else { return children }
    guard let visible = elements(element, kAXVisibleRowsAttribute as String), !visible.isEmpty
    else { return children }
    let rows = insideWebArea ? nil : elements(element, kAXRowsAttribute as String)
    return AccessibilityProvider.tableChildren(children: children, rows: rows, visibleRows: visible)
  }

  private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
      return nil
    }
    return raw as? [AXUIElement]
  }

  /// Glyph rects for one run. The layout was measured while collecting, so
  /// this is a string search whatever the letter is.
  private static func glyphHits(
    _ run: Run, query: String
  ) -> [(occurrence: BigramOccurrence, rect: CGRect)] {
    BigramMatcher.glyphRects(in: run.text, query: query, lines: lineBoxes(run))
  }

  /// Word rects for one run, from the same measured lines.
  private static func wordHits(_ run: Run) -> [(occurrence: BigramOccurrence, rect: CGRect)] {
    WordMatcher.wordRects(in: run.text, lines: lineBoxes(run))
  }

  private static func lineBoxes(_ run: Run) -> [BigramMatcher.BigramLineBox] {
    switch run.layout {
    case .proportional:
      let length = (run.text as NSString).length
      return [BigramMatcher.BigramLineBox(location: 0, length: length, bounds: run.frame)]
    case .lines(let measured):
      return measured
    }
  }

  /// A short run uses its frame. A tall run's visible lines are measured now,
  /// once, so the later letter does not repeat that work per glyph.
  private static func glyphLayout(
    element: AXUIElement, text: String, frame: CGRect, screenH: CGFloat, clip: CGRect
  ) -> GlyphLayout {
    if BigramMatcher.allowsProportionalFallback(text: text, frame: frame) {
      return .proportional
    }
    switch visibleLineBoxes(element: element, text: text, screenH: screenH, clip: clip) {
    case .boxes(let boxes):
      return .lines(boxes)
    case .unsupported:
      if text.contains("\n") {
        return .lines(BigramMatcher.newlineBoxes(text: text, frame: frame))
      }
      if let glyph = AXAttribute.boundsForRange(
        element, location: 0, length: 1, screenH: screenH),
        glyph.width > 0, glyph.height > 0
      {
        return .lines(BigramMatcher.wrappedBoxes(text: text, frame: frame, glyph: glyph))
      }
      return .proportional
    }
  }

  private enum LineProbe {
    case unsupported
    case boxes([BigramMatcher.BigramLineBox])
  }

  /// How a line sits against the window. NS coordinates grow upward.
  private enum LineBand {
    case above
    case intersects
    case below
  }

  /// At most this many visible lines are measured. A taller window still
  /// covers what fits; the cap keeps a broken line layout from walking a file.
  private static let maxMeasuredLines = 240

  /// Lines of `element` whose bounds meet `clip`. Nil-equivalent `.unsupported`
  /// means the element has no line layout at all.
  private static func visibleLineBoxes(
    element: AXUIElement, text: String, screenH: CGFloat, clip: CGRect
  ) -> LineProbe {
    let length = (text as NSString).length
    guard length > 0 else { return .boxes([]) }
    let cache = LineCache(element: element, textLength: length, screenH: screenH)
    guard let first = cache.range(0), let firstBounds = cache.bounds(0, range: first) else {
      return .unsupported
    }
    // One range covering a tall value is not a line layout. Fall back to
    // per-glyph bounds rather than smearing every letter down the frame.
    if first.length >= length, firstBounds.height > 64 { return .unsupported }
    let start = firstVisibleLine(textLength: length, element: element, clip: clip, cache: cache)
    var boxes: [BigramMatcher.BigramLineBox] = []
    var line = start
    let limit = start + maxMeasuredLines
    while line < limit {
      guard let range = cache.range(line), let bounds = cache.bounds(line, range: range) else {
        break
      }
      switch band(of: bounds, in: clip) {
      case .above:
        line += 1
        continue
      case .below:
        return .boxes(boxes)
      case .intersects:
        boxes.append(
          BigramMatcher.BigramLineBox(
            location: range.location, length: range.length, bounds: bounds))
      }
      if range.location + range.length >= length { break }
      line += 1
    }
    return .boxes(boxes)
  }

  /// The first line that is not above the window. A visible-character range
  /// that is a real window slice wins; a range covering the whole value is the
  /// document, and the line is found from its bounds instead.
  private static func firstVisibleLine(
    textLength: Int, element: AXUIElement, clip: CGRect, cache: LineCache
  ) -> Int {
    if let visible = AXAttribute.visibleCharacterRange(element),
      visible.length > 0, visible.length < textLength,
      let line = AXAttribute.lineForIndex(element, index: visible.location), line >= 0
    {
      return line
    }
    var hi = 1
    while hi < 200_000 {
      guard let range = cache.range(hi), let bounds = cache.bounds(hi, range: range) else { break }
      if band(of: bounds, in: clip) != .above { break }
      hi *= 2
    }
    var lo = 0
    var right = hi
    while lo < right {
      let mid = lo + (right - lo) / 2
      guard let range = cache.range(mid), let bounds = cache.bounds(mid, range: range) else {
        right = mid
        continue
      }
      if band(of: bounds, in: clip) == .above { lo = mid + 1 } else { right = mid }
    }
    return lo
  }

  private static func band(of bounds: CGRect, in clip: CGRect) -> LineBand {
    if bounds.maxY <= clip.minY + 0.5 { return .below }
    if bounds.minY >= clip.maxY - 0.5 { return .above }
    return .intersects
  }

  /// One element's line ranges and bounds for the duration of a collection.
  private final class LineCache {
    let element: AXUIElement
    let textLength: Int
    let screenH: CGFloat
    private var ranges: [Int: CFRange?] = [:]
    private var boundsByLine: [Int: CGRect?] = [:]

    init(element: AXUIElement, textLength: Int, screenH: CGFloat) {
      self.element = element
      self.textLength = textLength
      self.screenH = screenH
    }

    func range(_ line: Int) -> CFRange? {
      if let cached = ranges[line] { return cached }
      let resolved = AXAttribute.rangeForLine(element, line: line).flatMap { range -> CFRange? in
        guard range.location < textLength else { return nil }
        return CFRange(
          location: range.location, length: min(range.length, textLength - range.location))
      }
      ranges[line] = resolved
      return resolved
    }

    func bounds(_ line: Int, range: CFRange) -> CGRect? {
      if let cached = boundsByLine[line] { return cached }
      let resolved = AXAttribute.boundsForRange(
        element, location: range.location, length: range.length, screenH: screenH)
      boundsByLine[line] = resolved
      return resolved
    }
  }

  private static func target(
    hit: Hit, rect: CGRect, run: Run, query: String, ordinal: Int, pid: pid_t,
    bundleIdentifier: String, screenH: CGFloat, clip: CGRect
  ) -> JumpTarget {
    textTarget(
      id: "bigram-\(pid)-\(ordinal)", providerID: providerID, hit: hit, rect: rect, run: run,
      pid: pid, bundleIdentifier: bundleIdentifier, screenH: screenH, clip: clip,
      stillMatches: { text in
        BigramMatcher.sliceMatches(
          text: text, location: hit.location, length: hit.length, query: query)
      },
      point: { bounds, preferred in
        BigramMatcher.clickPoint(in: bounds, keeping: preferred, from: rect)
      })
  }

  public static let wordProviderID = "words"

  /// A word's target: the commit re-reads the string and lands only when the
  /// same word still sits at the captured range.
  private static func wordTarget(
    hit: Hit, rect: CGRect, run: Run, ordinal: Int, pid: pid_t,
    bundleIdentifier: String, screenH: CGFloat, clip: CGRect
  ) -> JumpTarget {
    let expected = hit.label
    return textTarget(
      id: "word-\(pid)-\(ordinal)", providerID: wordProviderID, hit: hit, rect: rect, run: run,
      pid: pid, bundleIdentifier: bundleIdentifier, screenH: screenH, clip: clip,
      stillMatches: { text in
        let haystack = text as NSString
        guard hit.location >= 0, hit.location + hit.length <= haystack.length else { return false }
        return haystack.substring(with: NSRange(location: hit.location, length: hit.length))
          == expected
      },
      point: { bounds, _ in WordMatcher.clickPoint(in: bounds) })
  }

  /// A target on a range of one run's text. `stillMatches` judges the string
  /// read back at commit time; `point` places the click in the range's rect,
  /// given the point the caller chose on the captured rect.
  private static func textTarget(
    id: String, providerID: String, hit: Hit, rect: CGRect, run: Run, pid: pid_t,
    bundleIdentifier: String, screenH: CGFloat, clip: CGRect,
    stillMatches: @escaping (String) -> Bool, point: @escaping (CGRect, CGPoint) -> CGPoint
  ) -> JumpTarget {
    let element = run.element
    let role = run.role
    let location = hit.location
    let length = hit.length
    let capturedFrame = run.frame
    let resolve: (CGPoint) -> CGPoint? = { preferred in
      GeckoAccessibility.withTree(pid: pid, bundleIdentifier: bundleIdentifier) { _ in
        let title = copiedText(element, kAXTitleAttribute as String)
        let value = copiedText(element, kAXValueAttribute as String)
        guard let text = BigramText.rawString(role: role, title: title, value: value),
          stillMatches(text)
        else { return nil }
        if let bounds = AXAttribute.boundsForRange(
          element, location: location, length: length, screenH: screenH)
        {
          let center = CGPoint(x: bounds.midX, y: bounds.midY)
          guard clip.containsInclusive(center) else { return nil }
          return point(bounds, preferred)
        }
        let frame = currentFrame(of: element, screenH: screenH) ?? capturedFrame
        guard BigramMatcher.allowsProportionalFallback(text: text, frame: frame),
          let estimated = BigramMatcher.proportionalRect(
            frame: frame, location: location, length: length,
            totalUTF16: (text as NSString).length)
        else { return nil }
        let center = CGPoint(x: estimated.midX, y: estimated.midY)
        guard clip.containsInclusive(center) else { return nil }
        return point(estimated, preferred)
      }
    }
    return JumpTarget(
      id: id,
      frame: rect,
      role: role,
      accessibilityLabel: hit.label,
      pid: pid,
      resolveClickPoint: resolve,
      entersInsertMode: JumpTarget.isTextInput(role: role, subrole: run.subrole),
      providerID: providerID)
  }

  private static func copiedText(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success, let raw
    else { return nil }
    return text(raw)
  }

  private static func currentFrame(of element: AXUIElement, screenH: CGFloat) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size
    else { return nil }
    return frame(position: position, size: size, screenH: screenH)
  }

  private static func frame(position: Any, size: Any, screenH: CGFloat) -> CGRect? {
    let positionRef = position as CFTypeRef
    let sizeRef = size as CFTypeRef
    guard CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    return AccessibilityProvider.frameFromAX(
      pos: positionRef as! AXValue, size: sizeRef as! AXValue, screenH: screenH)
  }

  private static func text(_ value: Any) -> String? {
    if let text = value as? String { return text }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
  }
}
