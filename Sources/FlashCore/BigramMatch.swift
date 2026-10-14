import CoreGraphics
import Foundation

/// Where a one-character query sits in a string, in UTF-16 indexes so the
/// range can be handed to `kAXBoundsForRangeParameterizedAttribute`.
public struct BigramOccurrence: Equatable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }
}

/// Pure matching for an EasyMotion-style letter jump. The search character
/// matches either case, so `v` and `V` find the same glyphs, and it matches
/// the other character of that US key, so `3` and `#` do too.
public enum BigramMatcher {
  /// Centers closer than this are the same glyph reported by two nodes.
  public static let duplicateCenterDistance: CGFloat = 2

  /// Where `s` puts the pointer: one point left of the glyph centre.
  /// The pointer still sits on the letter. The lead keeps a later
  /// selection's anchor on this glyph's leading side.
  public static func clickPoint(in frame: CGRect) -> CGPoint {
    CGPoint(x: frame.midX - 1, y: frame.midY)
  }

  /// Unshifted and Shift characters of one US-ANSI key, letters excluded
  /// because case folding already pairs those. Same pairs as
  /// `KeyboardLayout.usANSI`.
  private static let shiftPartner: [Character: Character] = {
    let pairs: [(Character, Character)] = [
      ("`", "~"), ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"),
      ("6", "^"), ("7", "&"), ("8", "*"), ("9", "("), ("0", ")"), ("-", "_"),
      ("=", "+"), ("[", "{"), ("]", "}"), ("\\", "|"), (";", ":"), ("'", "\""),
      (",", "<"), (".", ">"), ("/", "?"),
    ]
    var map: [Character: Character] = [:]
    map.reserveCapacity(pairs.count * 2)
    for (plain, shifted) in pairs {
      map[plain] = shifted
      map[shifted] = plain
    }
    return map
  }()

  /// The query plus the character Shift types on the same US key, when
  /// that key is not a letter.
  private static func searchNeedles(_ query: String) -> [String] {
    guard query.count == 1, let char = query.first, let partner = shiftPartner[char] else {
      return [query]
    }
    return [query, String(partner)]
  }

  /// Every match of a one-character query. The step is the match's own
  /// UTF-16 length, so each glyph is one hit. Any other query length
  /// matches nothing. Case and the US shift pair are the same search.
  public static func occurrences(in text: String, query: String) -> [BigramOccurrence] {
    guard query.count == 1 else { return [] }
    var found: [BigramOccurrence] = []
    var seen = Set<Int>()
    for needle in searchNeedles(query) {
      for hit in scan(text, needle: needle) {
        if seen.insert(hit.location).inserted { found.append(hit) }
      }
    }
    found.sort { $0.location < $1.location }
    return found
  }

  private static func scan(_ text: String, needle: String) -> [BigramOccurrence] {
    let haystack = text as NSString
    let needleLength = (needle as NSString).length
    guard needleLength > 0, haystack.length >= needleLength else { return [] }
    var start = 0
    var found: [BigramOccurrence] = []
    while start <= haystack.length - needleLength {
      let range = haystack.range(
        of: needle, options: .caseInsensitive,
        range: NSRange(location: start, length: haystack.length - start))
      if range.location == NSNotFound || range.length <= 0 { break }
      found.append(BigramOccurrence(location: range.location, length: range.length))
      start = range.location + range.length
    }
    return found
  }

  /// Whether the UTF-16 slice is still the query, under the same case and
  /// shift-pair rule the search used. A moved or edited string fails the check.
  public static func sliceMatches(
    text: String, location: Int, length: Int, query: String
  ) -> Bool {
    let haystack = text as NSString
    guard location >= 0, length > 0, location + length <= haystack.length else { return false }
    let slice = haystack.substring(with: NSRange(location: location, length: length))
    return searchNeedles(query).contains { needle in
      slice.compare(needle, options: .caseInsensitive) == .orderedSame
    }
  }

  /// One visible line of a text run, in UTF-16 indexes of the whole string.
  /// `bounds` is that line's screen rect. Glyphs inside it are placed from
  /// the string, so a common letter costs the same as a rare one.
  public struct BigramLineBox: Equatable {
    public let location: Int
    public let length: Int
    public let bounds: CGRect

    public init(location: Int, length: Int, bounds: CGRect) {
      self.location = location
      self.length = length
      self.bounds = bounds
    }
  }

  /// Where each match sits inside `lines`. A trailing newline does not take a
  /// column. A match that is not inside a line is omitted.
  public static func glyphRects(
    in text: String, query: String, lines: [BigramLineBox]
  ) -> [(occurrence: BigramOccurrence, rect: CGRect)] {
    guard query.count == 1 else { return [] }
    let haystack = text as NSString
    var placed: [(occurrence: BigramOccurrence, rect: CGRect)] = []
    for line in lines {
      guard line.length > 0, line.location >= 0, line.location + line.length <= haystack.length
      else { continue }
      let slice = haystack.substring(
        with: NSRange(location: line.location, length: line.length))
      let columns = utf16LengthDroppingTrailingBreaks(slice)
      guard columns > 0 else { continue }
      for hit in occurrences(in: slice, query: query) {
        guard
          let rect = proportionalRect(
            frame: line.bounds, location: hit.location, length: hit.length, totalUTF16: columns)
        else { continue }
        placed.append(
          (
            occurrence: BigramOccurrence(
              location: line.location + hit.location, length: hit.length),
            rect: rect
          ))
      }
    }
    return placed
  }

  /// One box per newline-separated line, stacked from the top of `frame`.
  /// Used when an element has no Accessibility line layout.
  public static func newlineBoxes(text: String, frame: CGRect) -> [BigramLineBox] {
    let ns = text as NSString
    guard ns.length > 0, frame.width > 0, frame.height > 0 else { return [] }
    var spans: [(location: Int, length: Int)] = []
    var start = 0
    for index in 0..<ns.length {
      if ns.character(at: index) == 10 {
        spans.append((start, index - start))
        start = index + 1
      }
    }
    spans.append((start, ns.length - start))
    let lineHeight = frame.height / CGFloat(spans.count)
    return spans.enumerated().map { index, span in
      BigramLineBox(
        location: span.location, length: span.length,
        bounds: CGRect(
          x: frame.minX, y: frame.maxY - CGFloat(index + 1) * lineHeight,
          width: frame.width, height: lineHeight))
    }
  }

  /// Wrapped lines estimated from one sample glyph, stacked from the top of
  /// `frame`. `glyph` is the first character's rect.
  public static func wrappedBoxes(text: String, frame: CGRect, glyph: CGRect) -> [BigramLineBox] {
    let length = (text as NSString).length
    guard length > 0, frame.width > 0, frame.height > 0, glyph.width > 0, glyph.height > 0
    else { return [] }
    let columns = max(1, Int((frame.width / glyph.width).rounded(.down)))
    let lineHeight = min(glyph.height, frame.height)
    var boxes: [BigramLineBox] = []
    var location = 0
    var index = 0
    while location < length {
      let span = min(columns, length - location)
      let y = frame.maxY - CGFloat(index + 1) * lineHeight
      if y + lineHeight < frame.minY { break }
      boxes.append(
        BigramLineBox(
          location: location, length: span,
          bounds: CGRect(
            x: frame.minX, y: max(y, frame.minY),
            width: min(frame.width, CGFloat(span) * glyph.width), height: lineHeight)))
      location += span
      index += 1
    }
    return boxes
  }

  /// The UTF-16 columns of one line: its length without trailing breaks.
  public static func columns(of line: String) -> Int {
    utf16LengthDroppingTrailingBreaks(line)
  }

  private static func utf16LengthDroppingTrailingBreaks(_ text: String) -> Int {
    let ns = text as NSString
    var length = ns.length
    while length > 0 {
      let unit = ns.character(at: length - 1)
      if unit == 10 || unit == 13 { length -= 1 } else { break }
    }
    return length
  }

  /// A single visual line can estimate a glyph rect from its frame. A wrapped
  /// or tall run cannot: the estimate would land between lines.
  public static func allowsProportionalFallback(text: String, frame: CGRect) -> Bool {
    frame.height > 0 && frame.height <= 64 && !text.contains("\n")
  }

  /// A slice of `frame` in proportion to a UTF-16 range, at least 4pt wide
  /// and clamped so it stays inside the frame.
  public static func proportionalRect(
    frame: CGRect, location: Int, length: Int, totalUTF16: Int
  ) -> CGRect? {
    guard totalUTF16 > 0, length > 0, location >= 0, location + length <= totalUTF16,
      frame.width > 0, frame.height > 0,
      frame.minX.isFinite, frame.minY.isFinite
    else { return nil }
    let total = CGFloat(totalUTF16)
    let width = min(frame.width, max(4, CGFloat(length) / total * frame.width))
    let proposed = frame.minX + CGFloat(location) / total * frame.width
    let maxX = frame.maxX - width
    let x = min(max(proposed, frame.minX), max(frame.minX, maxX))
    return CGRect(x: x, y: frame.minY, width: width, height: frame.height)
  }

  /// Drops later rects whose centers sit within `duplicateCenterDistance` of
  /// an earlier one. Order is the caller's (tree order, then left to right).
  public static func dedupe<Payload>(
    _ items: [(rect: CGRect, value: Payload)]
  ) -> [(rect: CGRect, value: Payload)] {
    let limit = duplicateCenterDistance * duplicateCenterDistance
    var kept: [(rect: CGRect, value: Payload)] = []
    kept.reserveCapacity(items.count)
    for item in items {
      let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
      let duplicate = kept.contains { prior in
        let dx = prior.rect.midX - center.x
        let dy = prior.rect.midY - center.y
        return dx * dx + dy * dy <= limit
      }
      if !duplicate { kept.append(item) }
    }
    return kept
  }
}

/// Which accessibility nodes own visible text, and which string on them is
/// the one a letter search indexes. The returned string is the raw attribute
/// (whitespace included) so UTF-16 indexes match `boundsForRange`. A string
/// is indexed only when its trimmed length is at least one character.
public enum BigramText {
  public static let ownerRoles: Set<String> = [
    "AXStaticText", "AXHeading", "AXLink",
    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
    "AXMenuItem", "AXMenuBarItem", "AXTab",
    "AXMenuItemCheckbox", "AXMenuItemRadio",
    "AXCell", "AXGroup", "AXListItem", "AXRow",
  ]

  /// Roles whose value is the visible text and whose title is secondary.
  /// Every other owner is the other way around (a button's title is the label).
  public static let textRoles: Set<String> = [
    "AXStaticText", "AXHeading",
    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
  ]

  /// The node's own string, or nil when a descendant already emitted, the
  /// role does not own text, or nothing long enough is there. Description is
  /// never read: it is help text, not what is drawn.
  public static func ownString(
    role: String?, title: String?, value: String?, descendantEmitted: Bool
  ) -> String? {
    guard !descendantEmitted, let role, ownerRoles.contains(role) else { return nil }
    return rawString(role: role, title: title, value: value)
  }

  public static func rawString(role: String, title: String?, value: String?) -> String? {
    let ordered = textRoles.contains(role) ? [value, title] : [title, value]
    for candidate in ordered {
      guard let candidate else { continue }
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.count >= 1 { return candidate }
    }
    return nil
  }
}
