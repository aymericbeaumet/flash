import ApplicationServices
import CoreGraphics

/// `mouse_step`: the pointer moves one text line or one character, measured
/// from the text under it, as Vim's `j` `k` `h` `l` move the cursor. In HOLD
/// the held button drags, so the step extends the selection. All coordinates
/// are Accessibility's: global, top-left origin.
public enum TextStep {
  public enum Direction: String, CaseIterable, Hashable {
    case up, down, left, right
  }

  /// The step off the text: one typical line, or one typical column.
  public static let fallbackLine: CGFloat = 18
  public static let fallbackColumn: CGFloat = 8

  /// Probes past the glyph under the pointer, as multiples of its height,
  /// before a vertical step gives up on finding the next line.
  static let maxLineSearch: CGFloat = 4

  /// Where the step lands. `glyphAt` is the glyph drawn under a point;
  /// `neighbour` the glyph `offset` characters along from the one under the
  /// pointer; `landing` where the pointer sits on a glyph. Up and down keep
  /// the pointer's column and land on the next line's middle, even past the
  /// end of a shorter line; left and right land on the neighbour on the same
  /// line. Without text the pointer moves by `fallbackLine` / `fallbackColumn`.
  public static func target(
    pointer: CGPoint, direction: Direction, glyphAt: (CGPoint) -> CGRect?,
    neighbour: (Int) -> CGRect?, landing: (CGRect) -> CGPoint
  ) -> CGPoint {
    let here = glyphAt(pointer)
    switch direction {
    case .left, .right:
      let sign: CGFloat = direction == .right ? 1 : -1
      if let here, let next = neighbour(direction == .right ? 1 : -1),
        abs(next.midY - here.midY) < here.height / 2
      {
        return CGPoint(x: landing(next).x, y: pointer.y)
      }
      return CGPoint(x: pointer.x + sign * fallbackColumn, y: pointer.y)
    case .up, .down:
      let sign: CGFloat = direction == .down ? 1 : -1
      let height = here?.height ?? fallbackLine
      let edge = here.map { direction == .down ? $0.maxY : $0.minY } ?? pointer.y
      var offset: CGFloat = 1
      while offset <= height * maxLineSearch {
        let probe = CGPoint(x: pointer.x, y: edge + sign * offset)
        if let line = lineGlyph(at: probe, glyphAt: glyphAt, column: here),
          sign * (line.midY - (here?.midY ?? pointer.y)) > height / 2
        {
          return CGPoint(x: pointer.x, y: line.midY)
        }
        offset += 2
      }
      return CGPoint(x: pointer.x, y: pointer.y + sign * fallbackLine)
    }
  }

  /// A glyph on the line through `probe`: the one under it, else, past the
  /// end of a shorter line, the nearest glyph to its left on that line.
  private static func lineGlyph(
    at probe: CGPoint, glyphAt: (CGPoint) -> CGRect?, column: CGRect?
  ) -> CGRect? {
    if let glyph = glyphAt(probe) { return glyph }
    let width = column?.width ?? fallbackColumn
    var x = probe.x - width
    var scanned = 0
    while scanned < 80, x > 0 {
      if let glyph = glyphAt(CGPoint(x: x, y: probe.y)) { return glyph }
      x -= width
      scanned += 1
    }
    return nil
  }

  /// The step from `pointer` read from Accessibility: the element under it,
  /// its character there, and that character's neighbours. Blocking AX IPC
  /// bounded by `messagingTimeout`: call off the main thread.
  public static func target(
    pointer: CGPoint, direction: Direction, landing: (CGRect) -> CGPoint,
    messagingTimeout: Float = 0.25
  ) -> CGPoint {
    let probe = Probe(messagingTimeout: messagingTimeout)
    let under = probe.character(at: pointer)
    return target(
      pointer: pointer, direction: direction, glyphAt: { probe.character(at: $0)?.rect },
      neighbour: { offset in
        guard let under, under.index + offset >= 0 else { return nil }
        return bounds(under.element, location: under.index + offset)
      },
      landing: landing)
  }

  // MARK: Jumps

  /// Vim's word and line jumps: `w`, `b`, `e`, `0`, `$`.
  public enum Jump: String, CaseIterable, Hashable {
    case nextWord = "next_word"
    case previousWord = "previous_word"
    case wordEnd = "word_end"
    case lineStart = "line_start"
    case lineEnd = "line_end"
  }

  /// The UTF-16 index a word jump lands on in `text`, from `index`: the next
  /// word's start (`w`), the start of the word the index is in or of the one
  /// before (`b`), or the end of the word, or of the next one when already at
  /// an end (`e`). Nil when there is no such word in `text`.
  public static func wordTarget(in text: String, from index: Int, jump: Jump) -> Int? {
    let words = WordMatcher.words(in: text)
    switch jump {
    case .nextWord:
      return words.first { $0.location > index }?.location
    case .previousWord:
      return words.last { $0.location < index }?.location
    case .wordEnd:
      return words.map { $0.location + $0.length - 1 }.first { $0 > index }
    case .lineStart, .lineEnd:
      return nil
    }
  }

  /// The first (`toEnd` false) or last glyph of the line through `pointer`,
  /// scanning glyph by glyph and stepping over gaps of up to two glyphs
  /// (spaces some apps draw no glyph for). Nil off text.
  public static func lineEdge(
    pointer: CGPoint, toEnd: Bool, glyphAt: (CGPoint) -> CGRect?, landing: (CGRect) -> CGPoint
  ) -> CGPoint? {
    guard let here = glyphAt(pointer) else { return nil }
    let step = max(here.width, 4) * (toEnd ? 1 : -1)
    var edge = here
    var x = here.midX + step
    var misses = 0
    var scanned = 0
    while misses <= 2, scanned < 400 {
      scanned += 1
      if let glyph = glyphAt(CGPoint(x: x, y: here.midY)),
        abs(glyph.midY - here.midY) < here.height / 2
      {
        edge = glyph
        misses = 0
        x = glyph.midX + step
      } else {
        misses += 1
        x += step
      }
    }
    return CGPoint(x: landing(edge).x, y: pointer.y)
  }

  /// A jump from `pointer` read from Accessibility. Off text, or with no word
  /// to jump to in the element under it, the pointer moves one column the
  /// jump's way, so the motion is never a silent no-op.
  public static func target(
    pointer: CGPoint, jump: Jump, landing: (CGRect) -> CGPoint, messagingTimeout: Float = 0.25
  ) -> CGPoint {
    let probe = Probe(messagingTimeout: messagingTimeout)
    let backward = jump == .previousWord || jump == .lineStart
    let fallback = CGPoint(
      x: pointer.x + (backward ? -fallbackColumn : fallbackColumn), y: pointer.y)
    switch jump {
    case .lineStart, .lineEnd:
      return lineEdge(
        pointer: pointer, toEnd: jump == .lineEnd, glyphAt: { probe.character(at: $0)?.rect },
        landing: landing) ?? fallback
    case .nextWord, .previousWord, .wordEnd:
      guard let under = probe.character(at: pointer),
        let text = stringValue(under.element),
        let index = wordTarget(in: text, from: under.index, jump: jump),
        let rect = bounds(under.element, location: index)
      else { return fallback }
      return landing(rect)
    }
  }

  /// The element's text, the string its UTF-16 indexes count in.
  private static func stringValue(_ element: AXUIElement) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success
    else { return nil }
    return raw as? String
  }

  /// One character under a point, through the system-wide element.
  private struct Probe {
    let systemWide: AXUIElement
    let messagingTimeout: Float

    init(messagingTimeout: Float) {
      systemWide = AXUIElementCreateSystemWide()
      self.messagingTimeout = messagingTimeout
      AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    }

    func character(at point: CGPoint) -> (element: AXUIElement, index: Int, rect: CGRect)? {
      var hit: AXUIElement?
      guard
        AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
          == .success, let element = hit
      else { return nil }
      AXUIElementSetMessagingTimeout(element, messagingTimeout)
      var position = point
      guard let positionValue = AXValueCreate(.cgPoint, &position) else { return nil }
      var raw: CFTypeRef?
      guard
        AXUIElementCopyParameterizedAttributeValue(
          element, kAXRangeForPositionParameterizedAttribute as CFString, positionValue, &raw)
          == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID()
      else { return nil }
      var range = CFRange()
      guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0,
        let rect = TextStep.bounds(element, location: range.location)
      else { return nil }
      // Accessibility answers the nearest character, which can sit well away
      // from a point in blank space; only a glyph under the point counts.
      guard rect.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
      return (element, range.location, rect)
    }
  }

  fileprivate static func bounds(_ element: AXUIElement, location: Int) -> CGRect? {
    var range = CFRange(location: location, length: 1)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &raw)
        == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0
    else { return nil }
    return rect
  }
}
