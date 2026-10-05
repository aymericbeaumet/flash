import CoreGraphics
import Foundation

/// Where a two-character query sits in a string, in UTF-16 indexes so the
/// range can be handed to `kAXBoundsForRangeParameterizedAttribute`.
public struct BigramOccurrence: Equatable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }
}

/// Pure matching for an EasyMotion-style bigram jump. Both lowercase
/// characters are case-insensitive; any uppercase character is exact.
/// Occurrences may overlap (`aa` matches twice in `aaa`).
public enum BigramMatcher {
  /// Centers closer than this are the same glyph reported by two nodes.
  public static let duplicateCenterDistance: CGFloat = 2

  public static func isCaseSensitive(_ query: String) -> Bool {
    query.contains { $0.isUppercase }
  }

  /// Every match of a two-character query, advancing one UTF-16 unit so
  /// overlaps are kept. Any other query length matches nothing.
  public static func occurrences(in text: String, query: String) -> [BigramOccurrence] {
    guard query.count == 2 else { return [] }
    let haystack = text as NSString
    let needleLength = (query as NSString).length
    guard needleLength > 0, haystack.length >= needleLength else { return [] }
    let options: NSString.CompareOptions = isCaseSensitive(query) ? [] : .caseInsensitive
    var start = 0
    var found: [BigramOccurrence] = []
    while start <= haystack.length - needleLength {
      let range = haystack.range(
        of: query, options: options,
        range: NSRange(location: start, length: haystack.length - start))
      if range.location == NSNotFound || range.length <= 0 { break }
      found.append(BigramOccurrence(location: range.location, length: range.length))
      start = range.location + 1
    }
    return found
  }

  /// Whether the UTF-16 slice is still the query, under the same case rule
  /// the search used. A moved or edited string fails the check.
  public static func sliceMatches(
    text: String, location: Int, length: Int, query: String
  ) -> Bool {
    let haystack = text as NSString
    guard location >= 0, length > 0, location + length <= haystack.length else { return false }
    let slice = haystack.substring(with: NSRange(location: location, length: length))
    if isCaseSensitive(query) { return slice == query }
    return slice.compare(query, options: .caseInsensitive) == .orderedSame
  }

  /// A single visual line can estimate a glyph rect when the element has no
  /// bounds-for-range. A wrapped or tall run cannot: the estimate would land
  /// between lines.
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
/// the one a bigram search indexes. The returned string is the raw attribute
/// (whitespace included) so UTF-16 indexes match `boundsForRange`. A string
/// is indexed only when its trimmed length is at least two characters.
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
      if trimmed.count >= 2 { return candidate }
    }
    return nil
  }
}
